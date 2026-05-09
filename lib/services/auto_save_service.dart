// FILE: lib/services/auto_save_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Provides the global autosave preferences + an in-memory state holder
// that any form can opt into. Three pieces:
//
// 1. [AutoSaveFrequency] — enum describing how aggressive autosave is:
//    `off`, `onChange` (debounced after every edit, the historical
//    "on" behavior), or one of three periodic timers (`every1min`,
//    `every5min`, `every10min`) that flush dirty edits on a fixed
//    cadence.
//
// 2. [UnsavedChangesPolicy] — enum describing what should happen when
//    the user pops the screen with unsaved edits pending: `ask`
//    (show a Save / Discard / Cancel dialog), `discard` (silently
//    throw away changes), or `saveAll` (silently flush on pop).
//
// 3. [AutoSaveService] — a `ChangeNotifier` provided once at the
//    root via `Provider`. Holds the two enums plus the legacy
//    `auto_save_hint_shown` flag. Persists to `SharedPreferences`
//    under `auto_save_frequency` and `unsaved_changes_policy`. A
//    one-shot migration reads any pre-existing `auto_save_enabled`
//    boolean and converts it to a frequency on first hydrate.
//
// 4. [AutoSaveController] — a per-form helper that wires up the
//    selected frequency for one screen. Forms construct it in
//    `initState` with an `onSave` callback and call `notifyDirty()`
//    whenever a controller / dropdown changes. The controller
//    branches on the active frequency:
//      * `off` — no save fires; the user is responsible for "Done".
//      * `onChange` — debounce after each notify (default 2s).
//      * periodic — a single repeating `Timer.periodic` that fires
//        every N minutes; saves only if `_isDirty` is set. The
//        debounce path is a no-op in periodic mode.
//    `flush()` forces an immediate save (used by "Save changes
//    automatically" pop policy) and `dispose()` cancels every
//    timer. `isDirty` is exposed so the screen-level pop handler
//    can branch on the unsaved-changes policy.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's longest forms (recipe, firearm, batch, brass-lot,
// ballistic profile) were built around a single trailing "Save"
// button at the bottom of a long scrolling layout. Beginners
// couldn't tell when their typing had been committed and routinely
// lost work by backing out before reaching the button. The
// frequency picker plus the unsaved-changes policy give power users
// a way to reduce DB churn (every-N-minutes timer instead of
// per-keystroke) without losing the safety net for beginners.
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
// 2. **Debounce coalescing (onChange mode).** Every keystroke calls
//    `notifyDirty()`, which restarts the 2-second timer. Without
//    that coalescing, the form would issue one DB write per
//    character. Calling `flush()` cancels any pending debounce
//    timer and forces the save now — this is what the back-button
//    handler does so the latest edits are committed before the
//    screen pops.
//
// 3. **Periodic mode.** When the frequency is `every1min` /
//    `every5min` / `every10min`, the controller runs a single
//    `Timer.periodic` and saves only when `_isDirty` is true. The
//    debounce-on-notify path becomes a no-op — the user explicitly
//    chose periodic, so we do not also save on every change. We
//    still set `_isDirty` so periodic ticks know there's something
//    to save and so the screen-level pop handler can branch on it.
//
// 4. **Migration from the legacy boolean.** `auto_save_enabled`
//    was a `bool` in earlier builds. The hydrate step reads it
//    once, maps `true → onChange` / `false → off`, persists the
//    new key, and deletes the old one so the migration is
//    one-shot. New installs default to `onChange` (matches the
//    historical default of "on") and `UnsavedChangesPolicy.ask`.
//
// 5. **Validation guard.** The `onSave` callback returns a nullable
//    int. Returning null tells the controller "the form isn't
//    valid right now, skip this autosave but don't error." A
//    recipe with no name, for example, should not be autosaved.
//    The status stays `idle` rather than flipping to `saved`, so
//    the indicator doesn't lie to the user. `_isDirty` is left
//    untouched so the next periodic tick / debounce will retry.
//
// 6. **Timer lifecycle.** Both the debounce and periodic timers
//    are cancelled in `dispose()`. Forgetting to call dispose
//    would let a pending save fire after the form was popped,
//    potentially crashing because `onSave` likely closes over
//    `mounted`-sensitive state.
//
// 7. **Frequency change while a form is open.** If the user
//    navigates to Settings and changes the frequency mid-edit, the
//    controller is rebuilt by [_rebuildPeriodicTimer] on the next
//    `notifyDirty` (a cheap, lazy reset). Forms don't need to
//    listen explicitly — the next user edit picks the new
//    frequency up.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — instantiates `AutoSaveService()` and provides it.
// - lib/screens/recipes/recipe_form_screen.dart
// - lib/screens/firearms/firearm_form_screen.dart
// - lib/screens/batches/batch_form_screen.dart
// - lib/screens/brass_lots/brass_lot_form_screen.dart
// - lib/screens/ballistics/ballistics_screen.dart
//   ↑ Each constructs an `AutoSaveController` in initState and wires
//   `notifyDirty()` to its controllers, runs the unsaved-changes
//   policy from `PopScope`, and disposes in `dispose()`.
// - lib/screens/settings/app_preferences_screen.dart — the picker UI
//   reads / writes `service.frequency` and
//   `service.unsavedChangesPolicy`.
// - lib/widgets/auto_save_banner.dart — the slim banner widget renders
//   the timestamp / status from an `AutoSaveController` and adapts to
//   the global frequency.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads and writes `SharedPreferences` keys `auto_save_frequency`,
//   `unsaved_changes_policy`, and `auto_save_hint_shown`. Removes
//   the legacy `auto_save_enabled` key once it has been migrated.
// - The controller starts a `Timer` each time `notifyDirty()` is
//   called (debounce mode) or once per controller lifetime (periodic
//   mode) and cancels them in `dispose()`.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Status reported by [AutoSaveController.status]. Used by the banner
/// widget to render a tiny indicator: "Saved · 2:34 PM", "Saving...",
/// "Save failed".
enum AutoSaveStatus { idle, saving, saved, error }

