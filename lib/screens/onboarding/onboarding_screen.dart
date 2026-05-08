// FILE: lib/screens/onboarding/onboarding_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the "Quick Tour" — a horizontal walkthrough that introduces
// LoadOut to first-time users, with a strong bias toward the pen-and-
// paper reloader cohort the app is being marketed to. Reachable as the
// Quick Tour target from `HowItWorksScreen` and from the legacy
// "How To Use LoadOut" drawer entry. The screen is intentionally linear:
// swipe (or tap "Next") forward, swipe back, or tap "Skip" / "Get
// Started" at any point to dismiss.
//
// The flow has five core "v2" slides aimed at pen-and-paper migrators:
//
//   1. Welcome — local-first promise, "from your notebook to your phone
//      in 60 seconds".
//   2. Quick Add — "type a load like you'd write it".
//   3. Bring your existing data — buttons that deep-link to Backup &
//      Export (where the CSV import + future photo import live).
//   4. Grow as you go — 60+ optional fields, hidden in Beginner Mode
//      until you're ready.
//   5. Privacy — local-first SQLite plus end-to-end encrypted backups.
//
// Each page is described by the file-private `_OnboardingPage` data
// class — icon, title, list of bullet strings, and an optional
// `actionLabel` + `_PageActionType` pair. Action types currently are
// `viewPro` (push the paywall), `finish` (dismiss), `openImport`
// (jump to Backup & Export). Backup-screen deep-link is handled by
// popping the onboarding flow first so the user can navigate back into
// Home → Drawer → Backup & Export cleanly.
//
// Layout pieces:
//
//   - `PageView.builder` drives the horizontal swipe behaviour.
//   - `_OnboardingPageView` renders one page: a 96px brass-coloured
//     hero icon, a centered title, a list of bullets, and optional
//     action button(s). Slide C (Bring your data) carries TWO buttons
//     stacked vertically.
//   - `_DotIndicator` is a custom-painted page indicator. The active
//     dot animates wider via `AnimatedContainer`. Implemented inline
//     to avoid pulling in a third-party indicator package.
//   - Bottom bar: "Back" button (disabled on page 0) and a primary
//     "Next" / "Get started" button. AppBar has "Skip" on the right.
//
// On dismiss we mark BOTH the legacy `'onboarding_seen_v1'` flag (so a
// returning user who already saw the v1 tour stays out of the loop)
// and the new `'onboarding_completed_v2'` flag — anything that wants
// to auto-show the new tour for users who saw v1 can key off the v2
// flag specifically.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The onboarding flow is the single best chance to set expectations for
// the pen-and-paper cohort: their notebook isn't being replaced, it's
// being phone-i-fied. The new copy is opinionated: every slide either
// talks about migrating from notebook/spreadsheet, or about privacy.
// We deliberately shortened the deck (5 slides instead of 8) — fewer
// pages to swipe through is its own UX win.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Two things worth knowing:
//
//   1. The custom `_DotIndicator` exists to avoid a `smooth_page_indicator`
//      style dependency just for one screen. The `AnimatedContainer`s
//      in a `Row` give us a perfectly fine animated indicator without
//      pinning another package.
//   2. The "open import" CTA pops the onboarding screen FIRST, then
//      pushes BackupScreen onto the home navigator — pushing on top of
//      a fullscreen-dialog onboarding route would leave the user with
//      a bizarre back-button stack ("close import" returning them to
//      onboarding, not home). Doing the pop first keeps the stack
//      sensible.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/how_it_works/how_it_works_screen.dart` — the Quick
//   Tour card pushes this screen as a `MaterialPageRoute(fullscreenDialog:
//   true)`.
// - `lib/screens/home/home_screen.dart` — the legacy "How To Use
//   LoadOut" drawer entry pushes this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Writes `true` to the SharedPreferences keys
//   `OnboardingScreen.seenPrefKey` ('onboarding_seen_v1') and
//   `OnboardingScreen.completedV2PrefKey` ('onboarding_completed_v2')
//   on dismiss.
// - Indirectly: pushes `PaywallScreen` for the `viewPro` action and
//   `BackupScreen` for the `openImport` action.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../backup/backup_screen.dart';
import '../paywall/paywall_screen.dart';
import '../recipes/photo_import_screen.dart';
import '../recipes/quick_add_recipe_screen.dart';
import '../recipes/smart_import_screen.dart';
import 'notebook_onboarding_screen.dart';

