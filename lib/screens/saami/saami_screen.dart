// FILE: lib/screens/saami/saami_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The SAAMI Specs tab — tab 4 of `HomeScreen`'s bottom nav. A read-only
// reference surface. The user picks a cartridge from a fuzzy-search
// `_CartridgePicker`, and the screen renders a richly detailed
// breakdown sourced from the `Cartridges` Drift table:
//
// * `_HeaderCard` — large name + chips for type, case subtype, SAAMI
//   doc reference, parent case, and year introduced; an "Also Known
//   As" list of aliases.
// * `_DimensionsCard` — bullet diameter, case length, max COAL, body
//   diameter, neck and shoulder geometry (when applicable), rim
//   diameter / thickness. For non-bottleneck cases the shoulder
//   /neck-length / base-to-shoulder rows are hidden entirely.
// * `_BoreRiflingCard` — bore + groove diameter and twist rate.
// * `_PressurePrimingCard` — max average pressure (PSI) and primer
//   type.
// * `_ShotgunCard` — replaces the dimensions/bore/pressure trio for
//   `cartridge.type == 'shotgun'`; renders gauge, shell length, and
//   max average pressure.
// * `_DiagramsSection` — Pro-gated parametric `CartridgeDiagram`
//   widgets (cartridge profile + chamber profile) wrapped in a
//   `ProGate(feature: ...)`.
// * `_DisclaimerFooter` — italicised reminder that values are
//   reference, not gospel.
//
// The whole layout lives inside a single `CustomScrollView`. The
// picker is a non-pinned `SliverToBoxAdapter` at the top; the
// currently-selected cartridge name is a small pinned
// `SliverPersistentHeader` with `_SelectedNameHeaderDelegate` so the
// label stays visible while the user scrolls through long detail
// cards.
//
// `_Format` is a small static helper class with `diameter`, `length`,
// `angle`, `pressure`, `primerType`, and `gauge` formatters. Each one
// returns the em-dash `—` for nulls so missing values render
// uniformly across cards.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reloaders cross-reference SAAMI and CIP cartridge specifications
// constantly — case length, max COAL, max average pressure, neck
// diameter — and bouncing to a PDF mid-process is a friction point.
// LoadOut bundles the reference data as JSON (see
// `assets/seed_data/cartridges.json`) and seeds it into the local
// `Cartridges` table, so this tab is fully offline-capable. It's
// docked at bottom-nav slot 4.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The cartridge picker was originally a `DropdownMenu`. That broke
// hard when wrapped in a pinned `SliverPersistentHeader`: the
// menu's overlay positioning is computed against the
// `OverlayEntry`'s ancestor `RenderObject` chain, and pinning the
// header causes the chain's layout constraints to mutate during the
// same frame the overlay is being placed. The result was a
// `!semantics.parentDataDirty` layout-loop assertion on every
// frame — the screen would render but the picker overlay flashed
// off in debug builds.
//
// The fix was to (a) replace `DropdownMenu` with `Autocomplete<CartridgeRow>`
// for fuzzy token-matching search, and (b) leave the picker in a
// non-pinned `SliverToBoxAdapter` so its overlay positions against
// stable layout. Only the small static cartridge-name chip is
// pinned via `SliverPersistentHeader`, because it has no overlay
// or focus concerns.
//
// `_CartridgePicker._matches` is the search heuristic: split the
// query on whitespace, drop empties, and require every remaining
// token to appear (case-insensitively) in either the cartridge name
// or the JSON-encoded aliases blob. So `"6 GT"` matches `"6mm GT"`
// because the tokens `"6"` and `"gt"` both appear in `"6mm gt"`.
// The OS-level autocorrect / autocomplete suggestions on the picker
// field are explicitly disabled (`autocorrect: false`,
// `enableSuggestions: false`, `textCapitalization: none`) — cartridge
// names are short technical strings the OS shouldn't be guessing
// at, and we'd had a user report a "get x" suggestion chip
// appearing.
//
// `_DimensionsCard._hasShoulder` is a small but important detail:
// straight-wall and tapered straight cases (most pistol cartridges,
// .45-70, .350 Legend, etc.) don't have a defined shoulder, and
// SAAMI doesn't publish shoulder / neck-length / base-to-shoulder
// dimensions for them. The card hides those rows entirely instead
// of rendering em-dashes that look like missing data. The check is
// `caseSubtype.contains('bottleneck')` — both `"bottleneck"` and
// `"bottleneck-belted"` qualify.
//
// `CartridgeDiagram` integration is Pro-gated: the entire diagrams
// section is wrapped in `ProGate(feature: 'Visual Cartridge & Chamber
// Diagrams', child: ...)`. Free users see the pro-gate's upgrade
// affordance; Pro users see the parametric drawings.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — slotted at index 4 of
//   `_pages` and rendered inside the `IndexedStack`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Subscribes to `ComponentRepository.watchCartridges()` for the
//   lifetime of the StreamBuilder.
// - No writes — the screen is read-only.
// - Renders `CartridgeDiagram` widgets, which are pure CustomPainters.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/database.dart';
import '../../utils/natural_sort.dart';
import '../../repositories/component_repository.dart';
import '../../widgets/cartridge_diagram.dart';
import '../../widgets/pro_gate.dart';

