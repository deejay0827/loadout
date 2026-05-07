import 'package:flutter/material.dart';

import '../disclaimer/disclaimer_screen.dart';
import '../glossary/glossary_screen.dart';
import '../guide/reloading_guide_screen.dart';
import '../home/home_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../paywall/paywall_screen.dart';
import '../privacy/privacy_screen.dart';

/// Topic-based explainer screen reachable from the side drawer
/// ("How It Works"). Acts as a menu of bite-sized topic cards — each
/// opens a detail page that explains a specific feature, with an
/// optional CTA that jumps to the relevant part of the app.
///
/// The Quick Tour card at the top routes to the existing linear
/// [OnboardingScreen]; this screen replaces the drawer's direct link
/// to onboarding so users have a richer, browsable entry point.
class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final basics = _topicsForSection(_Section.basics);
    final deeper = _topicsForSection(_Section.goingDeeper);

    return Scaffold(
      appBar: AppBar(title: const Text('How It Works')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            // Header lead-in.
            Text(
              'Pick any topic — or start with the Quick Tour.',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            // Big highlighted entry card.
            _QuickTourCard(
              onTap: () => _openOnboarding(context),
            ),
            const SizedBox(height: 28),
            _SectionLabel(label: _Section.basics.label),
            const SizedBox(height: 12),
            for (final t in basics) ...[
              _TopicCard(
                topic: t,
                onTap: () => _openTopic(context, t),
              ),
              if (t != basics.last) const SizedBox(height: 10),
            ],
            const SizedBox(height: 28),
            _SectionLabel(label: _Section.goingDeeper.label),
            const SizedBox(height: 12),
            for (final t in deeper) ...[
              _TopicCard(
                topic: t,
                onTap: () => _openTopic(context, t),
              ),
              if (t != deeper.last) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  void _openOnboarding(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const OnboardingScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  void _openTopic(BuildContext context, _Topic topic) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TopicDetailScreen(topic: topic),
      ),
    );
  }
}

// ─────────────────────────── Topic data model ───────────────────────────

enum _Section {
  basics('THE BASICS'),
  goingDeeper('GOING DEEPER');

  const _Section(this.label);
  final String label;
}

enum _TopicId {
  recipes,
  firearms,
  saami,
  glossary,
  reloadingGuide,
  pro,
  privacy,
  disclaimer,
}

class _Topic {
  const _Topic({
    required this.id,
    required this.section,
    required this.icon,
    required this.title,
    required this.tagline,
    required this.body,
    required this.bullets,
    required this.ctaLabel,
  });

  final _TopicId id;
  final _Section section;
  final IconData icon;
  final String title;
  final String tagline;
  final String body;
  final List<_TopicBullet> bullets;
  final String ctaLabel;
}

class _TopicBullet {
  const _TopicBullet(this.icon, this.text);
  final IconData icon;
  final String text;
}

List<_Topic> _topicsForSection(_Section section) =>
    _allTopics.where((t) => t.section == section).toList(growable: false);

const List<_Topic> _allTopics = [
  // ─── THE BASICS ───
  _Topic(
    id: _TopicId.recipes,
    section: _Section.basics,
    icon: Icons.receipt_long,
    title: 'Recipes',
    tagline:
        'Build, edit, and search your load formulas. Toggle Basic / Detailed / All.',
    body:
        'A recipe is your specific load formula — caliber, powder, charge, '
        'bullet, primer, brass, and dimensions like COAL or CBTO. Save it, '
        'search it, edit it on the Recipes tab.\n\n'
        'Use the detail toggle at the top of any recipe to switch between '
        'Basic, Detailed, and All field views. Filter the form by typing '
        'into the search field at the top.',
    bullets: [
      _TopicBullet(Icons.search, 'Filter fields by name to find what you need fast.'),
      _TopicBullet(Icons.tune, 'Three detail levels: Basic, Detailed, All.'),
      _TopicBullet(
        Icons.folder_open,
        'Sectioned by Powder, Primer, Bullet, Brass, etc.',
      ),
    ],
    ctaLabel: 'Open Recipes',
  ),
  _Topic(
    id: _TopicId.firearms,
    section: _Section.basics,
    icon: Icons.handshake,
    title: 'Firearms',
    tagline:
        'Catalog every rifle, pistol, and shotgun. Track shots fired across recipes.',
    body:
        'Add every firearm you reload for. Pick from the reference catalog '
        '(Ruger, Tikka, Bergara, etc.) or add a custom build with your '
        'barrel, twist rate, and notes.\n\n'
        'Each firearm tracks shots fired so you can monitor barrel life over time.',
    bullets: [
      _TopicBullet(
        Icons.library_add,
        'Pick from the reference catalog or add a custom firearm.',
      ),
      _TopicBullet(Icons.timer, 'Tracks shots fired across all your recipes.'),
      _TopicBullet(Icons.tune, 'Capture barrel length, twist rate, and chambering.'),
    ],
    ctaLabel: 'Open Firearms',
  ),
  _Topic(
    id: _TopicId.saami,
    section: _Section.basics,
    icon: Icons.straighten,
    title: 'SAAMI Specs',
    tagline:
        'Look up dimensions for 200+ cartridges. Pro unlocks technical drawings.',
    body:
        'Look up authoritative cartridge dimensions for 200+ rifle, pistol, '
        'rimfire, and shotgun cartridges, sourced from SAAMI Z299.1–4 and '
        'CIP TDCC.\n\n'
        'Pick any cartridge to see bullet, case, body, neck, shoulder, and '
        'rim dimensions, plus pressure and twist-rate references.',
    bullets: [
      _TopicBullet(
        Icons.search,
        "Fuzzy search by name or alias — '6 GT' finds '6mm GT'.",
      ),
      _TopicBullet(
        Icons.straighten,
        '200+ cartridges across SAAMI and CIP standards.',
      ),
      _TopicBullet(
        Icons.image_outlined,
        'Pro: technical drawings of cartridge + chamber profiles.',
      ),
    ],
    ctaLabel: 'Open SAAMI Specs',
  ),
  _Topic(
    id: _TopicId.glossary,
    section: _Section.basics,
    icon: Icons.menu_book,
    title: 'Glossary',
    tagline: 'Quick reference for reloading terms — searchable, alphabetical.',
    body:
        'A searchable reference for reloading terms — from CBTO and shoulder '
        'bump to seating depth and headspace.\n\n'
        'Open it anytime from the side menu.',
    bullets: [
      _TopicBullet(Icons.search, 'Search across every term and definition.'),
      _TopicBullet(Icons.sort_by_alpha, 'Browse alphabetically.'),
      _TopicBullet(
        Icons.menu_book,
        'Plain-English explanations — no expert jargon.',
      ),
    ],
    ctaLabel: 'Open Glossary',
  ),

  // ─── GOING DEEPER ───
  _Topic(
    id: _TopicId.reloadingGuide,
    section: _Section.goingDeeper,
    icon: Icons.auto_stories_outlined,
    title: 'Reloading Guide',
    tagline:
        'Walk through the eight stages of reloading at a high level.',
    body:
        'An eight-stage walkthrough of the reloading process — from inspecting '
        'brass through final inspection. High-level reference, not load data.\n\n'
        'Every stage explains what it does, why it matters, common tools, and '
        'what to watch for. This is reference content; always cross-check '
        'against published manuals from your component manufacturers.',
    bullets: [
      _TopicBullet(Icons.list_alt, 'Eight chronological stages of reloading.'),
      _TopicBullet(
        Icons.warning_amber,
        'High-level — never includes specific charges or pressures.',
      ),
      _TopicBullet(
        Icons.menu_book_outlined,
        'Cross-check with published manuals before loading.',
      ),
    ],
    ctaLabel: 'Open Reloading Guide',
  ),
  _Topic(
    id: _TopicId.pro,
    section: _Section.goingDeeper,
    icon: Icons.workspace_premium_outlined,
    title: 'LoadOut Pro',
    tagline:
        'Yearly or Lifetime — unlock technical drawings, ballistics, future cloud backup.',
    body:
        'Pro unlocks the cartridge + chamber technical drawings on the SAAMI '
        'Specs page, the ballistics calculator (coming soon), and future '
        'cloud backup.\n\n'
        'Two plans — yearly subscription or lifetime one-time purchase. '
        'Restore prior purchases anytime from the paywall screen.',
    bullets: [
      _TopicBullet(
        Icons.image_outlined,
        'Cartridge + chamber technical drawings.',
      ),
      _TopicBullet(
        Icons.calculate_outlined,
        'Ballistics calculator (coming soon).',
      ),
      _TopicBullet(Icons.cloud_upload_outlined, 'Cloud backup (coming soon).'),
    ],
    ctaLabel: 'View Pro',
  ),
  _Topic(
    id: _TopicId.privacy,
    section: _Section.goingDeeper,
    icon: Icons.shield_outlined,
    title: 'Local-First & Privacy',
    tagline:
        'Your reloading data stays on this device. No cloud, no telemetry.',
    body:
        'Your reloading data — recipes, firearms, custom components — stays '
        'on this device only. We never see it, never upload it, and never '
        'share it.\n\n'
        'Firebase Auth handles your sign-in (Google, Apple, email) but no '
        'reloading data ever leaves your phone. Uninstall the app and your '
        'data is gone with it.',
    bullets: [
      _TopicBullet(Icons.shield, 'All recipe + firearm data lives on-device only.'),
      _TopicBullet(
        Icons.cloud_off,
        'No telemetry, no analytics, no third-party trackers.',
      ),
      _TopicBullet(
        Icons.delete_forever,
        "Uninstall = wipe. We can't recover your data.",
      ),
    ],
    ctaLabel: 'Privacy Details',
  ),
  _Topic(
    id: _TopicId.disclaimer,
    section: _Section.goingDeeper,
    icon: Icons.warning_amber_outlined,
    title: 'Disclaimer & Safety',
    tagline:
        'Reloading is dangerous. LoadOut is reference data — not a substitute for manuals or training.',
    body:
        'Reloading ammunition is inherently dangerous. Improper handloads can '
        'cause catastrophic firearm failure, serious injury, or death.\n\n'
        'LoadOut is reference and organizational software — not a substitute '
        'for proper training, current manufacturer load manuals, or '
        "experienced supervision. If you're new to reloading, take a class "
        'or work with someone experienced first.',
    bullets: [
      _TopicBullet(
        Icons.warning_amber,
        'Always cross-check loads with current manufacturer manuals.',
      ),
      _TopicBullet(
        Icons.school,
        "If you're new, work with someone experienced first.",
      ),
      _TopicBullet(
        Icons.menu_book,
        'LoadOut provides reference data, not a license to load.',
      ),
    ],
    ctaLabel: 'Read Disclaimer',
  ),
];

// ─────────────────────────── List items ───────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

/// The big highlighted entry card at the top of the list. Uses a brass
/// tinted background and brass border to set it apart from the regular
/// topic cards underneath.
class _QuickTourCard extends StatelessWidget {
  const _QuickTourCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brass = theme.colorScheme.primary;
    return Material(
      color: brass.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: brass.withValues(alpha: 0.55),
              width: 1.2,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: brass.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.flag_outlined, color: brass, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Take a Quick Tour',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Eight quick steps — Recipes, Firearms, SAAMI, Pro, '
                      'and safety. Two minutes.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: brass,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopicCard extends StatelessWidget {
  const _TopicCard({required this.topic, required this.onTap});
  final _Topic topic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brass = theme.colorScheme.primary;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.30),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: brass.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(topic.icon, color: brass, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topic.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      topic.tagline,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Detail screen ───────────────────────────

class _TopicDetailScreen extends StatelessWidget {
  const _TopicDetailScreen({required this.topic});
  final _Topic topic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brass = theme.colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: Text(topic.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            // Eyebrow — tiny uppercase section label above the hero.
            Text(
              topic.section.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: brass,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            // Hero icon in a circular tinted disc.
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: brass.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(topic.icon, color: brass, size: 44),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              topic.title,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              topic.body,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.55,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
              ),
            ),
            const SizedBox(height: 24),
            ...topic.bullets.map((b) => _BulletRow(bullet: b)),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => _runCta(context, topic),
              icon: const Icon(Icons.arrow_forward),
              label: Text(topic.ctaLabel),
            ),
          ],
        ),
      ),
    );
  }

  void _runCta(BuildContext context, _Topic topic) {
    switch (topic.id) {
      case _TopicId.recipes:
        _popToHomeAndSwitchTab(context, 0);
        break;
      case _TopicId.firearms:
        _popToHomeAndSwitchTab(context, 1);
        break;
      case _TopicId.saami:
        _popToHomeAndSwitchTab(context, 2);
        break;
      case _TopicId.glossary:
        _popToHomeAndPush(
          context,
          MaterialPageRoute(builder: (_) => const GlossaryScreen()),
        );
        break;
      case _TopicId.reloadingGuide:
        _popToHomeAndPush(
          context,
          MaterialPageRoute(builder: (_) => const ReloadingGuideScreen()),
        );
        break;
      case _TopicId.pro:
        _popToHomeAndPush(
          context,
          MaterialPageRoute(
            builder: (_) => const PaywallScreen(),
            fullscreenDialog: true,
          ),
        );
        break;
      case _TopicId.privacy:
        _popToHomeAndPush(
          context,
          MaterialPageRoute(builder: (_) => const PrivacyScreen()),
        );
        break;
      case _TopicId.disclaimer:
        _popToHomeAndPush(
          context,
          MaterialPageRoute(
            builder: (_) => const DisclaimerViewerScreen(),
          ),
        );
        break;
    }
  }

  /// Pops back through the topic detail and the topics index to the
  /// home shell, then switches its bottom-nav tab to [index].
  ///
  /// The home state is resolved via the [Navigator]'s context so it
  /// remains valid after [Navigator.popUntil] tears down the topic
  /// pages whose contexts we were called from.
  void _popToHomeAndSwitchTab(BuildContext context, int index) {
    final navigator = Navigator.of(context);
    final navContext = navigator.context;
    navigator.popUntil((route) => route.isFirst);
    HomeScreen.switchTab(navContext, index);
  }

  /// Pops back through the topic detail and the topics index, then
  /// pushes [route] from the home shell.
  void _popToHomeAndPush(BuildContext context, Route<void> route) {
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    navigator.push(route);
  }
}

