// FILE: lib/screens/load_development/widgets/shot_entry_card.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Per-charge shot-entry card used by the OCW, Audette Ladder,
// Satterlee, and Generic detail screens. Renders one expandable card
// per planned charge weight, with rows of (velocityFps, impactX,
// impactY, notes) inputs — one row per shot at that charge.
//
// Public widgets:
//   * `ShotEntryCard` — one card for one charge weight. Accepts the
//     existing list of shots, the planned shot count for this method
//     (e.g. 3 for OCW, 1 for Ladder / Satterlee), and callbacks for
//     "add shot," "delete shot," and "update shot."
//
// The card pads the displayed row count up to the planned shot
// count so the user always sees an empty row to type into. Empty
// trailing rows aren't persisted until the user types something.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// All four method-specific detail screens share the same data shape
// (one row per shot, keyed to a charge weight). Pulling the entry UI
// into one widget means every detail screen renders the exact same
// data-entry experience — and a future change (say, swiping shots
// to the next charge) only needs to land in one file.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. Each TextField needs its own controller; controllers must
//    persist across rebuilds when the underlying shot list changes
//    (Flutter would otherwise rebuild the field, lose the cursor
//    position, and produce visible flicker mid-keystroke). We key
//    controllers by `(chargeGr, shotIndex, fieldName)` and dispose
//    them on widget unmount.
// 2. The user types one digit at a time; we don't want to rebuild
//    the whole detail screen on every keystroke. Each field's
//    `onChanged` debounces a 300 ms callback that calls
//    `onShotUpdated` with a partial companion update.
// 3. The "+" affordance for adding an extra shot only appears when
//    the user has already filled the expected row count. Otherwise
//    the empty trailing row IS the "+" affordance.
// 4. Sign convention. The Y impact field labels itself "Y impact
//    (in, + up)" so the user doesn't have to remember which way is
//    positive — the math downstream (OCW vertical-vs-charge) needs Y
//    positive UP and we keep that convention everywhere in the UI.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/ocw_test_screen.dart
// - lib/screens/load_development/ladder_test_screen.dart
// - lib/screens/load_development/satterlee_test_screen.dart
// - lib/screens/load_development/generic_test_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — the widget calls back to the parent for persistence; it does
// not read or write the database directly.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
// We import flutter/services AFTER drift so the drift Value class
// reference doesn't get shadowed by anything in services. Both files
// are large and the import ordering matters less than the explicit
// `show Value` above, but keeping drift first makes the intent clear.
import 'package:flutter/services.dart';

import '../../../database/database.dart';

/// One expandable card representing one planned charge weight on a
/// load-development test. Shows one row per shot; tapping the row
/// expands the per-shot inputs (velocity, impact X, impact Y, notes).
class ShotEntryCard extends StatefulWidget {
  const ShotEntryCard({
    super.key,
    required this.chargeGr,
    required this.shots,
    required this.plannedShotsPerCharge,
    required this.shotKind,
    required this.onAddShot,
    required this.onDeleteShot,
    required this.onUpdateShot,
  });

  /// The charge weight this card represents. Persisted as the key for
  /// every shot row inside it.
  final double chargeGr;

  /// Existing shot rows for this charge.
  final List<LoadDevelopmentShotRow> shots;

  /// How many shots the protocol expects per charge (OCW = 3,
  /// Ladder = 1, Satterlee = 1, Generic = caller's choice).
  final int plannedShotsPerCharge;

  /// Which fields are relevant for this protocol. Some methods don't
  /// care about impact (Satterlee = chrono-only); others don't care
  /// about velocity (Audette Ladder = impact-only).
  final ShotEntryKind shotKind;

  /// Caller persists a brand-new shot at the next available shotIndex.
  /// The companion already has chargeGr filled.
  final Future<void> Function(LoadDevelopmentShotsCompanion entry) onAddShot;

  /// Caller deletes one shot row by id.
  final Future<void> Function(int shotId) onDeleteShot;

  /// Caller persists a partial update to one shot row.
  final Future<void> Function(int shotId, LoadDevelopmentShotsCompanion patch)
      onUpdateShot;

  @override
  State<ShotEntryCard> createState() => _ShotEntryCardState();
}

