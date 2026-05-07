// FILE: lib/screens/recipes/photo_import_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Entry point for the photo-import flow. Renders two big buttons —
// "Take a photo" (camera) and "Pick from gallery" — then runs OCR via
// `PhotoImportService`, parses the result with `RecipeParser`, and
// pushes `PhotoImportReviewScreen` with the resulting `RecipeDraft`.
//
// During the OCR pass the captured image is rendered full-width with a
// `CircularProgressIndicator` overlay so the user has feedback while ML
// Kit's text recognizer is busy. ML Kit's first-call latency includes a
// one-time on-device model download (~30MB) so the spinner can run for
// a few extra seconds the first time the feature is used.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// 66% of reloaders use pen-and-paper notebooks per the launch survey.
// The CSV / XLSX import path covers the spreadsheet cohort; this screen
// covers the notebook cohort. Free, on-device, privacy-aligned — no
// network call ever leaves the device.
//
// All entry points to this screen are gated `Platform.isIOS ||
// Platform.isAndroid` because the underlying `image_picker` and
// `google_mlkit_text_recognition` plugins don't ship a macOS
// implementation today. The static `isSupportedPlatform` helper here
// is the single source of truth for that check; entry points use it
// rather than re-deriving the condition.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Catalog has to be loaded once.** The parser needs the local
//    cartridge / powder / bullet catalogs. We fetch them via
//    `ComponentRepository` in `initState` and cache them on the state
//    so the parser is rebuilt instantly on every retry.
//
// 2. **Permissions vs cancellation are indistinguishable.** When the
//    OS denies camera access AND when the user taps "Cancel" in the
//    picker, `image_picker` returns the same `null`. We surface a
//    generic "Couldn't capture an image — try again?" hint with a
//    secondary "Open Settings" CTA that's only shown if the platform
//    is iOS (Settings deep-linking on Android isn't needed because
//    `image_picker` triggers the system permission prompt automatically
//    on first call).
//
// 3. **OCR can return empty text on dark or out-of-focus photos.** We
//    detect this with `OcrResult.isEmpty` and show a "Couldn't read
//    text from this image" prompt. The user can retake without losing
//    their selection.
//
// 4. **Dispose path matters.** ML Kit's text recognizer holds native
//    resources. The `_service.dispose()` call MUST run when the screen
//    is popped, otherwise the recognizer leaks. We construct one
//    `PhotoImportService` per screen push and dispose in
//    `State.dispose`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/quick_add_recipe_screen.dart — surfaces an
//   "Import from photo" card.
// - lib/screens/recipes/recipes_list_screen.dart — adds a tile to the
//   FAB bottom-sheet.
// - lib/screens/onboarding/onboarding_screen.dart — the photo-import
//   slide deep-links here.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Opens the OS camera or photo-library picker.
// - Loads cartridge / powder / bullet catalogs from SQLite once on
//   `initState`.
// - On first ML Kit invocation, downloads the OCR model (~30MB,
//   on-device).
// - Pushes `PhotoImportReviewScreen` with the parsed draft.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../repositories/component_repository.dart';
import '../../services/photo_import_service.dart';
import '../../services/recipe_parser.dart';
import 'photo_import_review_screen.dart';

/// Two-button photo capture screen. Camera or gallery -> OCR -> parse
/// -> review.
class PhotoImportScreen extends StatefulWidget {
  const PhotoImportScreen({super.key});

  /// True on platforms that have both `image_picker` AND
  /// `google_mlkit_text_recognition` implementations. macOS / Windows /
  /// Linux currently fail this check; web is also excluded.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isAndroid;
  }

  @override
  State<PhotoImportScreen> createState() => _PhotoImportScreenState();
}

class _PhotoImportScreenState extends State<PhotoImportScreen> {
  late final PhotoImportService _service;

  /// Path to the most recently captured / picked image. Rendered as a
  /// preview both during OCR (with a spinner overlay) and on the
  /// "couldn't read text" retry screen.
  String? _imagePath;

  /// True while OCR / parsing is in flight.
  bool _busy = false;

  /// Set when an OCR pass returned empty text (or the parser failed) so
  /// the screen can render a "try again" hint without popping back to
  /// the chooser.
  String? _statusMessage;

  /// Loaded once on initState — re-used for every retry.
  RecipeParser? _parser;