// Public PDF URLs for the four ANSI/SAAMI standard documents. Anything
// outside this map (or a malformed value) falls back to the SAAMI
// standards index page.
const String _saamiStandardsIndexUrl =
    'https://saami.org/technical-information/ansi-saami-standards/';
const Map<String, String> _saamiDocUrls = <String, String>{
  'Z299.1':
      'https://saami.org/wp-content/uploads/2026/04/SAAMI-Z299.1-R2026-Rimfire-FINAL-Approved-2026-04-10.pdf',
  'Z299.2':
      'https://saami.org/wp-content/uploads/2025/09/ANSI-SAAMI-Z299.2-Shotshell-2019-Approved-2025-09-23.pdf',
  'Z299.3':
      'https://saami.org/wp-content/uploads/2025/05/SAAMI-Z299.3-2022-Centerfire-Pistol-Revolver-Approved-12-13-2022.pdf',
  'Z299.4':
      'https://saami.org/wp-content/uploads/2026/04/SAAMI-Z299.4-CFR-2025-Centerfire-Rifle-Approved-2-10-2025-2026-04-27.pdf',
};

/// Returns the PDF URL for a SAAMI doc string, or the standards index page
/// when the doc isn't recognized. Trims whitespace and is case-sensitive
/// against the known set (the catalog produces canonical `Z299.x` strings).
String _saamiUrlForDoc(String? doc) {
  final key = doc?.trim() ?? '';
  return _saamiDocUrls[key] ?? _saamiStandardsIndexUrl;
}

