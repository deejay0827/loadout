// FILE: lib/services/locale_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Persists and exposes the user's chosen UI language. Provided once at the
// app root via `Provider`. `LoadOutApp.build` reads the current `locale`
// and hands it to `MaterialApp`'s `locale:` parameter; flutter then
// renders every `AppLocalizations.of(context)!.<key>` lookup against the
// matching `app_<lang>.arb`.
//
// `null` means "follow the device locale" — Flutter's default behaviour
// when `MaterialApp.locale` is unset. The Settings → Language picker
// surfaces a "System default" entry that maps back to `null`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut launches with translations for English, German, Spanish,
// French, Italian, Russian, Finnish, Swedish, Norwegian Bokmål,
// Polish, Czech, Brazilian Portuguese, Hungarian, Danish, and Dutch
// (15 total). Flutter's built-in locale resolution picks the device
// locale automatically, but reloaders frequently want to override
// that — e.g. a Russian-speaking shooter on an English macOS
// install, or a beta-tester verifying the German pack on an English
// phone. This service is the single source of truth for that override.
//
// Mirrors the shape of `BeginnerModeService` and `AutoSaveService` so
// every preference toggle in the app uses the same pattern.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **`null` is a load-bearing value.** It means "follow the
//     device locale," NOT "no preference set yet." Both states map
//     to null. Don't add an enum or a sentinel to disambiguate —
//     callers don't care, and Flutter's `MaterialApp.locale: null`
//     is the canonical "use system" signal.
//   * **The stored prefs value is the language TAG, not a Locale.**
//     SharedPreferences is string-based; we serialize as a tag
//     (`'de'`, `'es'`, etc.) and parse back on load. If we ever add
//     country-variant locales (`de_AT`, `es_MX`), the parse path
//     needs to handle the underscore form.
//   * **MaterialApp must subscribe via `context.watch`**, not a
//     one-shot `context.read`. Without watching, switching language
//     in Settings won't re-resolve the localizations until the user
//     restarts. The provider is set up to notify on every setLocale.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — provided once at the root; `LoadOutApp.build`
//   watches the notifier and feeds the value into `MaterialApp.locale`.
// - lib/screens/settings/settings_screen.dart — exposes the dropdown
//   that calls `setLocale(...)`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads / writes `SharedPreferences` under the key `app_locale`. The
// stored value is the language tag (e.g. `de`, `es`, `fr`, `ru`, `it`,
// `fi`, `sv`, `nb`, `pl`, `cs`, `pt_BR`, `hu`, `da`, `nl`, or `en`);
// the special value `''` (empty string) and the missing key both
// decode to `null`, meaning "follow the device locale". Country-variant
// tags such as `pt_BR` are stored verbatim and parsed back via
// underscore split when handed to `MaterialApp.locale`.

import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the user's locale override. Stored as the
/// 2-letter language tag (`en`, `de`, `es`, ...) or empty for "follow
/// the system".
const String kLocalePrefKey = 'app_locale';

/// Locales the app ships translations for. Order matters — this is the
/// order the picker renders in. Keep in sync with the `app_*.arb` files
/// under `lib/l10n/`. The first six entries are the original launch
/// pack; the nine that follow were added in the 15-language expansion
/// and are flagged TRANSLATOR-REVIEW in their respective ARBs.
const List<String> kSupportedLanguageCodes = [
  'en',
  'de',
  'es',
  'fr',
  'it',
  'ru',
  'fi',
  'sv',
  'nb',
  'pl',
  'cs',
  'pt_BR',
  'hu',
  'da',
  'nl',
];

/// Display label for each supported locale, in its OWN language so a
/// user who can't read the current UI language can still find their
/// own. Falls back to the language tag if a key is missing.
const Map<String, String> kLanguageDisplayNames = {
  'en': 'English',
  'de': 'Deutsch',
  'es': 'Español',
  'fr': 'Français',
  'it': 'Italiano',
  'ru': 'Русский',
  'fi': 'Suomi',
  'sv': 'Svenska',
  'nb': 'Norsk Bokmål',
  'pl': 'Polski',
  'cs': 'Čeština',
  'pt_BR': 'Português (Brasil)',
  'hu': 'Magyar',
  'da': 'Dansk',
  'nl': 'Nederlands',
};

/// Global UI-locale preference. Provided once at app root via
/// `provider`. `null` means "follow the device locale".
class LocaleService extends ChangeNotifier {
  LocaleService() {
    // ignore: discarded_futures
    _hydrate();
  }

  String? _languageCode;
  bool _hydrated = false;

  /// The user's chosen language tag (`en`, `de`, `pt_BR`, ...) or
  /// `null` to follow the system. Country-variant tags use the
  /// underscore form on disk; consumers feeding `MaterialApp.locale`
  /// should call [resolvedLocale] instead so the underscore is split
  /// into the proper [Locale] language + country pair.
  String? get languageCode => _languageCode;

  /// Convenience getter that returns the user's chosen [Locale] (or
  /// `null` for "follow the device locale"). Handles country-variant
  /// tags such as `pt_BR` by splitting on the underscore — feeding
  /// `Locale('pt_BR')` directly to `MaterialApp.locale` would create
  /// a Locale whose `languageCode` is the literal string `pt_BR`,
  /// which doesn't match `gen_l10n`'s `Locale('pt', 'BR')` entry in
  /// `supportedLocales` and silently falls back to English.
  Locale? get resolvedLocale {
    final code = _languageCode;
    if (code == null || code.isEmpty) return null;
    final parts = code.split('_');
    if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return Locale(parts[0], parts[1]);
    }
    return Locale(code);
  }

  /// True once the SharedPreferences read finished. Consumers can wait
  /// for this before forcing a `MaterialApp.locale` value if they want
  /// to avoid an English flash on cold start; in practice the read
  /// resolves before the first frame so the flash is invisible.
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kLocalePrefKey);
    _languageCode = (raw == null || raw.isEmpty) ? null : raw;
    _hydrated = true;
    notifyListeners();
  }

  /// Set the user's preferred language. Pass `null` to clear the
  /// override and follow the device locale instead.
  Future<void> setLanguageCode(String? value) async {
    final normalized =
        (value == null || value.isEmpty) ? null : value;
    if (_languageCode == normalized) return;
    _languageCode = normalized;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (normalized == null) {
      await prefs.remove(kLocalePrefKey);
    } else {
      await prefs.setString(kLocalePrefKey, normalized);
    }
  }
}
