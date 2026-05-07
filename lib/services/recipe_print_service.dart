// FILE: lib/services/recipe_print_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Formats a saved recipe (`UserLoadRow`) as a clean, one-page-friendly
// plain-text document and hands it to the OS share sheet via
// `share_plus`. The user picks the destination — Files, Print, AirDrop,
// email, the system "Save as PDF" affordance — and ends up with a paper
// copy they can three-hole-punch and stick in a binder.
//
// Why text and not PDF?
//   * Adding the `printing` Flutter package pulls in a sizable native
//     dependency for what is essentially "render some lines of text".
//   * iOS and Android share sheets both expose "Save to Files" which
//     accepts the plain `.txt` we hand them; iOS additionally exposes
//     "Print" directly from a shared document, which renders text the
//     same way a Notes.app note would.
//   * Plain text is portable: a reloader's binder of printed loads is
//     legible on any laptop, any printer, no app required.
//
// Public surface:
//
//   * `RecipePrintService(repo)` — constructor.
//   * `formatRecipe(row)` — returns the text body. Pure function — no
//     I/O, no side effects. Useful for unit tests.
//   * `share(row, {subject})` — formats + writes a temp file + opens
//     the share sheet. Returns when the share sheet was presented; the
//     final destination is the user's choice and not visible to us.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// CLAUDE.md notes the marketing pivot toward the 66% pen-and-paper
// reloader cohort. Even after switching to LoadOut, many of those
// reloaders will keep a paper notebook for at-the-bench work. A clean
// "Print recipe" button makes that hybrid workflow effortless: tap,
// share to Print, three-hole-punch the result.
//
// The text-via-share-sheet approach avoids a heavy PDF dependency while
// still getting native print on iOS and "Save to Files / Print to PDF"
// on Android. If a richer PDF layout becomes worth the dependency cost,
// this service is the one place to upgrade.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/recipe_form_screen.dart — the AppBar exposes a
//   "Print" action on saved recipes (only available when there's an
//   existing row to print).

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../database/database.dart';

/// Formats and shares a printable copy of a recipe.
class RecipePrintService {
  RecipePrintService();

  /// Build the plain-text body. Section headers are bare uppercase, key
  /// fields are aligned with two spaces of padding so the right margin
  /// is roughly even on a typical printer. No tabs (tab handling varies
  /// across share-receiving apps).
  String formatRecipe(UserLoadRow row) {
    final buf = StringBuffer();
    void section(String title) {
      buf.writeln();
      buf.writeln(title.toUpperCase());
      buf.writeln('=' * title.length);
    }

    void kv(String label, Object? value, {String? suffix}) {
      if (value == null) return;
      final s = value.toString().trim();
      if (s.isEmpty) return;
      buf.writeln('${_padLabel(label)}$s${suffix ?? ''}');
    }

    buf.writeln('LoadOut — Recipe Card');
    buf.writeln('=' * 24);
    buf.writeln();
    buf.writeln(row.name);
    if (row.caliber != null && row.caliber!.isNotEmpty) {
      buf.writeln(row.caliber!);
    }

    section('Powder');
    kv('Powder', row.powder);
    kv('Charge', row.powderChargeGr, suffix: ' gr');
    kv('Charge Tolerance', row.chargeToleranceGr, suffix: ' gr');

    section('Bullet');
    kv('Bullet', row.bullet);
    kv('Bullet Weight', row.bulletWeightGr, suffix: ' gr');
    kv('Bullet Length', row.bulletLengthIn, suffix: ' in');
    kv('Base-to-Ogive', row.bulletBaseToOgiveIn, suffix: ' in');

    section('Primer');
    kv('Primer', row.primer);
    kv('Primer Seating Force', row.primerSeatingForceLbs, suffix: ' lbs');

    section('Brass');
    kv('Brass', row.brass);

    section('Loaded Round');
    kv('COAL', row.coalIn, suffix: ' in');
    kv('CBTO', row.cbtoIn, suffix: ' in');
    kv('Seating Depth', row.seatingDepthIn, suffix: ' in');
    kv('Shoulder Bump', row.shoulderBumpIn, suffix: ' in');
    kv('Mandrel Size', row.mandrelSizeIn, suffix: ' in');
    kv('Distance to Lands', row.distanceToLandsIn, suffix: ' in');
    kv('Jump to Lands', row.jumpToLandsIn, suffix: ' in');

    if (_hasPressureNotes(row)) {
      section('Pressure');
      kv('Pressure Notes', row.pressureNotes);
      kv('Bolt Lift', row.boltLift);
      if (row.ejectorMarks) kv('Ejector Marks', 'yes');
      if (row.crateredPrimers) kv('Cratered Primers', 'yes');
      kv('Web Expansion at .200"', row.webExpansion200In, suffix: ' in');
      kv('Primer Flatness (1-5)', row.primerFlatness);
    }

    if (_hasProvenance(row)) {
      section('Process / Equipment');
      kv('Loaded By', row.loadedBy);
      kv('Loading Date', _formatDate(row.loadingDate));
      kv('Rounds in Batch', row.roundsLoadedInBatch);
      kv('Press', row.pressUsed);
      kv('Sizing Die', row.sizingDieUsed);
      kv('Seating Die', row.seatingDieUsed);
      kv('Scale', row.scaleUsed);
      kv('Scale Calibration', _formatDate(row.scaleCalibrationDate));
      kv('Comparator Insert', row.comparatorInsertUsed);
      kv('Chronograph', row.chronographUsed);
      kv('Bore State', row.boreState);
    }

    if (row.notes != null && row.notes!.trim().isNotEmpty) {
      section('Notes');
      buf.writeln(row.notes!.trim());
    }

    buf.writeln();
    buf.writeln('-' * 60);
    buf.writeln(
      'Always cross-check this recipe against your current published '
      'reloading manual before loading. Saved values are a snapshot, '
      'not load advice.',
    );
    buf.writeln(
      'Exported from LoadOut on ${_formatDate(DateTime.now())}.',
    );

    return buf.toString();
  }