/// Open [url] in the platform browser / PDF viewer. Falls back to the
/// standards index page if the platform cannot launch the original URL.
Future<void> _openSaamiUrl(String url) async {
  final uri = Uri.parse(url);
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
  } catch (_) {
    // fall through to the index URL
  }
  final fallback = Uri.parse(_saamiStandardsIndexUrl);
  // Best-effort. If even the index cannot open we silently no-op rather
  // than throwing inside an onTap.
  try {
    await launchUrl(fallback, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// SAAMI/CIP reference screen. Pick a cartridge, then see a richly detailed
/// breakdown of its dimensions, pressure / priming spec, bore + rifling info,
/// and (for Pro users) parametric cartridge + chamber diagrams.
class SaamiScreen extends StatefulWidget {
  const SaamiScreen({super.key});

  @override
  State<SaamiScreen> createState() => _SaamiScreenState();
}

class _SaamiScreenState extends State<SaamiScreen> {
  String? _selectedName;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ComponentRepository>();
    return Scaffold(
      body: StreamBuilder<List<CartridgeRow>>(
        stream: repo.watchCartridges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          // Natural sort so cartridge calibers order numerically:
          // .22 LR < 5.56 NATO < 6mm < 6.5 < 8mm < 9mm < 10mm < .30-06 …
          // Pure lexicographic sort would put "10mm" before "8mm" and
          // ".30-06" right next to ".308".
          final cartridges = [...?snap.data]
            ..sort((a, b) => naturalCompare(a.name, b.name));

          if (cartridges.isEmpty) {
            return const Center(child: Text('No cartridge data available.'));
          }

          // Drop selection if it's no longer in the list (seed reset etc.).
          if (_selectedName != null &&
              !cartridges.any((c) => c.name == _selectedName)) {
            _selectedName = null;
          }

          final selected = _selectedName == null
              ? null
              : cartridges.firstWhere((c) => c.name == _selectedName);

          // The picker uses Autocomplete, which positions an overlay below
          // the field. Wrapping it in a pinned SliverPersistentHeader breaks
          // the overlay positioning and triggers a layout-loop assertion
          // (`!semantics.parentDataDirty`). Keep the picker as a normal
          // (non-pinned) sliver at the top, and only pin the small cartridge
          // name chip — that one is static text with no overlay or focus
          // concerns, so it's safe inside a SliverPersistentHeader.
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: _CartridgePicker(
                    cartridges: cartridges,
                    selectedName: _selectedName,
                    onChanged: (name) => setState(() => _selectedName = name),
                  ),
                ),
              ),
              if (selected != null)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SelectedNameHeaderDelegate(name: selected.name),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                sliver: SliverList.list(
                  children: selected == null
                      ? [const _EmptyState()]
                      : [
                          _HeaderCard(cartridge: selected),
                          const SizedBox(height: 12),
                          if (selected.type != 'shotgun') ...[
                            _DimensionsCard(cartridge: selected),
                            const SizedBox(height: 12),
                            _BoreRiflingCard(cartridge: selected),
                            const SizedBox(height: 12),
                            _PressurePrimingCard(cartridge: selected),
                            const SizedBox(height: 12),
                          ] else ...[
                            _ShotgunCard(cartridge: selected),
                            const SizedBox(height: 12),
                          ],
                          _DiagramsSection(cartridge: selected),
                          const SizedBox(height: 16),
                          const _DisclaimerFooter(),
                        ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────── Sticky header ───────────────────────

class _SelectedNameHeaderDelegate extends SliverPersistentHeaderDelegate {
  _SelectedNameHeaderDelegate({required this.name});
  final String name;

  @override
  double get minExtent => 44;
  @override
  double get maxExtent => 44;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          name,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SelectedNameHeaderDelegate oldDelegate) =>
      oldDelegate.name != name;
}

// ─────────────────────── Picker ───────────────────────

class _CartridgePicker extends StatefulWidget {
  const _CartridgePicker({
    required this.cartridges,
    required this.selectedName,
    required this.onChanged,
  });

  final List<CartridgeRow> cartridges;
  final String? selectedName;
  final ValueChanged<String?> onChanged;

  @override
  State<_CartridgePicker> createState() => _CartridgePickerState();
}

class _CartridgePickerState extends State<_CartridgePicker> {
  /// Maximum number of suggestions to show. The relevance scorer below
  /// will TECHNICALLY match many low-quality candidates (e.g. ".50 BMG"
  /// for the query "9 mm" via the substring "99mm" in an alias) — capping
  /// keeps those off-screen.
  static const int _maxResults = 30;

  /// Score a cartridge against a query for relevance ranking.
  ///
  /// Bug #5 background: a naïve "every token must appear in the
  /// haystack" filter makes "9 mm" match anything whose name or alias
  /// contains both a "9" and an "mm" anywhere — `.50 BMG` (via the
  /// `12.7x99mm` alias), `.357 Magnum` (via `9x33mmR`), `.380 ACP`
  /// (via `9mm Browning Short`), `.44 Magnum` (via `10.9x33mmR`),
  /// etc. The user expected "9 mm" to surface 9mm Luger first, not
  /// 16 unrelated cartridges.
  ///
  /// Returns 0 for "no match"; cartridges with score 0 are filtered
  /// out. Higher scores come first. Capped at the top [_maxResults]
  /// to keep the dropdown manageable.
  int _score(CartridgeRow c, String fullQuery, List<String> tokens) {
    if (tokens.isEmpty) return 1;
    final name = c.name.toLowerCase();
    final aliases = c.aliasesJson.toLowerCase();
    final fullQueryNoSpaces = fullQuery.replaceAll(RegExp(r'\s+'), '');

    var score = 0;

    // Highest-priority: name starts with the FULL query as typed.
    if (fullQuery.isNotEmpty && name.startsWith(fullQuery)) {
      score += 1000;
    }
    // Name contains the full query as a continuous substring.
    if (fullQuery.isNotEmpty && name.contains(fullQuery)) {
      score += 500;
    }
    // The whitespace-stripped boosts only fire when the query
    // actually contained whitespace — otherwise they double-count
    // with the boosts above.
    if (fullQueryNoSpaces.isNotEmpty && fullQueryNoSpaces != fullQuery) {
      // Name starts with the whitespace-stripped query — covers
      // "9 mm" → "9mm Luger" / "9mm Makarov" preference.
      if (name.startsWith(fullQueryNoSpaces)) {
        score += 300;
      }
      // Name contains the query with whitespace removed — so "9 mm"
      // matches "9mm" inside "9mm Luger" or "7.62x39mm".
      if (name.contains(fullQueryNoSpaces)) {
        score += 200;
      }
    }

    // Every token appears anywhere in the name.
    final allTokensInName = tokens.every(name.contains);
    if (allTokensInName) {
      score += 100;
    }

    // Aliases — counted when there's no strong name match, to keep
    // things like ".50 BMG" (alias `12.7x99mm`) from outranking
    // `9mm Luger` for a "9 mm" query. We do still award an alias
    // exact / contains bonus even when the name matched, because an
    // alias-exact match (e.g. "6 GT" → 6mm GT) is a legitimate
    // signal worth ranking above same-name-score peers.
    if (fullQuery.isNotEmpty && aliases.contains(fullQuery)) {
      score += 80;
    }
    if (!allTokensInName) {
      final allTokensInAliases = tokens.every(aliases.contains);
      if (allTokensInAliases) {
        score += 50;
      } else {
        // Partial alias matches earn a small score — used as tie
        // breaker for partial matches on rare cartridges.
        var partial = 0;
        for (final t in tokens) {
          if (aliases.contains(t)) partial++;
        }
        if (partial > 0 && partial < tokens.length) {
          score += partial * 10;
        }
      }
    }

    return score;
  }

  @override
  Widget build(BuildContext context) {
    return Autocomplete<CartridgeRow>(
      initialValue:
          TextEditingValue(text: widget.selectedName ?? ''),
      displayStringForOption: (c) => c.name,
      optionsBuilder: (te) {
        final query = te.text.trim().toLowerCase();
        final tokens = query
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList(growable: false);
        // No query → show all cartridges (already alphabetized upstream).
        if (tokens.isEmpty) return widget.cartridges;

        // Score every cartridge against the query, drop zeros, sort
        // descending, then cap to keep the dropdown manageable.
        final scored = <({CartridgeRow row, int score})>[];
        for (final c in widget.cartridges) {
          final s = _score(c, query, tokens);
          if (s > 0) scored.add((row: c, score: s));
        }
        scored.sort((a, b) {
          final cmp = b.score.compareTo(a.score);
          if (cmp != 0) return cmp;
          // Tie-break with natural sort so .22 < 5.56 < 6mm < 9mm < 10mm.
          return naturalCompare(a.row.name, b.row.name);
        });
        return scored.take(_maxResults).map((e) => e.row);
      },
      fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) {
        return TextFormField(
          controller: textCtrl,
          focusNode: focusNode,
          // Turn off the OS-level autocorrect / autocomplete suggestions
          // ("get x" chip the user reported). Cartridge names are short
          // technical strings that the OS shouldn't be guessing at.
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          decoration: InputDecoration(
            labelText: 'Cartridge',
            prefixIcon: const Icon(Icons.search),
            // Clear button when there's text.
            suffixIcon: textCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      textCtrl.clear();
                      widget.onChanged(null);
                    },
                  ),
          ),
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
      onSelected: (c) => widget.onChanged(c.name),
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final c = options.elementAt(i);
                  return ListTile(
                    dense: true,
                    title: Text(c.name),
                    onTap: () => onSelected(c),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.straighten,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Pick a cartridge to see its specifications',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Header ───────────────────────

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.cartridge});
  final CartridgeRow cartridge;

  List<String> _aliases() {
    try {
      return (json.decode(cartridge.aliasesJson) as List<dynamic>)
          .cast<String>();
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aliases = _aliases();
    final chips = <_ChipData>[
      _ChipData(_capitalize(cartridge.type), Icons.label_outline),
      if (cartridge.caseSubtype != null)
        _ChipData(_humanizeSubtype(cartridge.caseSubtype!), Icons.straighten),
      if (cartridge.saamiDoc != null)
        _ChipData(
          cartridge.saamiDoc!,
          Icons.description_outlined,
          // Tapping the SAAMI doc chip opens the relevant ANSI/SAAMI
          // standards PDF in the platform browser. Unrecognized values
          // fall back to the standards index page.
          onTap: () => _openSaamiUrl(_saamiUrlForDoc(cartridge.saamiDoc)),
        ),
      if (cartridge.parentCase != null)
        _ChipData('Parent: ${cartridge.parentCase}',
            Icons.account_tree_outlined),
      if (cartridge.yearIntroduced != null)
        _ChipData('${cartridge.yearIntroduced}', Icons.event_outlined),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              cartridge.name,
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 28),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final c in chips) _Chip(data: c)],
            ),
            if (aliases.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Also Known As',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                aliases.join(' • '),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static String _humanizeSubtype(String s) {
    return s
        .split('-')
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}

class _ChipData {
  const _ChipData(this.label, this.icon, {this.onTap});
  final String label;
  final IconData icon;

  /// When non-null the chip becomes tappable (used for the SAAMI doc
  /// link). The chip also gains a small `open_in_new` glyph + an
  /// underlined label so it is visually distinguishable from the static
  /// chips next to it.
  final VoidCallback? onTap;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.data});
  final _ChipData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLink = data.onTap != null;
    final borderRadius = BorderRadius.circular(8);
    final textStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w500,
      decoration: isLink ? TextDecoration.underline : null,
      decorationColor: isLink ? theme.colorScheme.primary : null,
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(data.icon, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(data.label, style: textStyle),
          if (isLink) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.open_in_new,
              size: 12,
              color: theme.colorScheme.primary,
            ),
          ],
        ],
      ),
    );

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: borderRadius,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: content,
    );

    if (!isLink) return decorated;

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: data.onTap,
        child: decorated,
      ),
    );
  }
}

