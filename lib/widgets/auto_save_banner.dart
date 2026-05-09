// FILE: lib/widgets/auto_save_banner.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// A slim status banner that sits between the AppBar and the form
// content on every screen wired into [AutoSaveController]. Renders one
// of these states:
//
// * Autosave **off** — save icon + "Auto-save off — tap save to save
//   manually." (Hint that they have to scroll to the bottom save
//   button.)
// * Autosave **onChange / periodic, idle / never saved** — bolt icon
//   plus a copy line that mentions the active frequency
//   ("Auto-save on — saves after any change", "Auto-save on — saves
//   every 5 minutes", etc.).
// * Autosave **active, saving** — small spinner + "Saving..."
// * Autosave **active, saved at least once** — check icon + "Saved
//   · 2:34 PM".
// * Autosave **active, error** — error icon + "Save failed — tap
//   save to retry".
//
// On the right edge it also hosts a tiny [CloudSyncDot] — green when
// synced, amber while syncing, red on error. The dot self-hides for
// free users and when Cloud Sync is disabled, so it only ever lights
// up when continuous sync is actually running. This keeps form-level
// "is my data safely on the cloud?" feedback in the same place as
// the per-form save status.
//
// Subscribes to both the global [AutoSaveService] preference (so
// changing the frequency in Settings updates the banner) and the
// per-form controller's `status` / `lastSavedAt` notifiers (so it
// reflects the current save state without rebuilding the parent
// form).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Without a status indicator, autosave is invisible and beginners can't
// tell whether their typing has been committed. The banner lives at the
// top of every form so it's always visible regardless of scroll
// position; ~32px tall on purpose, so it doesn't displace the form
// itself.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/recipe_form_screen.dart
// - lib/screens/firearms/firearm_form_screen.dart
// - lib/screens/batches/batch_form_screen.dart
// - lib/screens/brass_lots/brass_lot_form_screen.dart
//   ↑ Each renders an `AutoSaveBanner` below its `AppBar`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure rebuild on listenable changes.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auto_save_service.dart';
import 'cloud_sync_indicator.dart';

class AutoSaveBanner extends StatelessWidget {
  const AutoSaveBanner({super.key, required this.controller});

  final AutoSaveController controller;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoSaveService>();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      elevation: 0,
      child: ValueListenableBuilder<AutoSaveStatus>(
        valueListenable: controller.status,
        builder: (context, status, _) {
          return ValueListenableBuilder<DateTime?>(
            valueListenable: controller.lastSavedAt,
            builder: (context, lastSavedAt, _) {
              return _buildBanner(
                context,
                theme: theme,
                frequency: service.frequency,
                status: status,
                lastSavedAt: lastSavedAt,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildBanner(
    BuildContext context, {
    required ThemeData theme,
    required AutoSaveFrequency frequency,
    required AutoSaveStatus status,
    required DateTime? lastSavedAt,
  }) {
    final scheme = theme.colorScheme;
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final IconData icon;
    Widget? leading;
    final String label;

    if (frequency == AutoSaveFrequency.off) {
      icon = Icons.save_outlined;
      label = 'Auto-save off — tap save to save manually';
      leading = Icon(icon, size: 14, color: scheme.onSurfaceVariant);
    } else {
      switch (status) {
        case AutoSaveStatus.saving:
          leading = SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: scheme.primary,
            ),
          );
          label = 'Saving...';
          break;
        case AutoSaveStatus.saved:
          icon = Icons.check_circle_outline;
          leading = Icon(icon, size: 14, color: scheme.primary);
          label = lastSavedAt == null
              ? 'Saved'
              : 'Saved · ${_formatTime(lastSavedAt)}';
          break;
        case AutoSaveStatus.error:
          icon = Icons.error_outline;
          leading = Icon(icon, size: 14, color: scheme.error);
          label = 'Save failed — tap save to retry';
          break;
        case AutoSaveStatus.idle:
          icon = Icons.bolt_outlined;
          leading = Icon(icon, size: 14, color: scheme.primary);
          label = lastSavedAt == null
              ? _idleLabelForFrequency(frequency)
              : 'Saved · ${_formatTime(lastSavedAt)}';
          break;
      }
    }

    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: textStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Cloud Sync dot. Renders nothing for free users / when sync
            // is disabled — see [CloudSyncDot] for the gating logic. The
            // 10px size is consistent with the AppBar variant.
            const SizedBox(width: 8),
            const CloudSyncDot(size: 10),
          ],
        ),
      ),
    );
  }

  /// Idle-state banner copy for each frequency. Shown only before
  /// the first save lands; after that the banner shows "Saved · h:mm
  /// AM/PM" instead.
  static String _idleLabelForFrequency(AutoSaveFrequency f) {
    switch (f) {
      case AutoSaveFrequency.off:
        return 'Auto-save off — tap save to save manually';
      case AutoSaveFrequency.onChange:
        return 'Auto-save on — saves after any change';
      case AutoSaveFrequency.every1min:
        return 'Auto-save on — saves every minute';
      case AutoSaveFrequency.every5min:
        return 'Auto-save on — saves every 5 minutes';
      case AutoSaveFrequency.every10min:
        return 'Auto-save on — saves every 10 minutes';
    }
  }

  /// Format `dt` as a localized 12h "h:mm a" string. Avoids the
  /// `intl` package dependency by formatting manually — the app
  /// already does this for date strings elsewhere.
  static String _formatTime(DateTime dt) {
    final hour24 = dt.hour;
    final hour12 = hour24 == 0
        ? 12
        : hour24 > 12
            ? hour24 - 12
            : hour24;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = hour24 < 12 ? 'AM' : 'PM';
    return '$hour12:$minute $ampm';
  }
}
