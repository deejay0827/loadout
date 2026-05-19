// FILE: lib/services/visual_style_notifier.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Global `VisualStyle` preference holder. Owns the SharedPreferences
// I/O for the `visual_style` key and exposes a `ChangeNotifier`
// surface so Settings + Range Day surfaces can `Consumer<...>` the
// current style and react to changes.
//
// Public surface:
//   * `VisualStyleNotifier extends ChangeNotifier`.
//   * `notifier.style` — current [VisualStyle]. Synchronous; defaults
//     to `stylized` until the SharedPrefs hydrate finishes (typically
//     before the first frame).
//   * `notifier.isHydrated` — true once the SharedPrefs read settled.
//     Consumers don't usually need this — the default is correct on
//     fresh install and the hydrate finishes within microseconds.
//   * `notifier.setStyle(VisualStyle)` — write-side. Updates the
//     in-memory value, notifies listeners synchronously, then
//     persists asynchronously.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Both the Settings → App preferences segmented button AND the Range
// Day AppBar quick toggle need to read + write the same value. The
// only Range Day-internal state (the `_RealisticScenePainter`
// constructor parameter) ALSO needs to react to changes from either
// surface so the scene repaints when the user toggles modes.
//
// The pattern matches `lib/services/locale_service.dart`: ChangeNotifier
// provided at the app root via `ChangeNotifierProvider`, hydrates from
// SharedPrefs on construction, writes through on every set. The Range
// Day toggle calls `setStyle`, the painter consumes via `Consumer` →
// `TargetPlot.build` reconstructs the painter when the style
// changes, `shouldRepaint` sees the new style, repaint fires.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * SharedPrefs I/O is async; the notifier exposes a synchronous
//     `style` getter so widget `build()` methods don't need to await.
//     The pre-hydrate default is `stylized` (matches the safe-fallback
//     value in `VisualStyle.fromPersistKey`), so a Range Day surface
//     that builds before the hydrate completes simply shows the
//     stylized tier — which is the correct default for a fresh install
//     AND the migration target for any legacy persisted choice. The
//     visible flash window on first launch is microseconds.
//   * `setStyle` notifies listeners SYNCHRONOUSLY (before the async
//     persist completes) so the UI reflects the change immediately.
//     If the persist throws, the in-memory state stays at the new
//     value — the user sees the new style; the persistence error is
//     logged via `debugPrint`. Reverting on persist failure would
//     produce a worse UX (UI snaps back to old mode after the user
//     committed) for a near-zero failure rate.
//   * No-op early-out: `setStyle(currentStyle)` returns without
//     notifying. Prevents redundant rebuilds when a SegmentedButton's
//     `onSelectionChanged` fires with the already-selected value.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `lib/app.dart` — provides the notifier at the app root via
//     `ChangeNotifierProvider`.
//   * `lib/screens/settings/...` — Settings UI's `SegmentedButton`.
//   * `lib/screens/range_day/range_day_detail_screen.dart` — AppBar
//     toggle + the painter's `visualStyle` parameter.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Reads `visual_style` from SharedPreferences on construction.
//   * Writes `visual_style` to SharedPreferences on `setStyle`.
//   * Notifies attached listeners synchronously on every change.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/visual_style.dart';

/// Global UI-style preference. Provided once at app root via
/// `ChangeNotifierProvider<VisualStyleNotifier>`. Reads + writes the
/// `visual_style` SharedPrefs key.
class VisualStyleNotifier extends ChangeNotifier {
  VisualStyleNotifier() {
    // ignore: discarded_futures
    _hydrate();
  }

  VisualStyle _style = VisualStyle.stylized;
  bool _hydrated = false;

  /// Current style. Synchronous; defaults to [VisualStyle.stylized]
  /// until the SharedPrefs hydrate finishes. Safe to read from
  /// widget `build()` methods.
  VisualStyle get style => _style;

  /// True once the SharedPrefs read settled. The default is correct
  /// pre-hydrate (stylized matches both fresh-install AND the safe-
  /// fallback / legacy-migration target for any persisted value), so
  /// most consumers don't need to wait.
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kVisualStylePrefKey);
      _style = VisualStyle.fromPersistKey(raw);
    } catch (e) {
      // SharedPreferences failed to open — extremely rare. Stay on
      // the stylized default; the next setStyle call will retry the
      // I/O.
      debugPrint('VisualStyleNotifier hydrate failed: $e');
      _style = VisualStyle.stylized;
    }
    _hydrated = true;
    notifyListeners();
  }

  /// Update the user's visual style. Notifies listeners
  /// synchronously, persists asynchronously. No-ops if the value
  /// matches the current style.
  Future<void> setStyle(VisualStyle value) async {
    if (_style == value) return;
    _style = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kVisualStylePrefKey, value.persistKey);
    } catch (e) {
      // Persist failed — in-memory state stays at the new value. The
      // user sees the new style this session; next cold start
      // re-hydrates from the last successfully-persisted value (or
      // the stylized default if none was ever persisted).
      debugPrint('VisualStyleNotifier persist failed: $e');
    }
  }
}