/// How aggressive autosave should be. `off` is the explicit "I'll save
/// manually" setting; `onChange` is the historical 2-second-debounce
/// behavior; the three periodic values are `Timer.periodic` cadences.
enum AutoSaveFrequency {
  off,
  onChange,
  every1min,
  every5min,
  every10min,
}

extension AutoSaveFrequencyX on AutoSaveFrequency {
  /// User-facing label. Matches the copy used by the Settings picker.
  String get label {
    switch (this) {
      case AutoSaveFrequency.off:
        return 'Off';
      case AutoSaveFrequency.onChange:
        return 'After Any Change';
      case AutoSaveFrequency.every1min:
        return 'Every Minute';
      case AutoSaveFrequency.every5min:
        return 'Every 5 Minutes';
      case AutoSaveFrequency.every10min:
        return 'Every 10 Minutes';
    }
  }

  /// Wire-format string used in `SharedPreferences`. Stable across
  /// schema versions; do not rename existing values.
  String get prefsValue {
    switch (this) {
      case AutoSaveFrequency.off:
        return 'off';
      case AutoSaveFrequency.onChange:
        return 'onChange';
      case AutoSaveFrequency.every1min:
        return 'every1min';
      case AutoSaveFrequency.every5min:
        return 'every5min';
      case AutoSaveFrequency.every10min:
        return 'every10min';
    }
  }

  /// Periodic mode interval, or null for `off` / `onChange`.
  Duration? get periodicInterval {
    switch (this) {
      case AutoSaveFrequency.every1min:
        return const Duration(minutes: 1);
      case AutoSaveFrequency.every5min:
        return const Duration(minutes: 5);
      case AutoSaveFrequency.every10min:
        return const Duration(minutes: 10);
      case AutoSaveFrequency.off:
      case AutoSaveFrequency.onChange:
        return null;
    }
  }

  /// True when the controller should persist on each `notifyDirty`
  /// call (subject to debounce). Periodic frequencies leave the
  /// notify path as a "mark dirty" no-op.
  bool get savesOnChange => this == AutoSaveFrequency.onChange;

  /// True when any save will fire automatically without an explicit
  /// user action — i.e. anything but `off`.
  bool get savesAutomatically => this != AutoSaveFrequency.off;

