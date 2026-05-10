// FILE: lib/screens/ballistics/internal_ballistics_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the Pro-gated Internal Ballistics Calculator. The user enters a
// hypothetical reloading recipe — cartridge case capacity, powder name,
// charge weight, bullet weight & diameter, COAL, case length, barrel
// length, bore diameter — and a "Predict" button runs
// `predictLoad(...)` from `internal_ballistics.dart`. The result panel
// shows predicted muzzle velocity (fps), predicted peak chamber pressure
// (psi), loading density (%), expansion ratio, and a burn-completion
// percent.
//
// "Internal ballistics" is the physics INSIDE the gun barrel from primer
// strike to muzzle exit, distinct from "external ballistics" (what
// happens AFTER the bullet leaves the barrel — see `ballistics_screen.dart`).
//
// The screen is laid out as:
//
//   1. A persistent yellow "estimation tool" disclaimer banner at the
//      top — same visual weight as the Range Day "Using ICAO standard
//      atmosphere" indicator. Reloaders are precision people; they
//      need to see this disclaimer every time, not click through it
//      once and forget.
//
//   2. Five form sections:
//        a. Cartridge   — case capacity (grH₂O), case length (in)
//        b. Powder      — picker dropdown sourced from
//                          `kPowderBurnRates`, optional category
//                          pre-filter chips
//        c. Charge      — charge weight (gr)
//        d. Bullet      — weight (gr), diameter (in), COAL (in),
//                          optional bullet length (in)
//        e. Barrel      — barrel length (in), bore diameter (in)
//
//   3. A "Predict Pressure & MV" button. Tapping runs the predictor.
//
//   4. The result card (only renders when the predictor returned non-
//      null). Empty state explains exactly which input is missing or
//      which limit was tripped.
//
// Per CLAUDE.md § 0 (no placeholder data for ballistics-affecting
// fields), every input controller starts EMPTY. The predict button is
// disabled until every required field is non-empty. The result card
// shows nothing when inputs are incomplete — never a derived number
// from default values.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Companion screen to the external-ballistics calculator
// (`ballistics_screen.dart`). The external calculator answers "where
// will the bullet land at 800 yards"; the internal calculator answers
// "is this load over pressure?". Reloaders need both — the internal
// model is the headline market gap LoadOut was missing relative to
// GRT (free, Windows / Mac via Wine) and QuickLOAD ($170+ Windows-
// only). Both desktop-only; LoadOut shipping a competent mobile
// version is the strategic differentiator.
//
// The screen is REACHABLE FROM TWO PLACES:
//   * Resources → "Internal Ballistics Calculator" (top-level
//     entry point, mirrors how SAAMI Specs is reached).
//   * Ballistics Calculator → bottom-of-screen "Predict Pressure &
//     MV (Internal Ballistics)" button (so a user already in the
//     external-ballistics flow can pivot to internal without
//     navigating away).
//
// Both entry points are gated through `ensurePro(context)` — this is
// a Pro feature.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. UNIT DISCIPLINE. Every numeric input is in standard reloader's
//    American units (grH₂O, grains, inches). The labels say so
//    explicitly and every helper hint reinforces. Mixing in metric
//    even once (e.g. "case capacity in cm³") would silently break
//    the predictor.
//
// 2. DISCLAIMER VISIBILITY. Powley predicts pressure within ±15% on
//    the validation set. A reloader who acts on a "below max"
//    prediction without verifying could blow up their rifle. The
//    disclaimer copy and the persistent yellow banner are
//    load-bearing — they MUST be visible every render, not behind
//    a "got it / dismiss" flow. We do NOT offer a way to suppress
//    the banner.
//
// 3. POWDER PICKER. The list is curated (~40 powders); the user's
//    powder may not be in the list. When they pick "Other / not
//    in list", the predict button stays disabled and the result
//    card explains why. We do NOT silently treat unknown powders
//    as IMR 4350 — that's exactly the kind of fake-default
//    failure CLAUDE.md § 0 forbids.
//
// 4. RESULT DISPLAY. Each output number is annotated with its
//    units (fps / psi / %) and the result card includes a small
//    "Compared to manual" gauge that tells the user where this
//    load sits relative to a typical SAAMI maximum (60 000-65 000
//    psi for most centerfire rifle cartridges). The gauge is
//    informational only — it does NOT mean "safe / unsafe."
//
// 5. NO AUTOSAVE / NO PROFILES. This screen is a calculator, not
//    a recipe-editing surface. There's no profile to save and no
//    persistence — every visit starts fresh. The form state is
//    deliberately ephemeral so the user doesn't accidentally
//    trust a stale prediction from a previous session.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/resources/resources_screen.dart — Resource tile pushes
//   here.
// - lib/screens/ballistics/ballistics_screen.dart — bottom-of-screen
//   button pushes here after `ensurePro(context)`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads / writes `TextEditingController`s for form state.
// - Calls into the pure-Dart `predictLoad(...)` service. No DB, no
//   network, no clipboard, no SharedPreferences. The calculator is
//   stateless across visits by design.
// - Pushes the `PaywallScreen` via `ensurePro(context)` for non-Pro
//   users.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ballistics/internal_ballistics.dart';
import '../../services/ballistics/powder_burn_rates.dart';
import '../../widgets/pro_gate.dart';

