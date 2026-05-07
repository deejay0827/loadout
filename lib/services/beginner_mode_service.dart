// FILE: lib/services/beginner_mode_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Persists and exposes the global "Beginner Mode" preference. Provided
// once at the app root via `Provider`. Forms watch the value to:
//
//   * Default the recipe form's detail level to `Basic` when on
//     (instead of whatever the user last left it at).
//   * Show explainer tooltips next to less-common fields ("CBTO
//     measures from the case base to the bullet's ogive — more
//     reproducible than COAL across bullets with different tip
//     lengths").
//   * Surface the Glossary as a prominent shortcut on the home
//     screen / drawer.
//
// New installs default to ON (`_kDefaultEnabled = true`). The user
// flips it from Settings; the change is reactive — no restart needed,
// because every consumer uses `context.watch<BeginnerModeService>()`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The same screen has to serve a beginner who has never picked a
// charge weight and a competition shooter who tracks bolt-lift state.
// Showing every field at once overwhelms beginners; showing only the
// basics frustrates power users. Beginner Mode is the single switch
// that picks the default emphasis — explainer tooltips on, basic
// detail level, glossary one tap away.
//
// Mirrors the [AutoSaveService] shape so the pattern is consistent
// across the codebase.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — provided once at the root.
// - lib/screens/settings/settings_screen.dart — exposes the toggle.
// - lib/screens/recipes/recipe_form_screen.dart — drives default
//   detail level + tooltip visibility.
// - lib/screens/home/home_screen.dart — adds a Glossary shortcut
//   pinned to the home shell when on.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads / writes `SharedPreferences` under the key
// `beginner_mode_enabled`.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kBeginnerEnabledKey = 'beginner_mode_enabled';

/// New-install default. We bias toward ON because the marketing
/// pivot targets first-time-app reloaders coming over from pen-and-
/// paper. Power users can flip it off in Settings; the preference is
/// then sticky.
const bool _kDefaultEnabled = true;

/// Global Beginner Mode preference. Provided once at app root.
class BeginnerModeService extends ChangeNotifier {
  BeginnerModeService() {
    // ignore: discarded_futures
    _hydrate();
  }

  bool _enabled = _kDefaultEnabled;
  bool _hydrated = false;

  /// True when Beginner Mode is on. Default is true; flips to whatever
  /// the user last chose once `_hydrate` finishes.
  bool get isEnabled => _enabled;

  /// True once the SharedPreferences load completed. Forms can use
  /// this to wait for the saved value before deciding the initial
  /// detail level.
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kBeginnerEnabledKey) ?? _kDefaultEnabled;
    _hydrated = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBeginnerEnabledKey, value);
  }
}