class _BulletRow extends StatelessWidget {
  const _BulletRow({required this.bullet});
  final _TopicBullet bullet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brass = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: brass.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(bullet.icon, color: brass, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                bullet.text,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Disclaimer viewer ───────────────────────────

/// Read-only viewer for the safety disclaimer, surfaced from the
/// "Read Disclaimer" CTA on the disclaimer topic detail page. The
/// existing [DisclaimerScreen] is the first-launch acceptance gate
/// (with checkbox + accept button); this is just the body text in a
/// normal scrollable screen with a back arrow so users can re-read
/// the disclaimer at any time without re-accepting it.
class DisclaimerViewerScreen extends StatelessWidget {
  const DisclaimerViewerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Disclaimer & Safety')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: const _DisclaimerViewerBody(),
        ),
      ),
    );
  }
}

class _DisclaimerViewerBody extends StatelessWidget {
  const _DisclaimerViewerBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = theme.textTheme.titleLarge;
    final subheading = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final body = theme.textTheme.bodyMedium;

    return DefaultTextStyle.merge(
      style: body,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Important: This is reference information, not professional '
            'advice.',
            style: heading,
          ),
          const SizedBox(height: 16),
          const Text(
            'LoadOut helps you organize and reference data about reloading '
            'components, firearms, and cartridges. The information in this '
            'app — including reference catalogs of powders, bullets, primers, '
            'brass, firearms, and SAAMI cartridge specifications — is '
            'provided for informational and organizational purposes only.',
          ),
          const SizedBox(height: 16),
          Text('Reloading ammunition is inherently dangerous.',
              style: subheading),
          const SizedBox(height: 4),
          const Text(
            'Improper handloads can cause catastrophic firearm failure '
            'resulting in serious injury or death.',
          ),
          const SizedBox(height: 16),
          Text('You are responsible for verifying every recipe.',
              style: subheading),
          const SizedBox(height: 4),
          const Text(
            'Always cross-reference any recipe data against current published '
            'manuals from the powder, bullet, and firearm manufacturers '
            '(Hodgdon, Sierra, Hornady, Berger, etc.). Manufacturers update '
            'recipe data over time as components and testing equipment change.',
          ),
          const SizedBox(height: 16),
          Text('No warranty.', style: subheading),
          const SizedBox(height: 4),
          const Text(
            'LoadOut provides no warranty as to the accuracy, completeness, '
            'or safety of any data shown. Component lots vary, firearm '
            'chambers vary, and conditions vary.',
          ),
          const SizedBox(height: 16),
          Text('Your responsibility.', style: subheading),
          const SizedBox(height: 4),
          const Text('By using this app you agree that you:'),
          const SizedBox(height: 8),
          const _ViewerBullet(
            'Are of legal age to handle firearms and reloading components in '
            'your jurisdiction.',
          ),
          const _ViewerBullet(
            'Will follow all applicable federal, state, and local laws.',
          ),
          const _ViewerBullet('Will use proper safety equipment and procedures.'),
          const _ViewerBullet(
            'Will not rely on this app as your sole source of recipe data.',
          ),
          const _ViewerBullet(
            'Accept all risk associated with reloading and shooting.',
          ),
          const SizedBox(height: 16),
          Text('No professional relationship.', style: subheading),
          const SizedBox(height: 4),
          const Text(
            'LoadOut is not a substitute for instruction from a qualified '
            'handloader or gunsmith. If you are new to reloading, take a '
            'class or work with someone experienced before producing live '
            'ammunition.',
          ),
          const SizedBox(height: 16),
          Text('Liability.', style: subheading),
          const SizedBox(height: 4),
          const Text(
            'To the fullest extent permitted by law, the developer of '
            'LoadOut disclaims all liability for any damages arising from '
            'use of this app, including but not limited to property damage, '
            'personal injury, or death.',
          ),
        ],
      ),
    );
  }
}

class _ViewerBullet extends StatelessWidget {
  const _ViewerBullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8, top: 2),
            child: Text('•'),
          ),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