// ─────────────────────── Specs ───────────────────────

class _DimensionsCard extends StatelessWidget {
  const _DimensionsCard({required this.cartridge});
  final CartridgeRow cartridge;

  /// Whether this case has a defined shoulder. Straight-wall and tapered
  /// straight cases (most pistol cartridges, .45-70, .350 Legend, etc.) do
  /// not — and SAAMI does not define shoulder/neck-length/base-to-shoulder
  /// dimensions for them. We hide those rows entirely instead of rendering
  /// a row of em-dashes that look like missing data.
  bool get _hasShoulder {
    final s = cartridge.caseSubtype ?? '';
    return s.contains('bottleneck');
  }

  @override
  Widget build(BuildContext context) {
    final c = cartridge;
    final shoulder = _hasShoulder;
    final rows = <_KV>[
      _KV('Bullet Diameter', _Format.diameter(c.bulletDiameterIn)),
      _KV('Case Length', _Format.length(c.caseLengthIn)),
      _KV('Max COAL', _Format.length(c.maxCoalIn)),
      _KV('Body Diameter', _Format.diameter(c.bodyDiameterIn)),
      if (shoulder) ...[
        _KV('Shoulder Diameter', _Format.diameter(c.shoulderDiameterIn)),
        _KV('Shoulder Angle', _Format.angle(c.shoulderAngleDeg)),
      ],
      _KV('Neck Diameter', _Format.diameter(c.neckDiameterIn)),
      if (shoulder) ...[
        _KV('Neck Length', _Format.length(c.neckLengthIn)),
        _KV('Base to Shoulder', _Format.length(c.baseToShoulderIn)),
        _KV('Base to Neck', _Format.length(c.baseToNeckIn)),
      ],
      _KV('Rim Diameter', _Format.diameter(c.rimDiameterIn)),
      _KV('Rim Thickness', _Format.length(c.rimThicknessIn)),
    ];

    return _Section(
      title: 'Cartridge Dimensions',
      child: _KVList(rows: rows),
    );
  }
}