class _ShotEntryCardState extends State<ShotEntryCard> {
  // Keyed by `(shotId, fieldName)` — controllers persist across
  // rebuilds when the parent re-streams the shot list.
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, Timer> _debounce = {};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final t in _debounce.values) {
      t.cancel();
    }
    super.dispose();
  }

  TextEditingController _ctrl(String key, String? initial) {
    final existing = _controllers[key];
    if (existing != null) {
      // Sync external updates without nuking cursor position.
      final fresh = initial ?? '';
      if (existing.text != fresh && !_isFocused(key)) {
        existing.text = fresh;
      }
      return existing;
    }
    final c = TextEditingController(text: initial ?? '');
    _controllers[key] = c;
    return c;
  }

  bool _isFocused(String key) {
    // Cheap heuristic — Flutter doesn't expose a per-controller focus
    // state, so we use the existence of an active debounce timer as a
    // proxy: if the user typed in the last 300 ms, they're "in" the
    // field. Good enough for our purposes.
    return _debounce[key]?.isActive ?? false;
  }

  void _scheduleUpdate(String key, void Function() apply) {
    _debounce[key]?.cancel();
    _debounce[key] = Timer(const Duration(milliseconds: 350), apply);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shots = widget.shots;
    // Padded display count: at least the planned count, expanded if the
    // user already added more than planned.
    final displayCount = shots.length >= widget.plannedShotsPerCharge
        ? shots.length + 1
        : widget.plannedShotsPerCharge;
    final hasData = shots.any(_shotHasData);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasData
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${widget.chargeGr.toStringAsFixed(2)} gr',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                shots.isEmpty
                    ? '${widget.plannedShotsPerCharge} shots planned'
                    : '${shots.length} shot${shots.length == 1 ? '' : 's'} logged',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (hasData)
              Icon(
                Icons.check_circle_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
        children: [
          for (var i = 0; i < displayCount; i++) _shotRow(context, i),
        ],
      ),
    );
  }

  Widget _shotRow(BuildContext context, int displayIndex) {
    final theme = Theme.of(context);
    final isExisting = displayIndex < widget.shots.length;
    final shot = isExisting ? widget.shots[displayIndex] : null;
    final shotIndex = shot?.shotIndex ?? (widget.shots.length + 1);
    final keyPrefix = shot == null
        ? 'pending_${widget.chargeGr}_$displayIndex'
        : 'shot_${shot.id}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Shot $shotIndex',
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const Spacer(),
              if (isExisting && shot != null)
                IconButton(
                  tooltip: 'Delete this shot',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => widget.onDeleteShot(shot.id),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (widget.shotKind != ShotEntryKind.impactOnly)
                Expanded(
                  child: _numberField(
                    key: '${keyPrefix}_v',
                    label: 'Velocity (fps)',
                    initial: shot?.velocityFps?.toStringAsFixed(0),
                    onChanged: (v) =>
                        _onChanged(shot, displayIndex, velocityFps: v),
                  ),
                ),
              if (widget.shotKind == ShotEntryKind.both ||
                  widget.shotKind == ShotEntryKind.impactOnly) ...[
                if (widget.shotKind != ShotEntryKind.impactOnly)
                  const SizedBox(width: 8),
                Expanded(
                  child: _numberField(
                    key: '${keyPrefix}_x',
                    label: 'X Impact (in)',
                    initial: shot?.impactXIn?.toStringAsFixed(2),
                    onChanged: (v) =>
                        _onChanged(shot, displayIndex, impactXIn: v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _numberField(
                    key: '${keyPrefix}_y',
                    label: 'Y Impact (in, + up)',
                    initial: shot?.impactYIn?.toStringAsFixed(2),
                    onChanged: (v) =>
                        _onChanged(shot, displayIndex, impactYIn: v),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _ctrl('${keyPrefix}_n', shot?.notes),
            decoration: const InputDecoration(
              labelText: 'Notes',
              hintText: 'Called pull, wind shift, etc.',
              isDense: true,
            ),
            onChanged: (v) => _onChanged(shot, displayIndex, notes: v),
          ),
        ],
      ),
    );
  }

  Widget _numberField({
    required String key,
    required String label,
    required String? initial,
    required void Function(double?) onChanged,
  }) {
    return TextField(
      controller: _ctrl(key, initial),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
      ],
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (raw) {
        final t = raw.trim();
        if (t.isEmpty) {
          _scheduleUpdate(key, () => onChanged(null));
        } else {
          final v = double.tryParse(t);
          if (v != null) _scheduleUpdate(key, () => onChanged(v));
        }
      },
    );
  }

  Future<void> _onChanged(
    LoadDevelopmentShotRow? existing,
    int displayIndex, {
    Object? velocityFps = _unset,
    Object? impactXIn = _unset,
    Object? impactYIn = _unset,
    Object? notes = _unset,
  }) async {
    final String? notesText =
        identical(notes, _unset) ? null : notes as String?;
    final notesValue = identical(notes, _unset)
        ? const Value<String?>.absent()
        : Value<String?>(
            (notesText == null || notesText.isEmpty) ? null : notesText,
          );
    final velocityValue = identical(velocityFps, _unset)
        ? const Value<double?>.absent()
        : Value<double?>(velocityFps as double?);
    final xValue = identical(impactXIn, _unset)
        ? const Value<double?>.absent()
        : Value<double?>(impactXIn as double?);
    final yValue = identical(impactYIn, _unset)
        ? const Value<double?>.absent()
        : Value<double?>(impactYIn as double?);

    if (existing == null) {
      // Creating a fresh shot row. Only insert when the user typed
      // something — empty edits stay client-side.
      final hasContent = velocityValue.present ||
          xValue.present ||
          yValue.present ||
          (notesValue.present && (notesValue.value ?? '').isNotEmpty);
      if (!hasContent) return;
      final shotIndex = widget.shots.length + 1;
      final companion = LoadDevelopmentShotsCompanion.insert(
        sessionId: 0, // parent injects via wrapper; see onAddShot caller.
        chargeGr: widget.chargeGr,
        shotIndex: shotIndex,
        velocityFps: velocityValue,
        impactXIn: xValue,
        impactYIn: yValue,
        notes: notesValue,
      );
      await widget.onAddShot(companion);
    } else {
      final patch = LoadDevelopmentShotsCompanion(
        velocityFps: velocityValue,
        impactXIn: xValue,
        impactYIn: yValue,
        notes: notesValue,
      );
      await widget.onUpdateShot(existing.id, patch);
    }
  }

  bool _shotHasData(LoadDevelopmentShotRow s) =>
      s.velocityFps != null ||
      s.impactXIn != null ||
      s.impactYIn != null ||
      (s.notes ?? '').isNotEmpty;

  static const Object _unset = Object();
}

/// Which input fields are relevant for one method. Different methods
/// hide different inputs (Satterlee = chrono only; Audette Ladder
/// can be impact only when the shooter doesn't own a chrono).
enum ShotEntryKind {
  /// Velocity only.
  velocityOnly,

  /// Impact only.
  impactOnly,

  /// Both velocity and impact (OCW, Generic).
  both,
}