  @override
  void initState() {
    super.initState();
    _service = PhotoImportService();
    // ignore: discarded_futures
    _loadCatalog();
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _service.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    final components = context.read<ComponentRepository>();
    final cartridges = await components.allCartridges();
    final powderLabels = await components.componentLabels('powder');
    final bullets = await components.allBulletsWithManufacturer();
    final primers = await components.componentLabels('primer');
    final brassMfgs = await components.manufacturersForKind('brass');

    // Aliases live as JSON inside CartridgeRow. Decode each one.
    final cartridgeAliases = <String, List<String>>{};
    for (final c in cartridges) {
      try {
        cartridgeAliases[c.name] = _decodeAliases(c.aliasesJson);
      } catch (_) {
        cartridgeAliases[c.name] = const <String>[];
      }
    }

    // Powder labels come back as "<Manufacturer> <Name>" — strip the
    // manufacturer prefix so the parser sees what users actually write
    // ("H4350", "Varget", etc.) AND keep the full label as a fallback.
    final powderNames = <String>{};
    for (final label in powderLabels) {
      powderNames.add(label);
      final parts = label.split(' ');
      if (parts.length >= 2) {
        // Drop the manufacturer (first token) — covers "Hodgdon H4350" -> "H4350".
        powderNames.add(parts.sublist(1).join(' '));
      }
    }

    final bulletEntries = <BulletCatalogEntry>[
      for (final b in bullets)
        BulletCatalogEntry(
          manufacturer: b.mfg.name,
          line: b.bullet.line,
          weightGr: b.bullet.weightGr,
        ),
    ];

    if (!mounted) return;
    setState(() {
      _parser = RecipeParser(
        cartridgeAliases: cartridgeAliases,
        powderNames: powderNames.toList(growable: false),
        bulletLines: bulletEntries,
        primerNames: primers,
        brassNames: brassMfgs,
      );
    });
  }

  /// Decode the `aliasesJson` text column into a String list. Reference
  /// data ships valid JSON, but a defensive try/catch in the caller
  /// keeps a malformed row from crashing the whole catalog load.
  List<String> _decodeAliases(String raw) {
    if (raw.isEmpty) return const <String>[];
    final dynamic decoded = json.decode(raw);
    if (decoded is List) {
      return decoded.whereType<String>().toList(growable: false);
    }
    return const <String>[];
  }

  Future<void> _pick(ImageSource source) async {
    if (_parser == null) {
      // Catalog still loading — show a transient hint and bail.
      _setStatus('Reference catalog still loading. Please try again.');
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final result = await _service.captureAndRecognize(source: source);
      if (!mounted) return;
      if (result == null) {
        // User cancelled OR permission denied. Surface a generic hint —
        // the platform's own permission prompt has already explained
        // the issue if it was a permission denial.
        setState(() {
          _busy = false;
          _statusMessage = source == ImageSource.camera
              ? 'Couldn\'t capture an image. Camera permission may be '
                  'required.'
              : 'No image picked.';
        });
        return;
      }
      setState(() {
        _imagePath = result.imagePath;
      });
      if (result.isEmpty) {
        setState(() {
          _busy = false;
          _statusMessage =
              'Couldn\'t read text from this image. Try better lighting '
              'or a closer photo, then try again.';
        });
        return;
      }
      final draft = _parser!.parse(result.fullText);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoImportReviewScreen(
            draft: draft,
            imagePath: result.imagePath,
            ocrText: result.fullText,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = 'Photo import failed: $e';
      });
    }
  }

  void _setStatus(String message) {
    setState(() {
      _statusMessage = message;
      _busy = false;
    });
  }

  Future<void> _openSettings() async {
    // App-specific settings deep link — only meaningful on iOS today.
    final uri = Uri.parse('app-settings:');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import from photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.photo_camera_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Snap your notebook',
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Take a photo of a handwritten or printed '
                            'reloading log. We\'ll read the text on this '
                            'device — your photo never leaves your phone.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          Chip(
                            label: const Text('Free for everyone'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: theme.colorScheme.primary.withValues(
                              alpha: 0.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_imagePath != null) ...[
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      File(_imagePath!),
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                  if (_busy)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Reading text…',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (_statusMessage != null) ...[
              Card(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_outlined,
                              color: theme.colorScheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _statusMessage!,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      if (Platform.isIOS) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _openSettings,
                            icon: const Icon(Icons.settings),
                            label: const Text('Open Settings'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _busy ? null : () => _pick(ImageSource.camera),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: const Icon(Icons.photo_camera),
              label: const Text('Take a photo'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => _pick(ImageSource.gallery),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Pick from gallery'),
            ),
            const SizedBox(height: 24),
            Text(
              'Tips for a good scan:',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const _TipBullet(text: 'Lay the notebook flat under bright light.'),
            const _TipBullet(text: 'Fill the frame with one recipe at a time.'),
            const _TipBullet(text: 'Hold steady — block any glare on the page.'),
            const _TipBullet(
              text:
                  'Block-letter handwriting reads better than cursive, but '
                  'cursive works too.',
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                _parser == null
                    ? 'Loading reference catalog…'
                    : 'Ready.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiny bullet-line widget used for the tips list. Kept private to this
/// file because the styling is bespoke.
class _TipBullet extends StatelessWidget {
  const _TipBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  '),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