class _BoreRiflingCard extends StatelessWidget {
  const _BoreRiflingCard({required this.cartridge});
  final CartridgeRow cartridge;

  @override
  Widget build(BuildContext context) {
    final rows = <_KV>[
      _KV('Bore Diameter', _Format.diameter(cartridge.boreDiameterIn)),
      _KV('Groove Diameter', _Format.diameter(cartridge.grooveDiameterIn)),
      _KV('Twist Rate', cartridge.twistRate ?? '—'),
    ];
    return _Section(
      title: 'Bore & Rifling',
      child: _KVList(rows: rows),
    );
  }
}

class _PressurePrimingCard extends StatelessWidget {
  const _PressurePrimingCard({required this.cartridge});
  final CartridgeRow cartridge;

  @override
  Widget build(BuildContext context) {
    final rows = <_KV>[
      _KV('Max Avg Pressure', _Format.pressure(cartridge.maxAvgPressurePsi)),
      _KV('Primer Type', _Format.primerType(cartridge.primerType)),
    ];
    return _Section(
      title: 'Pressure & Priming',
      child: _KVList(rows: rows),
    );
  }
}

class _ShotgunCard extends StatelessWidget {
  const _ShotgunCard({required this.cartridge});
  final CartridgeRow cartridge;

  @override
  Widget build(BuildContext context) {
    final rows = <_KV>[
      _KV('Gauge', _Format.gauge(cartridge.gauge)),
      _KV('Shell Length', _Format.length(cartridge.shellLengthIn)),
      _KV('Max Avg Pressure', _Format.pressure(cartridge.maxAvgPressurePsi)),
    ];
    return _Section(
      title: 'Shotshell',
      child: _KVList(rows: rows),
    );
  }
}

