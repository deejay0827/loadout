// FILE: lib/services/auto_save_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Provides the global autosave preference + an in-memory state holder
// that any form can opt into. Two pieces:
//
// 1. [AutoSaveService] — a `ChangeNotifier` provided once at the root
//    via `Provider`. Tracks two persistent flags in `SharedPreferences`:
//    `auto_save_enabled` (default true) and `auto_save_hint_shown`
//    (default false). Any UI that wants to react to the preference can
//    `context.watch<AutoSaveService>()`.
//
// 2. [AutoSaveController] — a per-form helper that wires up debounced
//    autosave for one screen. Forms construct it in `initState` with
//    an `onSave` callback and call `notifyDirty()` whenever a
//    controller / dropdown changes; the controller debounces those
//    notifications (default 2s) and runs `onSave` once the form has
//    been quiet long enough. `flush()` forces an immediate save (used
//    on back-button) and `dispose()` cancels any pending timer.
//
// Both pieces are intentionally decoupled: the service holds the user
// preference, the controller does the per-form bookkeeping. A form
// that hasn't constructed an `AutoSaveController` is never auto-saved
// even if the service flag is on.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's longest forms (recipe, firearm, batch, brass-lot) were
// built around a single trailing "Save" button at the bottom of a long
// scrolling layout. Beginners couldn't tell when their typing had been
// committed and routinely lost work by backing out before reaching the
// button. Autosave + a small "Saved · 2:34 PM" indicator at the top
// of each form solves both problems with one mechanism.
//
// The split between service and controller mirrors the
// `EntitlementNotifier` (global preference) vs per-screen state
// pattern already used elsewhere in the app.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **First-save vs subsequent updates.** A brand-new entity has no
//    primary key yet. The first call to `onSave` must `INSERT` and
//    return the new row id; every subsequent call must `UPDATE` that
//    same row. The controller stores the returned id and exposes it
//    via [savedRowId] so the form's manual save button (and any
//    follow-on logic that needs the id) stays in sync.
//
// 2. **Debounce coalescing.** Every keystroke calls `notifyDirty()`,
//    which restarts the 2-second timer. Without that coalescing, the
//    form would issue one DB write per character. Calling `flush()`
//    cancels any pending debounce timer and forces the save now —
//    this is what the back-button handler does so the latest edits
//    are committed before the screen pops.
//
// 3. **Validation guard.** The `onSave` callback returns a nullable
//    int. Returning null tells the controller "the form isn't valid
//    right now, skip this autosave but don't error." A recipe with no
//    name, for example, should not be autosaved. The status stays
//    `idle` rather than flipping to `saved`, so the indicator doesn't
//    lie to the user.
//
// 4. **Timer lifecycle.** The internal `Timer` is cancelled in
//    `dispose()`. Forgetting to call dispose would let a pending save
//    fire after the form was popped, potentially crashing because
//    `onSave` likely closes over `mounted`-sensitive state.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — instantiates `AutoSaveService()` and provides it.
// - lib/screens/recipes/recipe_form_screen.dart
// - lib/screens/firearms/firearm_form_screen.dart
// - lib/screens/batches/batch_form_screen.dart
// - lib/screens/brass_lots/brass_lot_form_screen.dart
//   ↑ Each constructs an `AutoSaveController` in initState and wires
//   `notifyDirty()` to its controllers, calls `flush()` from
//   `PopScope`, and disposes in `dispose()`.
// - lib/screens/settings/settings_screen.dart — the toggle UI calls
//   `service.setEnabled(...)`.
// - lib/widgets/auto_save_banner.dart — the slim banner widget renders
//   the timestamp / status from an `AutoSaveController` and adapts to
//   the global preference.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads and writes `SharedPreferences` keys `auto_save_enabled` and
//   `auto_save_hint_shown`.
// - The controller starts a `Timer` each time `notifyDirty()` is
//   called and cancels the prior one.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Status reported by [AutoSaveController.status]. Used by the banner
/// widget to render a tiny indicator: "Saved · 2:34 PM", "Saving...",
/// "Save failed".
enum AutoSaveStatus { idle, saving, saved, error }

/// Pref keys for the global autosave preference + first-time hint.
const _kEnabledKey = 'auto_save_enabled';
const _kHintShownKey = 'auto_save_hint_shown';

/// Global autosave preference. Provided once at the app root and read
/// from any form via `context.watch<AutoSaveService>()` (so toggling it
/// in Settings re-renders the banners) or `context.read<AutoSaveService>()`
/// (when the form just needs the current value).
class AutoSaveService extends ChangeNotifier {
  AutoSaveService() {
    // Hydrate from SharedPreferences asynchronously. Keeping this
    // eager (vs lazy on first read) means that by the time the user
    // opens a form the right preference is already loaded.
    // ignore: discarded_futures
    _hydrate();
  }

  bool _enabled = true;
  bool _hintShown = false;
  bool _hydrated = false;

  /// True when autosave is currently turned on. Default is true; we
  /// flip to whatever the user last chose once `_hydrate` finishes.
  bool get isEnabled => _enabled;

  /// True once the user has dismissed the first-time autosave hint.
  /// Default is false — the first form they open shows the hint
  /// regardless of which form it is.
  bool get hasShownFirstTimeHint => _hintShown;