/// Multi-page guided walkthrough that introduces LoadOut's features.
/// Reachable from the side drawer ("How To Use LoadOut") and from
/// `HowItWorksScreen`. After the user completes or skips the flow,
/// SharedPreferences flags are set so future versions can suppress an
/// auto-show on first launch.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  /// Persisted under this key once the user has completed or skipped
  /// onboarding. Versioned so we can re-show on major UX changes by
  /// bumping to `_v2` etc.
  static const String seenPrefKey = 'onboarding_seen_v1';

  /// Per-version flag for the v2 (pen-and-paper) deck. We mark this
  /// alongside the legacy `seenPrefKey` so a future change can
  /// reintroduce v3 by keying its auto-show off `completedV2PrefKey`
  /// without re-prompting users who already saw v2.
  static const String completedV2PrefKey = 'onboarding_completed_v2';

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  /// Build the slide deck against the current locale. Called from
  /// `build()` because `AppLocalizations.of(context)` requires a
  /// `BuildContext` and its result changes when the user switches the
  /// app language in Settings — so the list cannot be a `late final`.
  /// The list is small (6 entries) and rebuilding it on every frame is
  /// cheap.
  List<_OnboardingPage> _buildPages(AppLocalizations l) {
    return [
      // Slide A — Welcome.
      _OnboardingPage(
        icon: Icons.workspace_premium,
        title: l.onboardingWelcomeTitle,
        bullets: [
          l.onboardingWelcomeBullet1,
          l.onboardingWelcomeBullet2,
        ],
      ),
      // Slide A.5 — Path picker. "How do you track your loads today?"
      // Renders three persona cards (just-starting, notebook,
      // spreadsheet); the notebook path is the highlighted CTA. This
      // slide replaces a generic "feature tour" with persona-specific
      // routing into the matching dedicated flow. Pen-and-paper users
      // — the largest survey cohort — get a card centered visually
      // with a brass tint to draw attention.
      const _OnboardingPage(
        icon: Icons.alt_route,
        title: 'How do you track your loads today?',
        bullets: [],
        actionType: _PageActionType.pickPath,
        actionLabel: '',
      ),
      // Slide B — Quick Add.
      _OnboardingPage(
        icon: Icons.bolt,
        title: l.onboardingQuickAddTitle,
        bullets: [
          l.onboardingQuickAddBullet1,
          l.onboardingQuickAddBullet2,
          l.onboardingQuickAddBullet3,
        ],
      ),
      // Slide C — Bring your existing data. Spreadsheet routes to the
      // Smart Import wizard (CSV / XLSX with auto-suggested column
      // mapping); photo routes to Backup & Export, which is the home
      // for the photo-import flow as it lands.
      _OnboardingPage(
        icon: Icons.input,
        title: l.onboardingImportTitle,
        bullets: [
          l.onboardingImportBullet1,
          l.onboardingImportBullet2,
        ],
        actionLabel: l.onboardingImportSpreadsheetButton,
        actionType: _PageActionType.openSpreadsheetImport,
        secondaryActionLabel: l.onboardingImportPhotoButton,
        secondaryActionType: _PageActionType.openPhotoImport,
      ),
      // Slide D — Grow as you go.
      _OnboardingPage(
        icon: Icons.tune,
        title: l.onboardingDetailTitle,
        bullets: [
          l.onboardingDetailBullet1,
          l.onboardingDetailBullet2,
          l.onboardingDetailBullet3,
        ],
      ),
      // Slide E — Privacy.
      _OnboardingPage(
        icon: Icons.lock_outlined,
        title: l.onboardingPrivacyTitle,
        bullets: [
          l.onboardingPrivacyBullet1,
          l.onboardingPrivacyBullet2,
          l.onboardingPrivacyBullet3,
        ],
        actionLabel: l.onboardingGetStarted,
        actionType: _PageActionType.finish,
      ),
    ];
  }

  /// Cached during `build()` so callbacks (`_onNext`, `_handlePageAction`)
  /// can read the slide count / final-slide check without rebuilding
  /// the list. Updated on every build so a locale change refreshes it.
  late List<_OnboardingPage> _pages;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Persist the "seen" flags and pop. Fire-and-forget — we don't
  /// block the close on the disk write.
  void _markSeenAndClose([bool result = true]) {
    SharedPreferences.getInstance().then((prefs) {
      // Mark BOTH the legacy v1 and the new v2 flag. v1 keeps users
      // who have *already* seen v1 from re-popping the deck; v2 is
      // the per-version sentinel for this revamp.
      prefs.setBool(OnboardingScreen.seenPrefKey, true);
      prefs.setBool(OnboardingScreen.completedV2PrefKey, true);
    });
    Navigator.of(context).pop(result);
  }

  void _onNext() {
    if (_index >= _pages.length - 1) {
      _markSeenAndClose();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
    );
  }

  void _onBack() {
    if (_index == 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
    );
  }

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const PaywallScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  /// Mark onboarding seen and pop. Used by every "open import" CTA
  /// before pushing the destination — pushing on top of a fullscreen-
  /// dialog onboarding route would leave the user with a confused
  /// back-stack ("close import" returns to onboarding, not home).
  void _markSeenWithoutClosing() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(OnboardingScreen.seenPrefKey, true);
      prefs.setBool(OnboardingScreen.completedV2PrefKey, true);
    });
  }

  /// Spreadsheet CTA: pop onboarding, push the Smart Import wizard
  /// directly so the user lands on the file-picker step.
  void _openSpreadsheetImport() {
    _markSeenWithoutClosing();
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(builder: (_) => const SmartImportScreen()),
    );
  }

  /// Photo CTA: deep-links to the dedicated `PhotoImportScreen` on
  /// platforms that support it (iOS / Android). On macOS / Windows /
  /// web the photo path doesn't exist, so we fall back to the Backup
  /// hub where the user can find the spreadsheet importer instead.
  void _openPhotoImport() {
    _markSeenWithoutClosing();
    final navigator = Navigator.of(context);
    navigator.pop();
    if (PhotoImportScreen.isSupportedPlatform) {
      navigator.push(
        MaterialPageRoute(builder: (_) => const PhotoImportScreen()),
      );
    } else {
      navigator.push(
        MaterialPageRoute(builder: (_) => const BackupScreen()),
      );
    }
  }

  void _handlePageAction(_PageActionType type) {
    switch (type) {
      case _PageActionType.viewPro:
        _openPaywall();
      case _PageActionType.finish:
        _markSeenAndClose();
      case _PageActionType.openSpreadsheetImport:
        _openSpreadsheetImport();
      case _PageActionType.openPhotoImport:
        _openPhotoImport();
      case _PageActionType.pickPath:
        // Path-picker cards each call their per-card handler directly
        // (see _PathPickerSlide). This branch exists so the switch is
        // exhaustive but is never reached.
        break;
    }
  }

  /// Notebook path: deep-link into the dedicated
  /// `NotebookOnboardingScreen` so the pen-and-paper user gets the
  /// guided flow (explainer → photo capture → review → wrap-up).
  /// On macOS / web (no ML Kit) we fall through to the Backup hub
  /// where the user can find the spreadsheet importer instead.
  void _openNotebookPath() {
    _markSeenWithoutClosing();
    final navigator = Navigator.of(context);
    navigator.pop();
    if (PhotoImportScreen.isSupportedPlatform) {
      NotebookOnboardingScreen.start(navigator.context);
    } else {
      navigator.push(
        MaterialPageRoute(builder: (_) => const BackupScreen()),
      );
    }
  }

  /// "Just starting out" path: jump straight to Quick Add. The user
  /// who has no existing data is the simplest case — give them the
  /// blank form, beginner-friendly defaults are already on by
  /// default for first-time users.
  void _openQuickStart() {
    _markSeenWithoutClosing();
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(builder: (_) => const QuickAddRecipeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
    // Re-build the page list against the current locale on every
    // build so a Settings → Language change updates the slides
    // without restarting the flow.
    _pages = _buildPages(l);
    final isLast = _index == _pages.length - 1;
    final isFirst = _index == 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.onboardingAppBarTitle),
        actions: [
          TextButton(
            onPressed: _markSeenAndClose,
            child: Text(
              l.commonSkip,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _index = i),
                itemCount: _pages.length,
                itemBuilder: (context, i) {
                  final page = _pages[i];
                  return _OnboardingPageView(
                    page: page,
                    onAction: page.actionType == null
                        ? null
                        : () => _handlePageAction(page.actionType!),
                    onSecondaryAction: page.secondaryActionType == null
                        ? null
                        : () =>
                            _handlePageAction(page.secondaryActionType!),
                    onPickQuickStart: _openQuickStart,
                    onPickNotebook: _openNotebookPath,
                    onPickSpreadsheet: _openSpreadsheetImport,
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            _DotIndicator(
              count: _pages.length,
              activeIndex: _index,
              activeColor: theme.colorScheme.primary,
              inactiveColor:
                  theme.colorScheme.onSurface.withValues(alpha: 0.25),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isFirst ? null : _onBack,
                      child: Text(l.commonBack),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _onNext,
                      child: Text(isLast ? l.onboardingGetStarted : l.commonNext),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Action a page may expose via an inline button below its bullet
/// content. The two import variants split out so the welcome deck can
/// route each CTA to its own destination — spreadsheet to the Smart
/// Import wizard (CSV/XLSX with column mapping), photo to the Backup
/// & Export hub where photo import will land. Both are local-first;
/// no data leaves the device on either path.
enum _PageActionType {
  viewPro,
  finish,
  openSpreadsheetImport,
  openPhotoImport,
  /// Path-picker slide: render persona-specific cards instead of a
  /// single CTA button. Each card has its own callback. Tapping a
  /// card pops onboarding and pushes the matching dedicated flow
  /// (notebook, spreadsheet, or just-getting-started Quick Add).
  pickPath,
}

/// Plain data container for a single onboarding page. Action label/
/// type pairs are optional and may include a secondary action (used by
/// the "Bring your existing data" slide for both spreadsheet and photo
/// import buttons).
class _OnboardingPage {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.bullets,
    this.actionLabel,
    this.actionType,
    this.secondaryActionLabel,
    this.secondaryActionType,
  })  : assert(
          (actionLabel == null) == (actionType == null),
          'actionLabel and actionType must be set together',
        ),
        assert(
          (secondaryActionLabel == null) == (secondaryActionType == null),
          'secondaryActionLabel and secondaryActionType must be set '
          'together',
        );

  final IconData icon;
  final String title;
  final List<String> bullets;
  final String? actionLabel;
  final _PageActionType? actionType;
  final String? secondaryActionLabel;
  final _PageActionType? secondaryActionType;
}

/// Renders a single page: hero icon, title, bullet list, optional
/// action button(s). Scrolls if content exceeds available height
/// (shorter screens).
class _OnboardingPageView extends StatelessWidget {
  const _OnboardingPageView({
    required this.page,
    this.onAction,
    this.onSecondaryAction,
    this.onPickQuickStart,
    this.onPickNotebook,
    this.onPickSpreadsheet,
  });

  final _OnboardingPage page;
  final VoidCallback? onAction;
  final VoidCallback? onSecondaryAction;

  /// Path-picker slide callbacks. Wired only when the page's action
  /// type is [_PageActionType.pickPath]; null on every other slide.
  final VoidCallback? onPickQuickStart;
  final VoidCallback? onPickNotebook;
  final VoidCallback? onPickSpreadsheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Path-picker slide. Renders three "How do you track today?" cards
    // instead of bullet lists + a single CTA. This is the conversion
    // surface for the pen-and-paper persona.
    if (page.actionType == _PageActionType.pickPath) {
      return _PathPickerSlide(
        title: page.title,
        onPickQuickStart: onPickQuickStart,
        onPickNotebook: onPickNotebook,
        onPickSpreadsheet: onPickSpreadsheet,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            page.icon,
            size: 96,
            color: AppTheme.brass,
          ),
          const SizedBox(height: 24),
          Text(
            page.title,
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          for (final bullet in page.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 12),
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
                    child: Text(
                      bullet,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
          if (page.actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onAction,
                icon: Icon(_iconForAction(page.actionType!)),
                label: Text(page.actionLabel!),
              ),
            ),
          ],
          if (page.secondaryActionLabel != null &&
              onSecondaryAction != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onSecondaryAction,
                icon: Icon(_iconForSecondaryAction(page)),
                label: Text(page.secondaryActionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Pick a glyph that hints at the action type. Keeps the slide
  /// visually distinct from the page hero icon.
  IconData _iconForAction(_PageActionType type) {
    switch (type) {
      case _PageActionType.openSpreadsheetImport:
        return Icons.table_view_outlined;
      case _PageActionType.openPhotoImport:
        return Icons.photo_camera_outlined;
      case _PageActionType.viewPro:
        return Icons.workspace_premium_outlined;
      case _PageActionType.finish:
        return Icons.rocket_launch_outlined;
      case _PageActionType.pickPath:
        return Icons.alt_route;
    }
  }

  /// Pick a glyph for the secondary CTA. Reuses the same per-action
  /// mapping the primary uses so spreadsheet vs photo glyphs stay
  /// consistent regardless of which slot the action lands in.
  IconData _iconForSecondaryAction(_OnboardingPage page) {
    final type = page.secondaryActionType;
    if (type == null) return Icons.arrow_forward;
    return _iconForAction(type);
  }
}

/// "How do you track your loads today?" path-picker slide. Renders
/// three persona cards stacked vertically:
///   * Just starting out — Quick Add, beginner-friendly.
///   * I have a notebook — guided photo-import flow.
///   * I use Excel / Google Sheets — Smart Import wizard.
///
/// Each card has an icon, a title, and a one-line subtitle. Tapping a
/// card pops onboarding and opens the matching dedicated flow. The
/// pen-and-paper card is highlighted (brass tint) — surveys say it's
/// the largest cohort and we want it visually weighted.
class _PathPickerSlide extends StatelessWidget {
  const _PathPickerSlide({
    required this.title,
    required this.onPickQuickStart,
    required this.onPickNotebook,
    required this.onPickSpreadsheet,
  });

  final String title;
  final VoidCallback? onPickQuickStart;
  final VoidCallback? onPickNotebook;
  final VoidCallback? onPickSpreadsheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.alt_route,
            size: 64,
            color: AppTheme.brass,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Pick the option that sounds the most like you. '
            "You can change anything later.",
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _PathCard(
            icon: Icons.bolt_outlined,
            title: 'Just starting out',
            subtitle: 'Quick Add — type a load like you would write it.',
            onTap: onPickQuickStart,
          ),
          const SizedBox(height: 12),
          _PathCard(
            icon: Icons.menu_book_outlined,
            title: 'I have a notebook',
            subtitle: 'Photo-import a page (about 60 seconds).',
            onTap: onPickNotebook,
            highlighted: true,
          ),
          const SizedBox(height: 12),
          _PathCard(
            icon: Icons.table_view_outlined,
            title: 'I use Excel or Google Sheets',
            subtitle: 'Smart import — we will match your columns.',
            onTap: onPickSpreadsheet,
          ),
        ],
      ),
    );
  }
}

/// One persona card on the path-picker slide. Renders an icon + title
/// + subtitle in a tappable card. The notebook card is highlighted in
/// brass tint to draw attention to the largest survey cohort.
class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: highlighted
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 32,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Custom animated dot indicator — avoids adding a new dependency
/// just for this. Active dot is wider and uses the brass/primary
/// colour; inactive dots are dimmed.
class _DotIndicator extends StatelessWidget {
  const _DotIndicator({
    required this.count,
    required this.activeIndex,
    required this.activeColor,
    required this.inactiveColor,
  });

  final int count;
  final int activeIndex;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == activeIndex ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == activeIndex ? activeColor : inactiveColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
