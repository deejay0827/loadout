// FILE: lib/services/unit_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Global units-of-measurement preference. A `ChangeNotifier` provided once
// at the app root via `Provider` so every screen that displays a numeric
// quantity (range, velocity, length, mass, energy, temperature, wind,
// pressure) can read the user's chosen unit and convert / format the
// value at the UI boundary.
//
// The service exposes nine [UnitCategory] values and two top-level
// [UnitSystem] modes (imperial, metric). The Settings screen lets the
// user pick a master system and optionally override individual
// categories; switching the master system clears the per-category
// overrides so the user gets a clean "everything imperial" or
// "everything metric" experience.
//
// ============================================================================
// CANONICAL UNITS = IMPERIAL
// ============================================================================
// All persisted database values, the ballistics solver inputs, and the
// in-memory canonical representation are **imperial**. The conversion
// helpers below convert FROM imperial TO whatever the user picked for
// display, and the `toCanonicalX` inverse helpers convert FROM the
// user's chosen unit BACK to imperial when parsing input. The solver
// internals are never touched — conversions happen at the UI boundary
// only.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's recipe form, firearm form, ballistics calculator, and SAAMI
// screen all hard-code imperial unit suffixes ("in", "gr", "fps",
// "yd"). International users — and an increasing fraction of US precision
// shooters who track velocity in m/s — need a way to swap that. Mirroring
// the `BeginnerModeService` / `AutoSaveService` shape keeps the pattern
// consistent across the codebase.
//
// ============================================================================
// PERSISTENCE
// ============================================================================
// SharedPreferences keys:
//   * `units_system` — 'imperial' | 'metric'.
//   * `units_override_<categoryName>` — the chosen unit string for that
//     category. Only written when the user diverges from the master
//     system; cleared when the master system changes.
//
// ============================================================================
// CONVERSION TABLE (sources)
// ============================================================================
//   * 1 yard = 0.9144 m exactly (international yard, 1959).
//   * 1 fps = 0.3048 m/s exactly.
//   * 1 mph = 0.44704 m/s exactly. 1 mph = 1.609344 km/h.
//   * 1 inch = 25.4 mm exactly. 1 in = 2.54 cm.
//   * 1 grain = 1/7000 lb = 0.06479891 g (NIST).
//   * 1 ft-lb = 1.3558179483314004 J (CODATA).
//   * °F → °C: subtract 32, multiply by 5/9.
//   * 1 inHg = 33.8639 hPa = 25.4 mmHg (NIST).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — provided once at the root.
// - lib/screens/settings/settings_screen.dart — exposes the master
//   switch + per-category controls.
// - lib/screens/ballistics/ballistics_screen.dart — converts user-typed
//   inputs back to canonical imperial before the solver runs, and
//   converts solver outputs to display units for the DOPE table /
//   chart.
// - lib/screens/recipes/recipe_form_screen.dart — display-label only
//   migration; persisted DB values stay canonical (grains, inches).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads / writes `SharedPreferences` under the keys above.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Categories the user can toggle independently. Names are stable
/// (used as part of the SharedPreferences key) — adding a new category
/// is fine, but renaming an existing one will lose user preferences.
enum UnitCategory {
  range,
  velocity,
  smallLength,
  bulletWeight,
  angle,
  energy,
  temperature,
  windSpeed,
  pressure,
}

/// Master unit system. Categories with no override derive their unit
/// from this value via [UnitService.unitFor].
enum UnitSystem { imperial, metric }

/// SharedPreferences keys.
const String _kSystemKey = 'units_system';
String _overrideKey(UnitCategory cat) => 'units_override_${cat.name}';

/// Imperial unit strings (returned by [UnitService.unitFor] when system
/// = imperial and no override is set).
const String unitYd = 'yd';
const String unitFps = 'fps';
const String unitIn = 'in';
const String unitGr = 'gr';
const String unitMoa = 'MOA';
const String unitFtLb = 'ft-lbs';
const String unitDegF = 'degF';
const String unitMph = 'mph';
const String unitInHg = 'inHg';

/// Metric unit strings.
const String unitM = 'm';
const String unitMps = 'm/s';
const String unitCm = 'cm';
const String unitG = 'g';
const String unitMrad = 'MRAD';
const String unitJ = 'J';
const String unitDegC = 'degC';
const String unitKph = 'km/h';
const String unitMmHg = 'mmHg';
const String unitHpa = 'hPa';

