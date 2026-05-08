// FILE: lib/services/sample_notebook_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Generates a printable "sample reloading notebook page" PDF and pops the
// OS share sheet so the user can print it, save it to Files, AirDrop it
// to a desktop, etc. The page has a header band, a table with eight
// reloading-related columns ("Date · Recipe · Caliber · Powder · Charge
// · Bullet · COAL · Notes"), ten blank rows, and a footer hint pointing
// the user back to LoadOut so they can scan their filled-in page later.
//
// Public surface:
//
//   * `SampleNotebookService()` — no-arg constructor.
//   * `buildPdfBytes()` — returns a `Uint8List` of PDF bytes. Pure
//     function (no I/O). Useful for unit tests and for inlining the
//     bytes into a custom share path.
//   * `share(context)` — convenience: builds the PDF, writes it to a
//     temp file, calls `Share.shareXFiles`. Returns when the share
//     sheet was presented.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// CLAUDE.md notes the marketing pivot toward the 66% pen-and-paper
// reloader cohort. The "Print a sample notebook page" pitch is a small
// but powerful conversion feature: it tells the paper user "we meet you
// where you are." Workflow:
//
//   1. User taps "Print sample notebook page" in Settings → Help.
//   2. Share-sheet pops; user picks Print or Save to Files.
//   3. User keeps the printed page at the bench, fills it in by hand
//      while loading.
//   4. At the end of the session the user snaps a photo and imports
//      it via Recipes → Quick Add → "From photo".
//
// Net effect: the user keeps their existing paper habit AND gets a
// digital copy. The app stays useful even if they never abandon paper.
// LoadOut's competitive advantage in this cohort is the OCR pipeline,
// not a "give up your notebook" pitch.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Column widths matter.** Eight columns on a US-Letter page is
//    cramped. We weight the columns proportionally — Notes and Recipe
//    get the most space; Date and COAL get the least. The widths are
//    expressed as ratios so the layout adapts to the page size at
//    render time.
//
// 2. **No fonts beyond the bundled Helvetica.** The `pdf` package
//    ships with the base PDF Type 1 fonts (Helvetica, Times, Courier,
//    Symbol, ZapfDingbats). We don't bundle custom fonts. If a future
//    layout calls for monospaced / italic, we use Courier / Times-
//    Italic from the same set rather than pulling in `printing`'s
//    asset-loading machinery.
//
// 3. **Filename has to be share-friendly.** iOS truncates long file
//    names in the share sheet. We use a short, predictable name —
//    `loadout-notebook-page.pdf` — so the user can find it quickly in
//    Files later.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/settings/settings_screen.dart — the Help & Support
//   section exposes a "Print sample notebook page" tile that calls
//   `share(context)`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Writes a temp file under `getTemporaryDirectory()`.
// - Opens the OS share sheet via `share_plus`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

/// Generates and shares a printable sample reloading notebook page.
class SampleNotebookService {
  const SampleNotebookService();

  /// Number of blank rows the page renders. 10 fits comfortably on a
  /// US-Letter portrait page with the column header band on top and a
  /// short footer hint underneath.
  static const int _kRowCount = 10;

  /// The eight column headers on the printable page. Order matters —
  /// the build below walks this list left-to-right.
  static const List<String> _kColumnHeaders = [
    'Date',
    'Recipe',
    'Caliber',
    'Powder',
    'Charge (gr)',
    'Bullet',
    'COAL (in)',
    'Notes',
  ];

  /// Relative widths for each column. Notes and Recipe get the most
  /// space; Date and COAL the least. Sums to ~100 — the actual
  /// rendered widths are pdf-page-width × ratio / sum.
  static const List<double> _kColumnWeights = [
    9, // Date
    18, // Recipe
    12, // Caliber
    14, // Powder
    8, // Charge (gr)
    14, // Bullet
    9, // COAL (in)
    16, // Notes
  ];