  static AutoSaveFrequency fromPrefs(String? raw) {
    switch (raw) {
      case 'off':
        return AutoSaveFrequency.off;
      case 'onChange':
        return AutoSaveFrequency.onChange;
      case 'every1min':
        return AutoSaveFrequency.every1min;
      case 'every5min':
        return AutoSaveFrequency.every5min;
      case 'every10min':
        return AutoSaveFrequency.every10min;
    }
    return AutoSaveFrequency.onChange;
  }
}

/// What to do when the user pops the form (back button or system
/// back gesture) with unsaved changes pending. Independent of the
/// frequency: a user could pick `every10min` + `saveAll` so most
/// sessions are quiet, but a back-out always lands their edits.
enum UnsavedChangesPolicy { ask, discard, saveAll }

extension UnsavedChangesPolicyX on UnsavedChangesPolicy {
  String get label {
    switch (this) {
      case UnsavedChangesPolicy.ask:
        return 'Ask me each time';
      case UnsavedChangesPolicy.discard:
        return 'Discard changes';
      case UnsavedChangesPolicy.saveAll:
        return 'Save changes automatically';
    }
  }

  String get prefsValue {
    switch (this) {
      case UnsavedChangesPolicy.ask:
        return 'ask';
      case UnsavedChangesPolicy.discard:
        return 'discard';
      case UnsavedChangesPolicy.saveAll:
        return 'saveAll';
    }
  }

  static UnsavedChangesPolicy fromPrefs(String? raw) {
    switch (raw) {
      case 'ask':
        return UnsavedChangesPolicy.ask;
      case 'discard':
        return UnsavedChangesPolicy.discard;
      case 'saveAll':
        return UnsavedChangesPolicy.saveAll;
    }
    return UnsavedChangesPolicy.ask;
  }
}

/// Pref keys for the global preferences. The legacy boolean key is
/// migrated once on hydrate and removed; do not write to it again.
const _kFrequencyKey = 'auto_save_frequency';
const _kPolicyKey = 'unsaved_changes_policy';
const _kHintShownKey = 'auto_save_hint_shown';
const _kLegacyEnabledKey = 'auto_save_enabled';

/// Global autosave preferences. Provided once at the app root and
/// read from any form via `context.watch<AutoSaveService>()` (so
/// changing the frequency or policy in Settings re-renders the
/// banner / hint) or `context.read<AutoSaveService>()` (when the
/// form just needs the current value).
class AutoSaveService extends ChangeNotifier {
  AutoSaveService() {
    // Hydrate from SharedPreferences asynchronously. Eager (vs lazy
    // on first read) so by the time the user opens a form the right
    // preference is already loaded.
    // ignore: discarded_futures
    _hydrate();
  }

  AutoSaveFrequency _frequency = AutoSaveFrequency.onChange;
  UnsavedChangesPolicy _policy = UnsavedChangesPolicy.ask;
  bool _hintShown = false;
  bool _hydrated = false;

  /// Active frequency. Default `onChange` matches the historical
  /// "auto-save on" behavior so existing users don't notice a
  /// regression.
  AutoSaveFrequency get frequency => _frequency;

  /// Active leave-without-saving policy. Default `ask`.
  UnsavedChangesPolicy get unsavedChangesPolicy => _policy;

  /// Convenience: true unless the user picked `off`. Drives the
  /// banner copy + the form's "Done" / "Save" button label.
  bool get isEnabled => _frequency.savesAutomatically;

  /// True once the user has dismissed the first-time autosave hint.
  /// Default false — the first form they open shows the hint
  /// regardless of which form it is.
  bool get hasShownFirstTimeHint => _hintShown;