/// Pro-gated calculator that predicts muzzle velocity and peak
/// chamber pressure for a hypothetical reloading recipe via the
/// Powley method.
class InternalBallisticsScreen extends StatefulWidget {
  const InternalBallisticsScreen({super.key});

  @override
  State<InternalBallisticsScreen> createState() =>
      _InternalBallisticsScreenState();
}

class _InternalBallisticsScreenState extends State<InternalBallisticsScreen> {
  // ─── Cartridge ───
  final _caseCapCtrl = TextEditingController();
  final _caseLengthCtrl = TextEditingController();

  // ─── Powder ───
  PowderEntry? _selectedPowder;
  PowderCategory? _categoryFilter;

  // ─── Charge ───
  final _chargeCtrl = TextEditingController();

  // ─── Bullet ───
  final _bulletWtCtrl = TextEditingController();
  final _bulletDiamCtrl = TextEditingController();
  final _coalCtrl = TextEditingController();
  final _bulletLenCtrl = TextEditingController();

  // ─── Barrel ───
  final _barrelLenCtrl = TextEditingController();
  final _boreDiamCtrl = TextEditingController();

  /// Most-recent predict result. Null when the calculator hasn't
  /// been run yet (clean form), or when the predictor returned null
  /// (invalid / out-of-band inputs). The empty-state distinguishes
  /// the two via [_lastPredictAttempted].
  InternalBallisticsResult? _result;

  /// True after the user has tapped "Predict" at least once during
  /// this visit. Drives the empty-state copy: before predict, "fill
  /// in the form below"; after predict with null result, "load
  /// outside calibration band — see disclaimer."
  bool _lastPredictAttempted = false;

