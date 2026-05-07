import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../widgets/cartridge_diagram.dart';
import '../../widgets/pro_gate.dart';

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
          final cartridges = [...?snap.data]
            ..sort(
                (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

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
  /// Tokenize a query: split on whitespace, drop empties. Each token must
  /// appear (case-insensitively) in the cartridge name OR any alias for
  /// the cartridge to match. So `"6 GT"` matches `"6mm GT"` because tokens
  /// `"6"` and `"gt"` both appear in `"6mm gt"`.
  bool _matches(CartridgeRow c, List<String> tokens) {
    if (tokens.isEmpty) return true;
    final haystack = '${c.name} ${c.aliasesJson}'.toLowerCase();
    for (final t in tokens) {
      if (!haystack.contains(t)) return false;
    }
    return true;
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
        return widget.cartridges.where((c) => _matches(c, tokens));
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
        _ChipData(cartridge.saamiDoc!, Icons.description_outlined),
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
  const _ChipData(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.data});
  final _ChipData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(data.icon, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            data.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
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