  /// True once the SharedPreferences load completed. Forms can use
  /// this to delay the first-time hint until we know whether it
  /// should show — avoids a flash where the hint appears and then
  /// disappears once we discover the user already dismissed it.
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final storedFreq = prefs.getString(_kFrequencyKey);
    final storedPolicy = prefs.getString(_kPolicyKey);
    final storedHint = prefs.getBool(_kHintShownKey);
    if (storedFreq != null) {
      _frequency = AutoSaveFrequencyX.fromPrefs(storedFreq);
    } else if (prefs.containsKey(_kLegacyEnabledKey)) {
      // One-shot migration from the boolean key. Map true → onChange
      // (the historical "on" behavior) and false → off; persist the
      // new value, then delete the legacy key so we never run the
      // migration again.
      final legacy = prefs.getBool(_kLegacyEnabledKey) ?? true;
      _frequency = legacy
          ? AutoSaveFrequency.onChange
          : AutoSaveFrequency.off;
      await prefs.setString(_kFrequencyKey, _frequency.prefsValue);
      await prefs.remove(_kLegacyEnabledKey);
    } else {
      _frequency = AutoSaveFrequency.onChange;
    }
    _policy = UnsavedChangesPolicyX.fromPrefs(storedPolicy);
    _hintShown = storedHint ?? false;
    _hydrated = true;
    notifyListeners();
  }

  Future<void> setFrequency(AutoSaveFrequency value) async {
    if (_frequency == value) return;
    _frequency = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFrequencyKey, value.prefsValue);
  }

  Future<void> setUnsavedChangesPolicy(UnsavedChangesPolicy value) async {
    if (_policy == value) return;
    _policy = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPolicyKey, value.prefsValue);
  }

  Future<void> markFirstTimeHintShown() async {
    if (_hintShown) return;
    _hintShown = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHintShownKey, true);
  }
}

