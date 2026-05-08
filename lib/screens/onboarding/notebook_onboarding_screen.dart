// FILE: lib/screens/onboarding/notebook_onboarding_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Dedicated onboarding path for the "I have a notebook" persona — the
// pen-and-paper reloader who has never used a reloading app before. The
// flow is intentionally short: an explainer slide, the existing photo
// capture screen, the existing review screen, and a wrap-up slide that
// shows the count of imported recipes plus the elapsed time. Most paper
// reloaders walk through this in 60 seconds.
//
// Public surface:
//
//   * `NotebookOnboardingScreen` — the entry point. Renders the
//     explainer, then on "Snap a photo" pushes
//     `PhotoImportScreen` and waits for the user to either save a
//     recipe through `PhotoImportReviewScreen` (which pops back twice
//     with `result == null` after writing the row) or cancel.
//   * `NotebookOnboardingScreen.start(context)` — convenience helper
//     used by `OnboardingScreen` and `HowItWorksScreen` to push this
//     screen as a fullscreen-dialog route.
//
// State:
//   * `_OnboardingStep` — `explainer` (slide 1), `wrapUp` (slide 4).
//     Slides 2 and 3 are existing screens we push and wait on.
//   * `_startedAt` — captured before the first capture screen push so
//     the wrap-up can report total elapsed time ("imported 3 recipes
//     in 47 seconds").
//   * `_importedCount` — how many recipes were saved from this flow.
//     Bumped each time a `PhotoImportReviewScreen` returns `null`
//     (the review screen pops both itself and the capture screen on
//     successful save, but not on cancel — see comment in
//     `PhotoImportReviewScreen._save`).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The launch survey says 66% of reloaders track loads in pen-and-paper
// notebooks. The existing onboarding deck nudged toward those paths but
// asked the user to navigate THROUGH the deck before getting there — by
// the third "feature slide" we'd already lost the user who really just
// wanted to try the photo importer.
//
// This screen is the conversion path: the welcome slide's "I have a
// notebook" CTA pushes here directly. The user reads ONE explainer
// paragraph, taps "Snap a photo," lands on the existing photo capture
// flow (so existing OCR / review code is reused as-is), and ends up on
// the wrap-up slide that confirms what just happened.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`PhotoImportReviewScreen.save()` pops both review + capture
//    screens with no result.** That makes counting saves tricky. We
//    cooperate by reading `UserLoads` row count before/after each
//    capture-screen push and using the delta. This is the simplest
//    cross-screen channel that doesn't require touching the review
//    screen's existing `Navigator.pop()` calls.
//
// 2. **Privacy reassurance lives next to the call to action.** Older
//    users are more sensitive to "what's the catch?" — we surface a
//    short, plain-language reassurance line every step of the way. The
//    text matches the wording in CLAUDE.md §13 (no LoadOut-side
//    backend, OCR runs on-device).
//
// 3. **Onboarding completion flag.** Like `OnboardingScreen`, we set
//    BOTH the legacy v1 flag and the v2 flag on dismiss so an onboarded
//    user doesn't see this flow again unintentionally. The "Skip"
//    affordance from the AppBar uses the same persistence path.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/onboarding/onboarding_screen.dart — the welcome-slide
//   "I have a notebook" CTA pushes this screen.
// - lib/screens/how_it_works/how_it_works_screen.dart — exposes a
//   "From your notebook (60 seconds)" card that pushes this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Persists `OnboardingScreen.seenPrefKey` and
//   `OnboardingScreen.completedV2PrefKey` on dismiss.
// - Pushes `PhotoImportScreen` and `PhotoImportReviewScreen` (whose
//   own side effects — DB writes, custom-component creation — are
//   unchanged).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../repositories/recipe_repository.dart';
import '../../theme/app_theme.dart';
import '../recipes/photo_import_screen.dart';
import 'onboarding_screen.dart';

/// Steps the user moves through inside this screen. The capture +
/// review steps are handled by pushing existing screens; we just track
/// before / after here.
enum _NotebookStep { explainer, wrapUp }

/// Dedicated onboarding path for the pen-and-paper reloader: explainer
/// → photo capture → review → wrap-up. The wrap-up reports import
/// count + elapsed time so the user sees their notebook content
/// land in the app immediately.
class NotebookOnboardingScreen extends StatefulWidget {
  const NotebookOnboardingScreen({super.key});

  /// Push this screen as a fullscreen-dialog route. Used by both
  /// onboarding entry points (welcome-slide CTA and How It Works).
  static Future<void> start(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NotebookOnboardingScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<NotebookOnboardingScreen> createState() =>
      _NotebookOnboardingScreenState();
}

class _NotebookOnboardingScreenState extends State<NotebookOnboardingScreen> {
  _NotebookStep _step = _NotebookStep.explainer;
  DateTime? _startedAt;
  int _importedCount = 0;