/// Allowed unit values per category (used by Settings UI for the
/// segmented buttons + override validation).
const Map<UnitCategory, List<String>> kUnitOptions = {
  UnitCategory.range: [unitYd, unitM],
  UnitCategory.velocity: [unitFps, unitMps],
  UnitCategory.smallLength: [unitIn, unitCm],
  UnitCategory.bulletWeight: [unitGr, unitG],
  UnitCategory.angle: [unitMoa, unitMrad],
  UnitCategory.energy: [unitFtLb, unitJ],
  UnitCategory.temperature: [unitDegF, unitDegC],
  UnitCategory.windSpeed: [unitMph, unitMps, unitKph],
  UnitCategory.pressure: [unitInHg, unitMmHg, unitHpa],
};

/// The default unit used when [system] = imperial and the category has
/// no override.
const Map<UnitCategory, String> _kImperialDefaults = {
  UnitCategory.range: unitYd,
  UnitCategory.velocity: unitFps,
  UnitCategory.smallLength: unitIn,
  UnitCategory.bulletWeight: unitGr,
  UnitCategory.angle: unitMoa,
  UnitCategory.energy: unitFtLb,
  UnitCategory.temperature: unitDegF,
  UnitCategory.windSpeed: unitMph,
  UnitCategory.pressure: unitInHg,
};

/// The default unit used when [system] = metric and the category has
/// no override.
const Map<UnitCategory, String> _kMetricDefaults = {
  UnitCategory.range: unitM,
  UnitCategory.velocity: unitMps,
  UnitCategory.smallLength: unitCm,
  UnitCategory.bulletWeight: unitG,
  UnitCategory.angle: unitMrad,
  UnitCategory.energy: unitJ,
  UnitCategory.temperature: unitDegC,
  UnitCategory.windSpeed: unitMps,
  UnitCategory.pressure: unitHpa,
};

/// Pretty (display) version of a category for the Settings UI.
String unitCategoryLabel(UnitCategory cat) {
  switch (cat) {
    case UnitCategory.range:
      return 'Range';
    case UnitCategory.velocity:
      return 'Muzzle velocity';
    case UnitCategory.smallLength:
      return 'Drop & sight height';
    case UnitCategory.bulletWeight:
      return 'Bullet weight';
    case UnitCategory.angle:
      return 'Angle';
    case UnitCategory.energy:
      return 'Energy';
    case UnitCategory.temperature:
      return 'Temperature';
    case UnitCategory.windSpeed:
      return 'Wind velocity';
    case UnitCategory.pressure:
      return 'Pressure';
  }
}

/// Pretty (display) version of a unit string for the Settings UI.
/// Maps the internal codes (e.g. `degF`, `mps`) to the symbols
/// reloaders recognize (`°F`, `m/s`).
String unitDisplayLabel(String unit) {
  switch (unit) {
    case unitYd:
      return 'yd';
    case unitM:
      return 'm';
    case unitFps:
      return 'fps';
    case unitMps:
      return 'm/s';
    case unitIn:
      return 'in';
    case unitCm:
      return 'cm';
    case unitGr:
      return 'gr';
    case unitG:
      return 'g';
    case unitMoa:
      return 'MOA';
    case unitMrad:
      return 'MRAD';
    case unitFtLb:
      return 'ft-lbs';
    case unitJ:
      return 'J';
    case unitDegF:
      return '°F';
    case unitDegC:
      return '°C';
    case unitMph:
      return 'mph';
    case unitKph:
      return 'km/h';
    case unitInHg:
      return 'inHg';
    case unitMmHg:
      return 'mmHg';
    case unitHpa:
      return 'hPa';
    default:
      return unit;
  }
}

/// Global units-of-measurement preference. Provided once at app root.
class UnitService extends ChangeNotifier {
  UnitService() {
    // ignore: discarded_futures
    load();
  }

  UnitSystem _system = UnitSystem.imperial;
  final Map<UnitCategory, String> _overrides = {};
  bool _hydrated = false;

  /// True once SharedPreferences has been read. Settings UI uses this
  /// to keep from flashing default values before the saved choice
  /// arrives.
  bool get isHydrated => _hydrated;

  /// Active master system (imperial / metric).
  UnitSystem get system => _system;