  /// True once the SharedPreferences load completed. Forms can use
  /// this to delay the first-time hint until we know whether it
  /// should show — avoids a flash where the hint appears and then
  /// disappears once we discover the user already dismissed it.
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final storedEnabled = prefs.getBool(_kEnabledKey);
    final storedHint = prefs.getBool(_kHintShownKey);
    _enabled = storedEnabled ?? true;
    _hintShown = storedHint ?? false;
    _hydrated = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
  }

  Future<void> markFirstTimeHintShown() async {
    if (_hintShown) return;
    _hintShown = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHintShownKey, true);
  }
}

/// Per-form autosave controller. One instance per form, constructed in
/// `initState` and disposed in `dispose`.
///
/// Wire up by:
///   1. Creating it with an `onSave` callback that returns the saved
///      row's id (or null if the form is currently invalid).
///   2. Calling `notifyDirty()` from every `TextEditingController`
///      listener, dropdown `onChanged`, and other state mutation.
///   3. Awaiting `flush()` from a `PopScope.onPopInvokedWithResult`
///      handler so anything dirty gets committed before the screen
///      pops.
///
/// The first successful save records the new row id and the
/// controller transitions to "update mode" — every subsequent
/// `onSave` call should `UPDATE` rather than `INSERT`. The form is
/// responsible for branching on `savedRowId` inside its `onSave` to
/// pick the right repository call.
///
/// Cloud Sync hook: the controller fires [onSavedToCloud] (when set)
/// after every successful save so `CloudSyncService.scheduleSyncUp`
/// can debounce + push the encrypted blob a few seconds later. Forms
/// don't have to know about Cloud Sync — `app.dart` wires the
/// callback once and the same code path lights up every form.
class AutoSaveController {
  AutoSaveController({
    required this.onSave,
    required this.service,
    this.debounce = const Duration(seconds: 2),
    int? initialSavedRowId,
    this.onSavedToCloud,
  }) : _savedRowId = ValueNotifier<int?>(initialSavedRowId);

  /// Builds (and persists) the row, returning the saved row's primary
  /// key. Returning null tells the controller the form is currently
  /// invalid — skip this save and stay idle.
  final Future<int?> Function() onSave;

  final AutoSaveService service;
  final Duration debounce;

  /// Optional hook invoked after every successful save. Today this is
  /// used by Cloud Sync to schedule a debounced upload of the
  /// encrypted blob; tests / future features can plug their own
  /// behavior in here. Failures inside the callback are caught so
  /// they can never break the autosave pipeline.
  final void Function()? onSavedToCloud;

  Timer? _debounceTimer;
  bool _disposed = false;

  final ValueNotifier<int?> _savedRowId;
  final ValueNotifier<DateTime?> _lastSavedAt = ValueNotifier(null);
  final ValueNotifier<AutoSaveStatus> _status =
      ValueNotifier(AutoSaveStatus.idle);

  /// The row id of the most recent successful save, or null if the
  /// form has never persisted yet. Forms read this to decide whether
  /// `onSave` should `INSERT` (null) or `UPDATE` (non-null).
  ValueListenable<int?> get savedRowId => _savedRowId;

  /// Wall-clock time of the most recent successful save, used by the
  /// banner widget to render "Saved · 2:34 PM". Null until first save.
  ValueListenable<DateTime?> get lastSavedAt => _lastSavedAt;

  /// Current state of the autosave pipeline. Used by the banner to
  /// switch between "Saving..." (with spinner), "Saved · 2:34 PM",
  /// or the error variant.
  ValueListenable<AutoSaveStatus> get status => _status;

  /// Synchronous accessor for the row id; useful inside `onSave` to
  /// branch insert/update.
  int? get currentRowId => _savedRowId.value;

  /// Tells the controller something on the form changed. Restarts the
  /// debounce timer; the actual save fires after `debounce` of quiet.
  /// No-op if autosave is disabled in Settings.
  void notifyDirty() {
    if (_disposed) return;
    if (!service.isEnabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      // ignore: discarded_futures
      _runSave();
    });
  }

  /// Forces an immediate save, skipping the debounce. Intended for
  /// the back-button / `PopScope` handler so dirty edits land before
  /// the screen pops. Safe to call when nothing is dirty — `onSave`
  /// will simply rewrite the same values, which is harmless.
  ///
  /// No-op if autosave is disabled.
  Future<void> flush() async {
    if (_disposed) return;
    if (!service.isEnabled) return;
    _debounceTimer?.cancel();
    await _runSave();
  }

  Future<void> _runSave() async {
    if (_disposed) return;
    _status.value = AutoSaveStatus.saving;
    try {
      final id = await onSave();
      if (_disposed) return;
      if (id == null) {
        // Validation failed; revert to idle without lying to the user.
        _status.value = AutoSaveStatus.idle;
        return;
      }
      _savedRowId.value = id;
      _lastSavedAt.value = DateTime.now();
      _status.value = AutoSaveStatus.saved;
      // Notify Cloud Sync (if enabled). Wrapped so a sync-side error
      // never disturbs the autosave UX.
      try {
        onSavedToCloud?.call();
      } catch (e) {
        debugPrint('AutoSaveController.onSavedToCloud failed: $e');
      }
    } catch (_) {
      if (_disposed) return;
      _status.value = AutoSaveStatus.error;
    }
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _savedRowId.dispose();
    _lastSavedAt.dispose();
    _status.dispose();
  }
}