// ─────────────────────── Diagrams ───────────────────────

class _DiagramsSection extends StatelessWidget {
  const _DiagramsSection({required this.cartridge});
  final CartridgeRow cartridge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Section(
      title: 'Technical Drawings',
      child: ProGate(
        feature: 'Visual Cartridge & Chamber Diagrams',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Cartridge Profile',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            CartridgeDiagram(
              cartridge: cartridge,
              mode: DiagramMode.cartridge,
            ),
            const SizedBox(height: 24),
            Text(
              'Chamber Profile',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            CartridgeDiagram(
              cartridge: cartridge,
              mode: DiagramMode.chamber,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Layout primitives ───────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _KV {
  const _KV(this.label, this.value);
  final String label;
  final String value;
}

class _KVList extends StatelessWidget {
  const _KVList({required this.rows});
  final List<_KV> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.18),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    rows[i].label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    rows[i].value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _DisclaimerFooter extends StatelessWidget {
  const _DisclaimerFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
      child: Text(
        'Dimensions are SAAMI/CIP reference values where available. '
        "Always verify against current SAAMI specifications and your specific "
        "firearm's chamber drawing before reloading. "
        'Consult an official load manual for pressure data.',
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ─────────────────────── Formatting helpers ───────────────────────

class _Format {
  static const String _dash = '—';

  static String diameter(double? d) {
    if (d == null) return _dash;
    return d >= 0.5
        ? '${d.toStringAsFixed(2)} in'
        : '${d.toStringAsFixed(3)} in';
  }

  static String length(double? l) {
    if (l == null) return _dash;
    return l >= 0.5
        ? '${l.toStringAsFixed(2)} in'
        : '${l.toStringAsFixed(3)} in';
  }

  static String angle(double? a) {
    if (a == null) return _dash;
    final asInt = a.truncateToDouble() == a;
    return asInt ? '${a.toStringAsFixed(0)}°' : '${a.toStringAsFixed(1)}°';
  }

  static String pressure(int? psi) {
    if (psi == null) return _dash;
    final s = psi.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '$buf PSI';
  }

  static String primerType(String? t) {
    if (t == null) return _dash;
    return t
        .split('-')
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  static String gauge(double? g) {
    if (g == null) return _dash;
    if (g > 50) return '.410 bore';
    final asInt = g.truncateToDouble() == g;
    return asInt ? g.toStringAsFixed(0) : g.toString();
  }
}