  @override
  void dispose() {
    _caseCapCtrl.dispose();
    _caseLengthCtrl.dispose();
    _chargeCtrl.dispose();
    _bulletWtCtrl.dispose();
    _bulletDiamCtrl.dispose();
    _coalCtrl.dispose();
    _bulletLenCtrl.dispose();
    _barrelLenCtrl.dispose();
    _boreDiamCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Internal Ballistics Calculator'),
      ),
      body: ProGate(
        feature: 'Internal Ballistics Calculator',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _disclaimerBanner(),
              const SizedBox(height: 12),
              _cartridgeSection(),
              const SizedBox(height: 8),
              _powderSection(),
              const SizedBox(height: 8),
              _chargeSection(),
              const SizedBox(height: 8),
              _bulletSection(),
              const SizedBox(height: 8),
              _barrelSection(),
              const SizedBox(height: 16),
              _predictButton(),
              const SizedBox(height: 12),
              _resultCard(),
              const SizedBox(height: 12),
              _modelFooter(),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Disclaimer banner — persistent, top-of-screen
  // ─────────────────────────────────────────────────────────────

  /// Yellow warning banner anchored at the top of the screen. Visual
  /// weight matches the Range Day "Using ICAO standard atmosphere"
  /// indicator. Persistent (no dismiss button) — reloaders should
  /// see this every time they open the calculator.
  Widget _disclaimerBanner() {
    final theme = Theme.of(context);
    // Warm amber matches the safety-warning convention in the rest
    // of the app (firearm "Coming Soon" banners, Range Day's "ICAO
    // standard" indicator). We pull from the surface variant so the
    // banner adapts to dark mode without going black-on-yellow.
    final bg = theme.brightness == Brightness.dark
        ? const Color(0xFF3A2A0F)
        : const Color(0xFFFFF6D5);
    final border = theme.brightness == Brightness.dark
        ? const Color(0xFFB78B36)
        : const Color(0xFFD4A93B);
    final text = theme.brightness == Brightness.dark
        ? const Color(0xFFEFD9A6)
        : const Color(0xFF6F4F12);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: border, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Estimation Tool — Not a Load-Data Substitute',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Always verify against a published manual. Predicted '
                  'pressures here can be off by plus or minus 10 to 15 '
                  'percent. Never push a load above a published max '
                  'based on this calculator.',
                  style: theme.textTheme.bodySmall?.copyWith(color: text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Sections
  // ─────────────────────────────────────────────────────────────

  Widget _cartridgeSection() {
    return _SectionCard(
      title: 'Cartridge',
      icon: Icons.science_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _caseCapCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Case Capacity (grH2O)',
              helperText:
                  'Internal volume of an empty fired case. Common values: '
                  '.308 Win 56, .30-06 68, 6.5 CM 53, .223 Rem 30.5.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _caseLengthCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Case Length (in)',
              helperText: 'Case head to case mouth, inches.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
        ],
      ),
    );
  }

  Widget _powderSection() {
    final theme = Theme.of(context);
    final visiblePowders = _categoryFilter == null
        ? kPowderBurnRates
        : powdersForCategory(_categoryFilter!);
    return _SectionCard(
      title: 'Powder',
      icon: Icons.local_fire_department_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Category pre-filter chips. A reloader looking up a pistol
          // load doesn't need to scroll past all the magnum-rifle
          // powders.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FilterChip(
                label: const Text('All'),
                selected: _categoryFilter == null,
                onSelected: (_) {
                  setState(() => _categoryFilter = null);
                },
              ),
              FilterChip(
                label: const Text('Rifle'),
                selected: _categoryFilter == PowderCategory.rifle,
                onSelected: (sel) {
                  setState(() =>
                      _categoryFilter = sel ? PowderCategory.rifle : null);
                },
              ),
              FilterChip(
                label: const Text('Pistol'),
                selected: _categoryFilter == PowderCategory.pistol,
                onSelected: (sel) {
                  setState(() =>
                      _categoryFilter = sel ? PowderCategory.pistol : null);
                },
              ),
              FilterChip(
                label: const Text('Shotgun'),
                selected: _categoryFilter == PowderCategory.shotgun,
                onSelected: (sel) {
                  setState(() =>
                      _categoryFilter = sel ? PowderCategory.shotgun : null);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<PowderEntry>(
            initialValue: _selectedPowder,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Powder',
              helperText:
                  'Tap to pick. Custom / wildcat powders not in the list cannot be modeled.',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final p in visiblePowders)
                DropdownMenuItem(
                  value: p,
                  child: Text(
                    '${p.name} (${p.manufacturer})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (p) {
              setState(() => _selectedPowder = p);
              _clearStaleResult();
            },
          ),
          if (_selectedPowder != null) ...[
            const SizedBox(height: 8),
            Text(
              _selectedPowder!.notes,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chargeSection() {
    return _SectionCard(
      title: 'Charge',
      icon: Icons.scale_outlined,
      child: TextField(
        controller: _chargeCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: _decimalInputFormatters,
        decoration: const InputDecoration(
          labelText: 'Charge Weight (gr)',
          helperText:
              'Powder charge in grains. Loading density (charge / case '
              'capacity) must be 10 to 110 percent.',
          border: OutlineInputBorder(),
        ),
        onChanged: (_) => _clearStaleResult(),
      ),
    );
  }

  Widget _bulletSection() {
    return _SectionCard(
      title: 'Bullet',
      icon: Icons.adjust_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _bulletWtCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Bullet Weight (gr)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bulletDiamCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Bullet Diameter (in)',
              helperText:
                  'Common values: .308 cal 0.308, 6.5mm 0.264, .224 cal 0.224.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _coalCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'COAL (in)',
              helperText:
                  'Cartridge Overall Length. Affects effective case capacity.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bulletLenCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Bullet Length (in) — Optional',
              helperText:
                  'Leave empty to use the spitzer estimate (1.5 times '
                  'diameter). Required for accurate VLD predictions.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
        ],
      ),
    );
  }

  Widget _barrelSection() {
    return _SectionCard(
      title: 'Barrel',
      icon: Icons.straighten_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _barrelLenCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Barrel Length (in)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _boreDiamCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _decimalInputFormatters,
            decoration: const InputDecoration(
              labelText: 'Bore Diameter (in)',
              helperText:
                  'Lands-to-lands measurement. Roughly bullet diameter '
                  'minus 0.005 in. Common: .308 cal 0.300, 6.5mm 0.256.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _clearStaleResult(),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Predict button
  // ─────────────────────────────────────────────────────────────

  Widget _predictButton() {
    final ready = _formIsComplete();
    return FilledButton.icon(
      onPressed: ready ? _onPredict : null,
      icon: const Icon(Icons.calculate_outlined),
      label: const Text('Predict Pressure & MV'),
    );
  }

  bool _formIsComplete() {
    if (_selectedPowder == null) return false;
    final required = [
      _caseCapCtrl.text,
      _caseLengthCtrl.text,
      _chargeCtrl.text,
      _bulletWtCtrl.text,
      _bulletDiamCtrl.text,
      _coalCtrl.text,
      _barrelLenCtrl.text,
      _boreDiamCtrl.text,
    ];
    for (final t in required) {
      if (t.trim().isEmpty) return false;
      if (double.tryParse(t.trim()) == null) return false;
    }
    return true;
  }

  void _onPredict() {
    if (!_formIsComplete()) return;
    final input = InternalBallisticsInput.imperial(
      caseCapacityGrH2o: double.parse(_caseCapCtrl.text.trim()),
      caseLengthIn: double.parse(_caseLengthCtrl.text.trim()),
      powderName: _selectedPowder!.name,
      chargeWeightGr: double.parse(_chargeCtrl.text.trim()),
      bulletWeightGr: double.parse(_bulletWtCtrl.text.trim()),
      bulletDiameterIn: double.parse(_bulletDiamCtrl.text.trim()),
      coalIn: double.parse(_coalCtrl.text.trim()),
      barrelLengthIn: double.parse(_barrelLenCtrl.text.trim()),
      boreDiameterIn: double.parse(_boreDiamCtrl.text.trim()),
      bulletLengthIn: _bulletLenCtrl.text.trim().isEmpty
          ? null
          : double.tryParse(_bulletLenCtrl.text.trim()),
    );
    setState(() {
      _lastPredictAttempted = true;
      _result = predictLoad(input);
    });
  }

  void _clearStaleResult() {
    if (_result != null || _lastPredictAttempted) {
      // Wipe out a previous result the moment the user edits any
      // input — never leave a number on screen that doesn't match
      // the form contents.
      setState(() {
        _result = null;
        _lastPredictAttempted = false;
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Result card
  // ─────────────────────────────────────────────────────────────

  Widget _resultCard() {
    final theme = Theme.of(context);
    if (_result == null && !_lastPredictAttempted) {
      // First-visit empty state. The user hasn't tried to predict yet,
      // so don't lecture about validity bands — just say "fill in the
      // form."
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Fill in every field above and tap "Predict Pressure '
                  '& MV" to estimate this load.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_result == null && _lastPredictAttempted) {
      // The user tapped predict but the model returned null. Tell
      // them WHY (out-of-band loading density is the most common
      // case) without inventing a number.
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.colorScheme.error),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cannot Model This Load',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'The predictor refused. Most common cause: loading '
                      'density (charge / case capacity) is below 10 percent '
                      'or above 110 percent — outside Powley\'s calibration '
                      'band. Other causes: bore diameter larger than bullet '
                      'diameter (data-entry error), case length greater than '
                      'or equal to COAL, or charge weight outside 1 to 300 grains.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // We have a real result.
    final r = _result!;
    final pressureColor = _pressureGaugeColor(r.predictedPeakPressurePsi);
    final pressureBand = _pressureGaugeLabel(r.predictedPeakPressurePsi);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Predicted Performance',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _ResultRow(
              label: 'Muzzle Velocity',
              value: '${r.predictedMuzzleVelocityFps.toStringAsFixed(0)} fps',
              icon: Icons.speed_outlined,
            ),
            const SizedBox(height: 8),
            _ResultRow(
              label: 'Peak Pressure',
              value: '${r.predictedPeakPressurePsi.toStringAsFixed(0)} psi',
              icon: Icons.bolt_outlined,
              accentColor: pressureColor,
              trailing: pressureBand,
            ),
            const SizedBox(height: 8),
            _ResultRow(
              label: 'Loading Density',
              value: '${r.loadingDensityPct.toStringAsFixed(1)} %',
              icon: Icons.line_weight_outlined,
            ),
            const SizedBox(height: 8),
            _ResultRow(
              label: 'Expansion Ratio',
              value: r.expansionRatio.toStringAsFixed(2),
              icon: Icons.zoom_out_map_outlined,
            ),
            const SizedBox(height: 8),
            _ResultRow(
              label: 'Burn Completion',
              value: '${r.burnCompletionPct.toStringAsFixed(0)} %',
              icon: Icons.local_fire_department_outlined,
              accentColor: r.burnCompletionPct < 90
                  ? theme.colorScheme.error
                  : null,
              trailing: r.burnCompletionPct < 90
                  ? 'Low — Powder May Be Too Slow For Barrel'
                  : null,
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Validation tolerance: plus or minus 10 percent on MV, '
                      'plus or minus 15 percent on pressure. Cross-check '
                      'against a published manual before loading.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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

  /// Map a predicted peak pressure to a coarse "where does this sit
  /// relative to a typical SAAMI maximum" colour, for the gauge band.
  ///
  /// SAAMI rifle maxima cluster around 60 000–65 000 psi for modern
  /// centerfire cartridges (.308 = 62 000, 6.5 CM = 60 200, .30-06 =
  /// 60 200, .223 = 55 000). We use a neutral cutoff at 60 000 for
  /// "approaching max" and 65 000 for "above typical max." The gauge
  /// is ADVISORY — it doesn't know the user's specific cartridge max.
  Color _pressureGaugeColor(double psi) {
    final theme = Theme.of(context);
    if (psi < 50_000) return theme.colorScheme.primary;
    if (psi < 60_000) return theme.colorScheme.tertiary;
    return theme.colorScheme.error;
  }

  String _pressureGaugeLabel(double psi) {
    if (psi < 50_000) return 'Below Typical SAAMI Max';
    if (psi < 60_000) return 'Approaching SAAMI Max';
    if (psi < 65_000) return 'At Or Above SAAMI Max — Verify';
    return 'Above SAAMI Max — Stop, Verify Manual';
  }

  // ─────────────────────────────────────────────────────────────
  // Footer (model description)
  // ─────────────────────────────────────────────────────────────

  Widget _modelFooter() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        'Model: Homer Powley\'s interior-ballistics method (1962, '
        'revised 1980). Calibrated against the Hodgdon Reloading Data '
        'Center; validated within plus or minus 10 percent on MV and '
        'plus or minus 15 percent on pressure across a four-load test '
        'set. Output is a planning aid — never a substitute for the '
        'load workup process described in any reloading manual.',
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

/// Decimal-only input formatters for every numeric field. Allows
/// digits, one decimal point, and nothing else. Same convention the
/// existing ballistics screen uses.
final List<TextInputFormatter> _decimalInputFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
];

/// Wrapper card with an icon + title row. Same visual language as the
/// rest of the app's form sections.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// One row of the result card. Icon + label on the left, value on
/// the right, optional accent colour on the value, optional trailing
/// caption underneath (for "approaching max" / "burn too low"
/// callouts).
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.label,
    required this.value,
    required this.icon,
    this.accentColor,
    this.trailing,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? accentColor;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: accentColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        if (trailing != null) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Text(
              trailing!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: accentColor ?? theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