/// Per-form autosave controller. One instance per form, constructed
/// in `initState` and disposed in `dispose`.
///
/// Wire up by:
///   1. Creating it with an `onSave` callback that returns the saved
///      row's id (or null if the form is currently invalid).
///   2. Calling `notifyDirty()` from every `TextEditingController`
///      listener, dropdown `onChanged`, and other state mutation.
///   3. Awaiting `flush()` from the unsaved-changes pop handler so
///      anything dirty gets committed before the screen pops (only
///      when the policy is `saveAll` or the user picks "Save" from
///      the `ask` dialog).
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
  }) : _savedRowId = ValueNotifier<int?>(initialSavedRowId) {
    // React to frequency changes: rewire the periodic timer so the
    // user's choice in Settings takes effect even on an open form.
    service.addListener(_onFrequencyMaybeChanged);
    _activeFrequency = service.frequency;
    _ensurePeriodicTimer();
  }

  /// Builds (and persists) the row, returning the saved row's
  /// primary key. Returning null tells the controller the form is
  /// currently invalid — skip this save and stay idle.
  final Future<int?> Function() onSave;

  final AutoSaveService service;
  final Duration debounce;

  /// Optional hook invoked after every successful save. Today this
  /// is used by Cloud Sync to schedule a debounced upload of the
  /// encrypted blob; tests / future features can plug their own
  /// behavior in here. Failures inside the callback are caught so
  /// they can never break the autosave pipeline.
  final void Function()? onSavedToCloud;

  Timer? _debounceTimer;
  Timer? _periodicTimer;
  AutoSaveFrequency _activeFrequency = AutoSaveFrequency.onChange;
  bool _disposed = false;
  bool _isDirty = false;

  final ValueNotifier<int?> _savedRowId;
  final ValueNotifier<DateTime?> _lastSavedAt = ValueNotifier(null);
  final ValueNotifier<AutoSaveStatus> _status =
      ValueNotifier(AutoSaveStatus.idle);

  /// The row id of the most recent successful save, or null if the
  /// form has never persisted yet. Forms read this to decide whether
  /// `onSave` should `INSERT` (null) or `UPDATE` (non-null).
  ValueListenable<int?> get savedRowId => _savedRowId;

  /// Wall-clock time of the most recent successful save, used by the
  /// banner widget to render "Saved · 2:34 PM". Null until first
  /// save.
  ValueListenable<DateTime?> get lastSavedAt => _lastSavedAt;

  /// Current state of the autosave pipeline. Used by the banner to
  /// switch between "Saving..." (with spinner), "Saved · 2:34 PM",
  /// or the error variant.
  ValueListenable<AutoSaveStatus> get status => _status;

  /// Synchronous accessor for the row id; useful inside `onSave` to
  /// branch insert/update.
  int? get currentRowId => _savedRowId.value;

  /// True whenever the form has edits that haven't been persisted
  /// yet. The screen-level pop handler reads this to decide whether
  /// to engage the unsaved-changes policy at all — a clean form
  /// pops without prompting regardless of policy.
  bool get isDirty => _isDirty;

  /// Tells the controller something on the form changed.
  ///
  /// In `onChange` mode, restarts the debounce timer; the actual
  /// save fires after `debounce` of quiet.
  ///
  /// In periodic mode, just sets the dirty flag — the next periodic
  /// tick will save.
  ///
  /// In `off` mode, only sets the dirty flag so the pop handler can
  /// see there's something unsaved.
  void notifyDirty() {
    if (_disposed) return;
    _isDirty = true;
    final freq = service.frequency;
    if (freq == AutoSaveFrequency.off) return;
    if (freq == AutoSaveFrequency.onChange) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(debounce, () {
        // ignore: discarded_futures
        _runSave();
      });
      return;
    }
    // Periodic: ensure the heartbeat is alive. `_ensurePeriodicTimer`
    // is idempotent.
    _ensurePeriodicTimer();
  }

  /// Forces an immediate save, skipping any pending debounce. Used
  /// by the unsaved-changes pop handler in `saveAll` mode and the
  /// "Save" branch of the `ask` dialog. Safe to call when nothing
  /// is dirty — `onSave` will simply rewrite the same values, which
  /// is harmless.
  ///
  /// No-op if autosave is `off` AND the form has no dirty changes.
  /// When the user explicitly picks "Save" via the unsaved-changes
  /// dialog, callers should bypass this and call [forceSave]
  /// directly.
  Future<void> flush() async {
    if (_disposed) return;
    if (!service.frequency.savesAutomatically) return;
    _debounceTimer?.cancel();
    await _runSave();
  }

  /// Always saves, regardless of the frequency. Used by the `ask`
  /// dialog's "Save" branch and the `saveAll` policy when the user
  /// has picked `off` (the unsaved-changes policy can override the
  /// frequency at pop time).
  Future<void> forceSave() async {
    if (_disposed) return;
    _debounceTimer?.cancel();
    await _runSave();
  }

  /// Clears the dirty flag and cancels any pending debounce. Used
  /// when the form re-loads its state from the database (e.g. the
  /// Ballistics screen when the user picks a different saved
  /// profile) so the listener-driven `notifyDirty()` calls fired
  /// by the controllers' text writes don't leave the form looking
  /// dirty when nothing actually changed.
  void markClean() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _isDirty = false;
  }

  void _onFrequencyMaybeChanged() {
    if (_disposed) return;
    if (_activeFrequency == service.frequency) return;
    _activeFrequency = service.frequency;
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _ensurePeriodicTimer();
  }

  void _ensurePeriodicTimer() {
    if (_disposed) return;
    if (_periodicTimer != null) return;
    final interval = service.frequency.periodicInterval;
    if (interval == null) return;
    _periodicTimer = Timer.periodic(interval, (_) {
      if (_disposed) return;
      if (!_isDirty) return;
      // ignore: discarded_futures
      _runSave();
    });
  }

  Future<void> _runSave() async {
    if (_disposed) return;
    _status.value = AutoSaveStatus.saving;
    try {
      final id = await onSave();
      if (_disposed) return;
      if (id == null) {
        // Validation failed; revert to idle without lying to the
        // user. Leave `_isDirty` set so the next tick / debounce
        // will retry.
        _status.value = AutoSaveStatus.idle;
        return;
      }
      _savedRowId.value = id;
      _lastSavedAt.value = DateTime.now();
      _status.value = AutoSaveStatus.saved;
      _isDirty = false;
      // Notify Cloud Sync (if enabled). Wrapped so a sync-side error
      // never disturbs the autosave UX.
      try {
        onSavedToCloud?.call();
      } catch (e) {
        debugPrint('AutoSaveController.onSavedToCloud failed: $e');
      }
    } catch (e) {
      if (_disposed) return;
      debugPrint('AutoSaveController._runSave failed: $e');
      _status.value = AutoSaveStatus.error;
    }
  }

  void dispose() {
    _disposed = true;
    service.removeListener(_onFrequencyMaybeChanged);
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _savedRowId.dispose();
    _lastSavedAt.dispose();
    _status.dispose();
  }
}