  /// Pure builder — returns the PDF bytes, no I/O. Useful for unit
  /// tests and any future custom share path.
  Future<Uint8List> buildPdfBytes() async {
    final doc = pw.Document(
      title: 'LoadOut — Reloading Notebook Page',
      author: 'LoadOut',
      subject: 'Sample notebook page for hand-recording loads',
      keywords: 'reloading, notebook, loads, hand-recording',
    );

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter.copyWith(
          marginLeft: 36,
          marginRight: 36,
          marginTop: 36,
          marginBottom: 36,
        ),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              pw.SizedBox(height: 14),
              _buildTable(),
              pw.SizedBox(height: 14),
              _buildFooter(),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  /// Builds the page header — title + subtitle. Slight visual weight
  /// at the top, similar to a printed reloading log book.
  pw.Widget _buildHeader() {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Reloading Notebook',
          style: pw.TextStyle(
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          'Date: __________ · Range / location: ___________________ · '
          'Loaded by: _______________',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
      ],
    );
  }

  /// Builds the data table — header band followed by [_kRowCount]
  /// blank rows. Uses `pw.Table` rather than `pw.TableHelper` so we
  /// can control column widths via `columnWidths`.
  pw.Widget _buildTable() {
    // Map column weights into FlexColumnWidth ratios. The PDF
    // package's Table widget normalizes weights against the available
    // page width, so the absolute values don't matter as long as the
    // ratios are right.
    final columnWidths = <int, pw.TableColumnWidth>{
      for (var i = 0; i < _kColumnWeights.length; i++)
        i: pw.FlexColumnWidth(_kColumnWeights[i]),
    };

    return pw.Table(
      border: pw.TableBorder.all(
        color: PdfColors.grey700,
        width: 0.5,
      ),
      columnWidths: columnWidths,
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        // Header row — bold text, slightly tinted background.
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            for (final header in _kColumnHeaders)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
                child: pw.Text(
                  header,
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        // Blank data rows. The user fills these in at the bench. Each
        // row has a fixed minimum height so a hand-filled cell never
        // collapses to a thin line.
        for (var r = 0; r < _kRowCount; r++)
          pw.TableRow(
            children: [
              for (var c = 0; c < _kColumnHeaders.length; c++)
                pw.Container(
                  height: 26,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  // Empty cell — the user will write in it.
                  child: pw.SizedBox.expand(),
                ),
            ],
          ),
      ],
    );
  }

  /// Builds the footer hint pointing the user back to LoadOut. Plain
  /// language, two short sentences. No emojis (matches the
  /// older-reader copy guideline in CLAUDE.md).
  pw.Widget _buildFooter() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'When you are done, snap a photo of this page and import '
            'it back into LoadOut.',
            style: const pw.TextStyle(fontSize: 9.5),
          ),
          pw.SizedBox(height: 2),
          // Plain arrows (>) instead of unicode → so the bundled
          // Helvetica font can render them. The pdf package's Helvetica
          // is the base PDF Type 1 font and doesn't ship Unicode glyphs.
          pw.Text(
            'In the app: Recipes > Quick Add > From photo. The recipe '
            'drafts pre-fill from your handwriting and you confirm '
            'each one before saving. Your notebook stays yours; the '
            'photo never leaves your phone.',
            style: const pw.TextStyle(
              fontSize: 9.5,
              color: PdfColors.grey700,
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'LoadOut · Precision Reloading',
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Build the PDF, write it to a temp file, and surface the OS share
  /// sheet. The user picks Print / Save to Files / AirDrop / etc. from
  /// there.
  ///
  /// `context` is required because the iPad share sheet needs an
  /// origin rect to anchor the popover. We capture the origin rect
  /// BEFORE the first await so we don't read the BuildContext after
  /// async work — the lint that flagged this was correct in spirit
  /// even though `findRenderObject` doesn't actually deactivate a
  /// disposed context.
  Future<void> share(BuildContext context) async {
    // Capture the origin rect synchronously before any async work.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    final bytes = await buildPdfBytes();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/loadout-notebook-page.pdf');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'LoadOut — Reloading Notebook Page',
      text: 'A blank reloading notebook page you can print and fill '
          'in by hand. When you are done, snap a photo and import '
          'it back into LoadOut.',
      sharePositionOrigin: origin,
    );
  }
}