  /// Push the existing photo-import flow. We snapshot the row count
  /// before and after so we can count how many recipes the user
  /// imported through this run.
  Future<void> _runPhotoImport() async {
    final repo = context.read<RecipeRepository>();
    _startedAt ??= DateTime.now();
    final before = (await repo.allOnce()).length;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PhotoImportScreen()),
    );
    if (!mounted) return;
    final after = (await repo.allOnce()).length;
    final delta = after - before;
    if (delta <= 0) {
      // User cancelled or didn't save. Stay on the explainer so they
      // can retry. Don't advance to the wrap-up yet.
      return;
    }
    setState(() {
      _importedCount += delta;
      _step = _NotebookStep.wrapUp;
    });
  }

  /// Persist the v1 + v2 onboarding-seen flags. Same write the main
  /// onboarding flow does so a user who lands here from "I have a
  /// notebook" doesn't see the deck reappear later.
  void _markSeenAndClose() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(OnboardingScreen.seenPrefKey, true);
      prefs.setBool(OnboardingScreen.completedV2PrefKey, true);
    });
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Format the elapsed-time string for the wrap-up slide. We round
  /// to whole seconds and pluralize. ("47 seconds", "1 minute 12
  /// seconds"). Anything > 90 seconds collapses to a friendly
  /// "a couple of minutes" because the screen's job is to celebrate
  /// the import, not to make the user feel slow.
  String _elapsedLabel() {
    final start = _startedAt;
    if (start == null) return 'a few seconds';
    final secs = DateTime.now().difference(start).inSeconds;
    if (secs < 5) return 'a few seconds';
    if (secs < 60) return '$secs seconds';
    if (secs < 90) return '1 minute ${secs - 60} seconds';
    if (secs < 180) return 'a couple of minutes';
    return 'a few minutes';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import from your notebook'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: _markSeenAndClose,
        ),
      ),
      body: SafeArea(
        child: switch (_step) {
          _NotebookStep.explainer => _ExplainerStep(
              onStart: _runPhotoImport,
            ),
          _NotebookStep.wrapUp => _WrapUpStep(
              importedCount: _importedCount,
              elapsedLabel: _elapsedLabel(),
              onImportAnother: _runPhotoImport,
              onDone: _markSeenAndClose,
            ),
        },
      ),
    );
  }
}

/// Slide 1 — explainer. Plain-language description of what's about to
/// happen, centered around the privacy promise. The CTA opens the
/// existing camera/gallery screen.
class _ExplainerStep extends StatelessWidget {
  const _ExplainerStep({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supported = PhotoImportScreen.isSupportedPlatform;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      children: [
        // Hero icon — the brass-colored notebook visual we've been
        // using elsewhere for the pen-and-paper persona.
        const SizedBox(height: 8),
        Center(
          child: Icon(
            Icons.menu_book_outlined,
            size: 96,
            color: AppTheme.brass,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Bring your notebook into LoadOut',
          style: theme.textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        // Plain-language explainer. Copy is intentionally written for
        // older readers — short sentences, "you / your" framing, no
        // jargon. See CLAUDE.md "Pen-and-paper conversion" notes.
        Text(
          'Snap a photo of any page from your reloading log.',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          "We'll read your handwriting on this device, turn it into "
          "editable recipe drafts, and let you confirm what's right "
          "before saving.",
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        // Privacy reassurance card. Wording matches the
        // privacy-posture promises in CLAUDE.md §13.
        Card(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.shield_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your data stays on your phone',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Recognition runs entirely on this device. Your "
                        "photo never leaves your phone, and we don't run "
                        "a backend that sees your loads.",
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Tips list — short bullets, plain language. No emojis in body
        // copy per the older-reader audit.
        Text(
          'Tips for a clean photo:',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const _TipRow(text: 'Lay the page flat under bright light.'),
        const _TipRow(
          text: 'Fill the frame with one entry, or pick "Multi-page" '
              'if you want to scan a whole stack.',
        ),
        const _TipRow(
          text: 'Block letters read more cleanly than cursive, '
              'but cursive works too.',
        ),
        const SizedBox(height: 24),
        // Primary CTA. On platforms without ML Kit (macOS / web) we
        // surface a friendly explainer rather than crashing.
        if (supported)
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.photo_camera),
            label: const Text('Snap a photo'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          )
        else
          Card(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      color: theme.colorScheme.error),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "Photo import isn't available on this platform "
                      "yet — please open the app on your phone to "
                      "scan your notebook.",
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Slide 4 — wrap-up. Celebrates the import count + elapsed time and
/// offers a "scan another page" path so the user can keep going.
class _WrapUpStep extends StatelessWidget {
  const _WrapUpStep({
    required this.importedCount,
    required this.elapsedLabel,
    required this.onImportAnother,
    required this.onDone,
  });

  final int importedCount;
  final String elapsedLabel;
  final VoidCallback onImportAnother;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        const SizedBox(height: 24),
        Center(
          child: Icon(
            Icons.check_circle_outline,
            size: 96,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          importedCount == 1
              ? 'You imported 1 recipe from your notebook in $elapsedLabel.'
              : 'You imported $importedCount recipes from your notebook '
                  'in $elapsedLabel.',
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          "That's it. The recipes are saved on your phone.",
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        // Privacy reassurance. Same plain-language posture as the
        // explainer card.
        Card(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.shield_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Your data stays on this device unless you turn on "
                    "Cloud Sync — and even then, it's encrypted with a "
                    "password only you know.",
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Two CTAs: keep going, or finish. We use FilledButton for the
        // primary "Done" action because finishing is what most users
        // want; the "scan another" action is a secondary outlined.
        FilledButton.icon(
          onPressed: onDone,
          icon: const Icon(Icons.check),
          label: const Text('Done'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onImportAnother,
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Scan another page'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ],
    );
  }
}

/// Tiny bullet row used by the explainer tips list. No emoji glyph —
/// see the older-reader copy audit in CLAUDE.md.
class _TipRow extends StatelessWidget {
  const _TipRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