  /// Map of category → override unit string. Read-only snapshot — callers
  /// must use [setOverride] / [clearOverride] to mutate.
  Map<UnitCategory, String> get overrides => Map.unmodifiable(_overrides);

  /// Hydrate from SharedPreferences. Called once from the constructor;
  /// public so tests can re-trigger it after seeding prefs.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSystemKey);
    _system = raw == 'metric' ? UnitSystem.metric : UnitSystem.imperial;
    _overrides.clear();
    for (final cat in UnitCategory.values) {
      final v = prefs.getString(_overrideKey(cat));
      if (v != null && (kUnitOptions[cat] ?? const []).contains(v)) {
        _overrides[cat] = v;
      }
    }
    _hydrated = true;
    notifyListeners();
  }

  /// Returns the unit string the user has chosen for [cat] (e.g. `"yd"`,
  /// `"m/s"`). Falls back to the master system's default when no
  /// override is set.
  String unitFor(UnitCategory cat) {
    final ov = _overrides[cat];
    if (ov != null) return ov;
    final defaults = _system == UnitSystem.imperial
        ? _kImperialDefaults
        : _kMetricDefaults;
    return defaults[cat]!;
  }

  /// Master switch. Resets every per-category override so the user
  /// gets a clean "everything imperial" or "everything metric" feel.
  Future<void> setSystem(UnitSystem s) async {
    if (_system == s && _overrides.isEmpty) return;
    _system = s;
    _overrides.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSystemKey, s == UnitSystem.metric ? 'metric' : 'imperial');
    for (final cat in UnitCategory.values) {
      await prefs.remove(_overrideKey(cat));
    }
  }

  /// Set the per-category override. The unit must appear in
  /// [kUnitOptions] for that category. If the chosen unit equals the
  /// master system's default for that category, the override is cleared
  /// instead of stored — keeps the prefs file clean.
  Future<void> setOverride(UnitCategory cat, String unit) async {
    final allowed = kUnitOptions[cat] ?? const <String>[];
    if (!allowed.contains(unit)) return;
    final defaults = _system == UnitSystem.imperial
        ? _kImperialDefaults
        : _kMetricDefaults;
    final prefs = await SharedPreferences.getInstance();
    if (defaults[cat] == unit) {
      _overrides.remove(cat);
      await prefs.remove(_overrideKey(cat));
    } else {
      _overrides[cat] = unit;
      await prefs.setString(_overrideKey(cat), unit);
    }
    notifyListeners();
  }

  /// Clear the override for a category, falling back to the master
  /// system's default.
  Future<void> clearOverride(UnitCategory cat) async {
    if (!_overrides.containsKey(cat)) return;
    _overrides.remove(cat);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_overrideKey(cat));
  }

  // ─────────────────────── Conversions: canonical → display ───────────────────────
  // The internal canonical value is always imperial (matches the solver
  // and the persisted DB columns). These helpers turn an imperial
  // number into the user's chosen display unit.

  /// Convert range from yards to whatever the user picked.
  double convertRange(double yd) {
    switch (unitFor(UnitCategory.range)) {
      case unitM:
        return yd * 0.9144;
      case unitYd:
      default:
        return yd;
    }
  }

  /// Convert velocity from fps to whatever the user picked.
  double convertVelocity(double fps) {
    switch (unitFor(UnitCategory.velocity)) {
      case unitMps:
        return fps * 0.3048;
      case unitFps:
      default:
        return fps;
    }
  }

  /// Convert a small length (inches) into the user's chosen small-length
  /// unit. Used for drop, sight height, COAL, CBTO, etc.
  double convertSmallLength(double inches) {
    switch (unitFor(UnitCategory.smallLength)) {
      case unitCm:
        return inches * 2.54;
      case unitIn:
      default:
        return inches;
    }
  }

  /// Convert bullet weight from grains to grams (or pass through).
  double convertBulletWeight(double gr) {
    switch (unitFor(UnitCategory.bulletWeight)) {
      case unitG:
        return gr * 0.06479891;
      case unitGr:
      default:
        return gr;
    }
  }

  /// Convert energy from ft-lbs to joules (or pass through).
  double convertEnergy(double ftLbs) {
    switch (unitFor(UnitCategory.energy)) {
      case unitJ:
        return ftLbs * 1.3558179483314004;
      case unitFtLb:
      default:
        return ftLbs;
    }
  }

  /// Convert temperature from °F to °C (or pass through).
  double convertTemperature(double f) {
    switch (unitFor(UnitCategory.temperature)) {
      case unitDegC:
        return (f - 32.0) * 5.0 / 9.0;
      case unitDegF:
      default:
        return f;
    }
  }

  /// Convert wind speed from mph to whatever the user picked.
  double convertWindSpeed(double mph) {
    switch (unitFor(UnitCategory.windSpeed)) {
      case unitMps:
        return mph * 0.44704;
      case unitKph:
        return mph * 1.609344;
      case unitMph:
      default:
        return mph;
    }
  }

  /// Convert pressure from inHg to whatever the user picked.
  double convertPressure(double inHg) {
    switch (unitFor(UnitCategory.pressure)) {
      case unitMmHg:
        return inHg * 25.4;
      case unitHpa:
        return inHg * 33.8639;
      case unitInHg:
      default:
        return inHg;
    }
  }

  // ─────────────────────── Inverse: display → canonical ───────────────────────
  // For parsing user-typed inputs back into imperial before storing /
  // computing.

  double toCanonicalRange(double display) {
    switch (unitFor(UnitCategory.range)) {
      case unitM:
        return display / 0.9144;
      case unitYd:
      default:
        return display;
    }
  }

  double toCanonicalVelocity(double display) {
    switch (unitFor(UnitCategory.velocity)) {
      case unitMps:
        return display / 0.3048;
      case unitFps:
      default:
        return display;
    }
  }

  double toCanonicalSmallLength(double display) {
    switch (unitFor(UnitCategory.smallLength)) {
      case unitCm:
        return display / 2.54;
      case unitIn:
      default:
        return display;
    }
  }

  double toCanonicalBulletWeight(double display) {
    switch (unitFor(UnitCategory.bulletWeight)) {
      case unitG:
        return display / 0.06479891;
      case unitGr:
      default:
        return display;
    }
  }

  double toCanonicalEnergy(double display) {
    switch (unitFor(UnitCategory.energy)) {
      case unitJ:
        return display / 1.3558179483314004;
      case unitFtLb:
      default:
        return display;
    }
  }

  double toCanonicalTemperature(double display) {
    switch (unitFor(UnitCategory.temperature)) {
      case unitDegC:
        return display * 9.0 / 5.0 + 32.0;
      case unitDegF:
      default:
        return display;
    }
  }

  double toCanonicalWindSpeed(double display) {
    switch (unitFor(UnitCategory.windSpeed)) {
      case unitMps:
        return display / 0.44704;
      case unitKph:
        return display / 1.609344;
      case unitMph:
      default:
        return display;
    }
  }

  double toCanonicalPressure(double display) {
    switch (unitFor(UnitCategory.pressure)) {
      case unitMmHg:
        return display / 25.4;
      case unitHpa:
        return display / 33.8639;
      case unitInHg:
      default:
        return display;
    }
  }

  // ─────────────────────── Display formatters ───────────────────────
  // Convenience helpers that pair the converted number with its unit
  // suffix. Most call sites are happy with a default precision; pass
  // [fractionDigits] when you need a different one.

  String formatRange(double yd, {int fractionDigits = 0}) {
    final v = convertRange(yd);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.range))}';
  }

  String formatVelocity(double fps, {int fractionDigits = 0}) {
    final v = convertVelocity(fps);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.velocity))}';
  }

  String formatSmallLength(double inches, {int fractionDigits = 2}) {
    final v = convertSmallLength(inches);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.smallLength))}';
  }

  String formatBulletWeight(double gr, {int fractionDigits = 1}) {
    final v = convertBulletWeight(gr);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.bulletWeight))}';
  }

  String formatEnergy(double ftLbs, {int fractionDigits = 0}) {
    final v = convertEnergy(ftLbs);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.energy))}';
  }

  String formatTemperature(double f, {int fractionDigits = 0}) {
    final v = convertTemperature(f);
    return '${v.toStringAsFixed(fractionDigits)}${unitDisplayLabel(unitFor(UnitCategory.temperature))}';
  }

  String formatWindSpeed(double mph, {int fractionDigits = 0}) {
    final v = convertWindSpeed(mph);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.windSpeed))}';
  }

  String formatPressure(double inHg, {int fractionDigits = 2}) {
    final v = convertPressure(inHg);
    return '${v.toStringAsFixed(fractionDigits)} ${unitDisplayLabel(unitFor(UnitCategory.pressure))}';
  }
}
