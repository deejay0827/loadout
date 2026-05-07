import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ballistics/atmosphere.dart';
import '../../services/ballistics/drag_functions.dart';
import '../../services/ballistics/environment.dart';
import '../../services/ballistics/projectile.dart';
import '../../services/ballistics/solver.dart';
import '../../services/ballistics/units.dart';
import '../../widgets/pro_gate.dart';
import 'widgets/trajectory_chart.dart';

/// Top-level ballistics screen. Pro-gated.
///
/// Implements a Level 3 (Modified Point-Mass) external ballistics
/// calculator. Takes a projectile description, muzzle / zero
/// conditions, and environmental conditions (atmosphere, wind,
/// latitude / shot azimuth for Coriolis); produces a drop & wind table
/// at user-specified ranges plus a small trajectory + drift chart.
class BallisticsScreen extends StatefulWidget {
  const BallisticsScreen({super.key});

  @override
  State<BallisticsScreen> createState() => _BallisticsScreenState();
}

enum AngleUnit { inches, moa, mil }

class _BallisticsScreenState extends State<BallisticsScreen> {
  // ─────────────────────── Projectile ───────────────────────
  final _diameterCtrl = TextEditingController(text: '0.264');
  final _weightCtrl = TextEditingController(text: '140');
  final _lengthCtrl = TextEditingController(text: '1.355');
  final _bcCtrl = TextEditingController(text: '0.298');
  final _twistCtrl = TextEditingController(text: '8');
  DragModel _dragModel = DragModel.g7;

  // ─────────────────────── Muzzle / Zero ───────────────────────
  final _muzzleVelCtrl = TextEditingController(text: '2750');
  final _sightHeightCtrl = TextEditingController(text: '1.5');
  final _zeroRangeCtrl = TextEditingController(text: '100');
  final _shotAzimuthCtrl = TextEditingController(text: '0');
  final _targetElevationCtrl = TextEditingController(text: '0');

  // ─────────────────────── Environment ───────────────────────
  final _tempCtrl = TextEditingController(text: '59'); // ICAO 15°C = 59°F
  final _pressureCtrl = TextEditingController(text: '29.92');
  final _humidityCtrl = TextEditingController(text: '50');
  final _altitudeCtrl = TextEditingController(text: '0');
  final _windSpeedCtrl = TextEditingController(text: '10');
  final _windDirCtrl = TextEditingController(text: '90');
  final _latitudeCtrl = TextEditingController(text: '40');

  // ─────────────────────── Output settings ───────────────────────
  final _rangesCtrl = TextEditingController(
      text: '100, 200, 300, 400, 500, 600, 700, 800, 900, 1000');
  AngleUnit _unit = AngleUnit.moa;

  List<TrajectorySample> _samples = const [];
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _diameterCtrl,
      _weightCtrl,
      _lengthCtrl,
      _bcCtrl,
      _twistCtrl,
      _muzzleVelCtrl,
      _sightHeightCtrl,
      _zeroRangeCtrl,
      _shotAzimuthCtrl,
      _targetElevationCtrl,
      _tempCtrl,
      _pressureCtrl,
      _humidityCtrl,
      _altitudeCtrl,
      _windSpeedCtrl,
      _windDirCtrl,
      _latitudeCtrl,
      _rangesCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ─────────────────────── Compute ───────────────────────