  /// Renders the recipe as text, writes it to a temp file, and pops
  /// the OS share sheet. The user picks the destination from there
  /// (Print, Files, AirDrop, email).
  Future<void> share(
    UserLoadRow row, {
    String? subject,
  }) async {
    final body = formatRecipe(row);
    final dir = await getTemporaryDirectory();
    // Keep the filename safe across filesystems (no spaces or shell
    // metacharacters).
    final safe = row.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final filename = 'loadout-recipe-${safe.isEmpty ? 'recipe' : safe}.txt';
    final file = File('${dir.path}/$filename');
    await file.writeAsString(body, flush: true);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: subject ?? 'LoadOut recipe: ${row.name}',
      text: body,
    );
  }

  String _padLabel(String label) {
    // Two-column ASCII layout. Pad the label to 24 chars so values
    // align on the same column; falls back to "label: " for very
    // long labels.
    if (label.length >= 22) return '$label: ';
    return '${label.padRight(22)}  ';
  }

  String? _formatDate(DateTime? dt) {
    if (dt == null) return null;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d';
  }

  bool _hasPressureNotes(UserLoadRow row) {
    return (row.pressureNotes != null &&
            row.pressureNotes!.trim().isNotEmpty) ||
        (row.boltLift != null && row.boltLift!.isNotEmpty) ||
        row.ejectorMarks ||
        row.crateredPrimers ||
        row.webExpansion200In != null ||
        row.primerFlatness != null;
  }

  bool _hasProvenance(UserLoadRow row) {
    return (row.loadedBy != null && row.loadedBy!.trim().isNotEmpty) ||
        row.loadingDate != null ||
        row.roundsLoadedInBatch != null ||
        (row.pressUsed != null && row.pressUsed!.trim().isNotEmpty) ||
        (row.sizingDieUsed != null && row.sizingDieUsed!.trim().isNotEmpty) ||
        (row.seatingDieUsed != null && row.seatingDieUsed!.trim().isNotEmpty) ||
        (row.scaleUsed != null && row.scaleUsed!.trim().isNotEmpty) ||
        row.scaleCalibrationDate != null ||
        (row.comparatorInsertUsed != null &&
            row.comparatorInsertUsed!.trim().isNotEmpty) ||
        (row.chronographUsed != null &&
            row.chronographUsed!.trim().isNotEmpty) ||
        (row.boreState != null && row.boreState!.isNotEmpty);
  }
}