  void _compute() {
    setState(() {
      _error = null;
    });
    try {
      final diameter = _parsePos(_diameterCtrl.text, 'Bullet diameter');
      final weight = _parsePos(_weightCtrl.text, 'Bullet weight');
      final bc = _parsePos(_bcCtrl.text, 'BC');
      final twist = _parseOpt(_twistCtrl.text);
      final length = _parseOpt(_lengthCtrl.text);

      final mv = _parsePos(_muzzleVelCtrl.text, 'Muzzle velocity');
      final sightHeight = _parsePos(_sightHeightCtrl.text, 'Sight height');
      final zeroRange = _parsePos(_zeroRangeCtrl.text, 'Zero range');
      final shotAzimuth = double.tryParse(_shotAzimuthCtrl.text.trim()) ?? 0.0;

      final temp = _parseAny(_tempCtrl.text, 'Temperature');
      final pressure = _parsePos(_pressureCtrl.text, 'Pressure');
      final humidity = _parseAny(_humidityCtrl.text, 'Humidity');
      final altitude = _parseAny(_altitudeCtrl.text, 'Altitude');
      final windSpeed = double.tryParse(_windSpeedCtrl.text.trim()) ?? 0;
      final windDir = double.tryParse(_windDirCtrl.text.trim()) ?? 0;
      final latitude = double.tryParse(_latitudeCtrl.text.trim()) ?? 0;
      final tgtElev = double.tryParse(_targetElevationCtrl.text.trim()) ?? 0;

      final ranges = _parseRanges(_rangesCtrl.text);
      if (ranges.isEmpty) {
        throw const FormatException('Add at least one output range.');
      }

      final projectile = Projectile(
        diameterIn: diameter,
        weightGr: weight,
        bc: bc,
        dragModel: _dragModel,
        lengthIn: length,
        twistInches: twist,
      );
      final atmosphere = Atmosphere.station(
        tempF: temp,
        stationPressureInHg: pressure,
        humidityPct: humidity,
        altitudeFt: altitude,
      );
      final environment = Environment.fromImperial(
        atmosphere: atmosphere,
        windSpeedMph: windSpeed,
        windFromDegrees: windDir,
        shotAzimuthDegrees: shotAzimuth,
        latitudeDegrees: latitude,
        targetElevationFt: tgtElev,
      );
      final shot = ShotInputs(
        muzzleVelocityFps: mv,
        sightHeightIn: sightHeight,
        zeroRangeYards: zeroRange,
      );

      final samples = solveTrajectory(
        projectile: projectile,
        environment: environment,
        shot: shot,
        sampleRangesYards: ranges,
      );

      setState(() {
        _samples = samples;
      });
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
        _samples = const [];
      });
    } catch (e) {
      setState(() {
        _error = 'Could not solve: $e';
        _samples = const [];
      });
    }
  }

  double _parsePos(String s, String label) {
    final v = double.tryParse(s.trim());
    if (v == null || v <= 0) {
      throw FormatException('$label must be a positive number.');
    }
    return v;
  }

  double _parseAny(String s, String label) {
    final v = double.tryParse(s.trim());
    if (v == null) {
      throw FormatException('$label is invalid.');
    }
    return v;
  }

  double? _parseOpt(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  List<double> _parseRanges(String s) {
    final out = <double>{};
    for (final part in s.split(RegExp(r'[,\s]+'))) {
      if (part.isEmpty) continue;
      final v = double.tryParse(part);
      if (v != null && v > 0) out.add(v);
    }
    return out.toList()..sort();
  }

  // ─────────────────────── Export ───────────────────────

  Future<void> _exportDope() async {
    if (_samples.isEmpty) return;
    final buf = StringBuffer();
    buf.writeln('LoadOut DOPE card');
    buf.writeln('-----------------');
    buf.writeln('MV: ${_muzzleVelCtrl.text} fps');
    buf.writeln('Bullet: ${_weightCtrl.text} gr ${_diameterCtrl.text}" '
        '(${_dragModel.short} BC ${_bcCtrl.text})');
    buf.writeln('Zero: ${_zeroRangeCtrl.text} yd, '
        'sight ${_sightHeightCtrl.text}" above bore');
    buf.writeln('Twist: ${_twistCtrl.text}"');
    buf.writeln('Wind: ${_windSpeedCtrl.text} mph from '
        '${_windDirCtrl.text}°');
    buf.writeln('Temp: ${_tempCtrl.text}°F  '
        'Pressure: ${_pressureCtrl.text} inHg  '
        'RH: ${_humidityCtrl.text}%');
    buf.writeln('');
    buf.writeln(
        'Range   Drop      Wind     Velocity  Energy  ToF    Mach');
    for (final s in _samples) {
      buf.writeln('${s.rangeYards.toStringAsFixed(0).padLeft(4)} yd  '
          '${_fmtAngle(s.dropInches, s.rangeYards).padLeft(8)}  '
          '${_fmtAngle(s.windDriftInches, s.rangeYards).padLeft(7)}  '
          '${s.velocityFps.toStringAsFixed(0).padLeft(6)} fps  '
          '${s.energyFtLb.toStringAsFixed(0).padLeft(5)}  '
          '${s.timeSec.toStringAsFixed(2).padLeft(5)}s  '
          '${s.machNumber.toStringAsFixed(2)}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('DOPE card copied to clipboard')),
    );
  }

  String _fmtAngle(double inches, double yards) {
    switch (_unit) {
      case AngleUnit.inches:
        return '${inches.toStringAsFixed(1)}"';
      case AngleUnit.moa:
        if (yards <= 0) return '—';
        return '${inchesToMoaAtYards(inches, yards).toStringAsFixed(1)} M';
      case AngleUnit.mil:
        if (yards <= 0) return '—';
        return '${inchesToMilAtYards(inches, yards).toStringAsFixed(2)} mil';
    }
  }

  // ─────────────────────── Build ───────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ballistics Calculator'),
      ),
      body: ProGate(
        feature: 'Ballistics Calculator',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _projectileSection(),
              const SizedBox(height: 8),
              _muzzleZeroSection(),
              const SizedBox(height: 8),
              _environmentSection(),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _compute,
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Calculate Trajectory'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              _outputSection(),
              const SizedBox(height: 16),
              _DisclaimerFooter(),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────── Sections ───────────────────────

  Widget _projectileSection() {
    return _SectionCard(
      title: 'Projectile',
      icon: Icons.album_outlined,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _diameterCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Diameter (in)',
                    helperText: 'e.g. 0.264 for 6.5mm',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _weightCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Weight (gr)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lengthCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Length (in, optional)',
                    helperText: 'For Miller stability calc',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _twistCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Twist (1:in)',
                    helperText: 'e.g. 8 for 1:8',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bcCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'BC',
                    helperText: 'In the chosen drag-model family',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<DragModel>(
                  initialValue: _dragModel,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Drag function',
                  ),
                  items: [
                    for (final m in DragModel.values)
                      DropdownMenuItem(
                        value: m,
                        child: Text(m.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _dragModel = v);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _muzzleZeroSection() {
    return _SectionCard(
      title: 'Muzzle / Zero',
      icon: Icons.center_focus_strong_outlined,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _muzzleVelCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Muzzle velocity (fps)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _sightHeightCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Sight height (in)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _zeroRangeCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Zero range (yd)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _shotAzimuthCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: 'Shot azimuth (°)',
                    helperText: '0 = north (Coriolis)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetElevationCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Target elevation Δ (ft)',
              helperText: 'Positive = uphill',
            ),
          ),
        ],
      ),
    );
  }

  Widget _environmentSection() {
    return _SectionCard(
      title: 'Environment',
      icon: Icons.air_outlined,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tempCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: 'Temperature (°F)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pressureCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Pressure (inHg)',
                    helperText: 'Station, not corrected',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _humidityCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Humidity (%)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _altitudeCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: 'Elevation (ft)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _windSpeedCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Wind (mph)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _windDirCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Wind from (°)',
                    helperText: '0=tail, 90=right',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _latitudeCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Latitude (°N)',
              helperText: 'Used by Coriolis',
            ),
          ),
        ],
      ),
    );
  }

  Widget _outputSection() {
    return _SectionCard(
      title: 'Output',
      icon: Icons.table_rows_outlined,
      initiallyExpanded: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _rangesCtrl,
            decoration: const InputDecoration(
              labelText: 'Sample ranges (yd, comma-separated)',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<AngleUnit>(
                  segments: const [
                    ButtonSegment(
                      value: AngleUnit.inches,
                      label: Text('Inch'),
                    ),
                    ButtonSegment(
                      value: AngleUnit.moa,
                      label: Text('MOA'),
                    ),
                    ButtonSegment(
                      value: AngleUnit.mil,
                      label: Text('Mil'),
                    ),
                  ],
                  selected: {_unit},
                  onSelectionChanged: (s) {
                    setState(() => _unit = s.first);
                  },
                  showSelectedIcon: false,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_samples.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Run "Calculate Trajectory" to generate the drop table.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            )
          else ...[
            _DopeTable(samples: _samples, unit: _unit),
            const SizedBox(height: 16),
            TrajectoryChart(samples: _samples),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _exportDope,
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Export DOPE card to clipboard'),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────── Section card ───────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyExpanded = true,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Row(
          children: [
            Container(
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
                  Icon(icon, size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        children: [child],
      ),
    );
  }
}

// ─────────────────────── DOPE table ───────────────────────

class _DopeTable extends StatelessWidget {
  const _DopeTable({required this.samples, required this.unit});

  final List<TrajectorySample> samples;
  final AngleUnit unit;

  String _fmtAngle(double inches, double yards) {
    switch (unit) {
      case AngleUnit.inches:
        return inches.toStringAsFixed(1);
      case AngleUnit.moa:
        if (yards <= 0) return '—';
        return inchesToMoaAtYards(inches, yards).toStringAsFixed(1);
      case AngleUnit.mil:
        if (yards <= 0) return '—';
        return inchesToMilAtYards(inches, yards).toStringAsFixed(2);
    }
  }

  String get _unitSuffix {
    switch (unit) {
      case AngleUnit.inches:
        return 'in';
      case AngleUnit.moa:
        return 'MOA';
      case AngleUnit.mil:
        return 'mil';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final cellStyle = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        columnSpacing: 18,
        columns: [
          DataColumn(label: Text('Range', style: headerStyle)),
          DataColumn(
              label: Text('Drop ($_unitSuffix)', style: headerStyle),
              numeric: true),
          DataColumn(
              label: Text('Wind ($_unitSuffix)', style: headerStyle),
              numeric: true),
          DataColumn(
              label: Text('Vel (fps)', style: headerStyle), numeric: true),
          DataColumn(
              label: Text('Energy (ft·lb)', style: headerStyle),
              numeric: true),
          DataColumn(
              label: Text('ToF (s)', style: headerStyle), numeric: true),
          DataColumn(
              label: Text('Mach', style: headerStyle), numeric: true),
        ],
        rows: [
          for (final s in samples)
            DataRow(
              cells: [
                DataCell(
                  Text('${s.rangeYards.toStringAsFixed(0)} yd',
                      style: cellStyle),
                ),
                DataCell(Text(_fmtAngle(s.dropInches, s.rangeYards),
                    style: cellStyle)),
                DataCell(Text(_fmtAngle(s.windDriftInches, s.rangeYards),
                    style: cellStyle)),
                DataCell(Text(s.velocityFps.toStringAsFixed(0),
                    style: cellStyle)),
                DataCell(Text(s.energyFtLb.toStringAsFixed(0),
                    style: cellStyle)),
                DataCell(
                    Text(s.timeSec.toStringAsFixed(2), style: cellStyle)),
                DataCell(
                    Text(s.machNumber.toStringAsFixed(2), style: cellStyle)),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────── Disclaimer ───────────────────────

class _DisclaimerFooter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        'Solver is a Modified Point-Mass (MPM) model with G1/G7 standard drag '
        'curves and Litz spin-drift correction. Output is a planning aid; '
        'verify in the field before relying on these numbers for any '
        'consequential shot.',
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
