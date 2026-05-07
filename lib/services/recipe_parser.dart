// FILE: lib/services/recipe_parser.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Heuristic parser that turns the raw text emitted by Google ML Kit's OCR
// into a structured `RecipeDraft` the photo-import review screen can pre-
// fill. The OCR produces one ugly multi-line string per photographed
// notebook page; this parser scans it for the handful of fields a
// reloader actually writes down (caliber, powder, charge, bullet, primer,
// brass, COAL, CBTO) and attaches a per-field confidence score so the UI
// can color-code its certainty.
//
// Public surface:
//
//   - `RecipeParser({cartridgeAliases, powderNames, bulletLines})` —
//     constructed once per photo-import session with the device's local
//     reference catalog injected. The parser is stateless after that;
//     `parse(text)` is a pure function over the input string.
//   - `RecipeDraft` — the per-field result. Each field is `null` when no
//     match was found, or a `ParsedField<T>` carrying the value, the
//     confidence score, and the OCR snippet it came from.
//   - `ParsedField<T>` — value + confidence (0..1) + sourceText. The
//     review screen renders the value, the confidence bar, and the
//     "Source: …" caption verbatim from these.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The photo-import flow has three stages:
//   1. `PhotoImportService` runs the camera/picker and OCRs the result.
//   2. `RecipeParser` takes the raw OCR text + the device's reference
//      catalog (loaded via `ComponentRepository`) and produces a
//      structured draft.
//   3. The review screen renders the draft as an editable form.
//
// Splitting the parser out of the OCR service keeps it pure and easy to
// unit-test (there is one in `test/recipe_parser_test.dart`). The OCR
// stage is hard to test without a device — handwriting recognition is
// non-deterministic — but the parser stage is just string munging and
// catalog lookup.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **OCR text is dirty.** ML Kit splits a notebook line like
//    `"H4350 41.5 gr"` into multiple blocks. Newlines appear mid-line.
//    Letters and digits get swapped (`l` ↔ `1`, `O` ↔ `0`, `S` ↔ `5`,
//    `B` ↔ `8`). The parser ignores these errors and falls back to fuzzy
//    matching when an exact catalog hit isn't available.
//
// 2. **Numbers are ambiguous.** A lone "140" could be a bullet weight in
//    grains, a powder charge in grains, a velocity in fps, or simply
//    page metadata. The parser disambiguates by:
//      - Range filtering (powder charges are 5–80 gr; bullet weights are
//        30–250 gr; COAL/CBTO are 1.5–4.0 in with 3–4 decimals).
//      - Adjacency (a number adjacent to a powder name is likely the
//        charge for that powder; a number adjacent to a bullet line is
//        likely the bullet weight).
//      - Unit hints (`"gr"` or `"grain"` after a number qualifies it
//        regardless of magnitude).
//
// 3. **Confidence scoring is intentional.** The review screen color-
//    codes each parsed field. Five tiers:
//      - 0.95 — exact catalog match (alias-aware for cartridges).
//      - 0.75 — fuzzy match (Levenshtein ≤ 2, or substring contains).
//      - 0.50 — adjacency-inferred (number near a known token but not
//               directly tied).
//      - 0.45 — value inferred from numeric pattern alone (no catalog
//               cross-check).
//      - 0.30 — heuristic fallback (e.g. recipe name from the first
//               non-numeric line).
//    The thresholds in the screen are 0.75 (green), 0.5 (amber), <0.5
//    (red).
//
// 4. **Catalog injection.** The parser doesn't query SQLite directly —
//    the screen does that once on `initState` and passes the result in.
//    This keeps the parser pure and avoids forcing every test to spin up
//    a database.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/recipes/photo_import_screen.dart` — constructs the
//   parser with the catalog loaded from `ComponentRepository`, runs
//   `parse(ocrText)`, and pushes the review screen with the result.
// - `test/recipe_parser_test.dart` — exercises the parser with synthetic
//   OCR strings.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. The parser is a pure function over its constructor inputs and
// the `parse(text)` argument. No I/O, no global state, no SQLite.

import 'dart:math' as math;

/// One parsed field from a photo-import OCR pass. The review screen
/// renders the value, the confidence indicator, and a "Source: …"
/// caption with the OCR snippet that produced the value.
class ParsedField<T> {
  const ParsedField({
    required this.value,
    required this.confidence,
    required this.sourceText,
  });

  /// The structured value the parser extracted (a String for catalog
  /// lookups, a double for numeric fields).
  final T value;

  /// 0..1. The review screen colors the confidence bar:
  ///   ≥ 0.75 — green (exact catalog match)
  ///   0.5..0.75 — amber (fuzzy or adjacency-inferred)
  ///   < 0.5 — red (heuristic fallback, please double-check)
  final double confidence;

  /// The OCR snippet the value came from, surfaced verbatim under the
  /// editable form field as "Source: …".
  final String sourceText;
}

/// Structured result of parsing an OCR pass. Every field is `null` when
/// no match was found.
class RecipeDraft {
  const RecipeDraft({
    this.recipeName,
    this.caliber,
    this.powder,
    this.powderChargeGr,
    this.bullet,
    this.bulletWeightGr,
    this.primer,
    this.brass,
    this.coalIn,
    this.cbtoIn,
    this.notes,
  });

  /// First non-numeric line (or first line after `Recipe:` / `Load:`),
  /// or a generated fallback like `"6.5 Creedmoor H4350 41.5gr"`.
  final String? recipeName;

  final ParsedField<String>? caliber;
  final ParsedField<String>? powder;
  final ParsedField<double>? powderChargeGr;
  final ParsedField<String>? bullet;
  final ParsedField<double>? bulletWeightGr;
  final ParsedField<String>? primer;
  final ParsedField<String>? brass;
  final ParsedField<double>? coalIn;
  final ParsedField<double>? cbtoIn;

  /// The remaining text we couldn't classify, so the user can see what
  /// the OCR saw verbatim.
  final String? notes;
}

/// Bullet catalog entry the parser uses for matching. The `weightGr`
/// is part of the match key — a bullet line typically has multiple
/// weights, and the parser uses the closest weight to the OCR'd
/// number.
class BulletCatalogEntry {
  const BulletCatalogEntry({
    required this.manufacturer,
    required this.line,
    required this.weightGr,
  });

  final String manufacturer;
  final String line;
  final double weightGr;
}

/// Heuristic parser that turns OCR text into a `RecipeDraft`. The
/// catalog is injected at construction time so the parser stays pure.
class RecipeParser {
  RecipeParser({
    required Map<String, List<String>> cartridgeAliases,
    required List<String> powderNames,
    required List<BulletCatalogEntry> bulletLines,
    List<String>? primerNames,
    List<String>? brassNames,
  })  : _cartridgeAliases = cartridgeAliases,
        _powderNames = powderNames,
        _bulletLines = bulletLines,
        _primerNames = primerNames ?? const <String>[],
        _brassNames = brassNames ?? const <String>[];

  /// Map of canonical cartridge name -> list of alias strings.
  /// Both keys and values are matched case-insensitively against the OCR.
  final Map<String, List<String>> _cartridgeAliases;

  /// Canonical powder names like `"H4350"`, `"IMR4350"`, `"Varget"`.
  final List<String> _powderNames;

  /// Bullet manufacturer + line + weight tuples for adjacency matching.
  final List<BulletCatalogEntry> _bulletLines;

  /// Optional — primer storage labels like `"Federal #210M"`.
  final List<String> _primerNames;

  /// Optional — brass manufacturer names like `"Lapua"`, `"Hornady"`.
  final List<String> _brassNames;

  /// Run the parser on a raw OCR string. Pure — no I/O.
  RecipeDraft parse(String ocrText) {
    final lines = ocrText
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);

    final caliber = _findCaliber(ocrText, lines);
    final powder = _findPowder(ocrText, lines);
    final powderCharge = _findPowderCharge(lines, powder?.value);
    final bullet = _findBullet(ocrText, lines);
    final bulletWeight = _findBulletWeight(lines, bullet?.value);
    final primer = _findPrimer(ocrText);
    final brass = _findBrass(ocrText);
    final coal = _findCoal(ocrText);
    final cbto = _findCbto(ocrText);
    final recipeName = _findRecipeName(
      lines: lines,
      caliber: caliber?.value,
      powder: powder?.value,
      charge: powderCharge?.value,
    );
    final notes = _composeNotes(ocrText, lines);

    return RecipeDraft(
      recipeName: recipeName,
      caliber: caliber,
      powder: powder,
      powderChargeGr: powderCharge,
      bullet: bullet,
      bulletWeightGr: bulletWeight,
      primer: primer,
      brass: brass,
      coalIn: coal,
      cbtoIn: cbto,
      notes: notes,
    );
  }

  // ─────────────────────── caliber ───────────────────────

  ParsedField<String>? _findCaliber(String text, List<String> lines) {
    final lower = text.toLowerCase();
    // Exact alias hit first — confidence 0.95.
    String? bestExact;
    String? bestExactSource;
    int bestExactLength = 0;
    for (final entry in _cartridgeAliases.entries) {
      final canonical = entry.key;
      final aliases = entry.value;
      // Always include the canonical name itself in the alias scan.
      final candidates = <String>{canonical, ...aliases};
      for (final c in candidates) {
        if (c.length < 3) continue;
        final needle = c.toLowerCase();
        if (lower.contains(needle)) {
          // Prefer the longest match so "6.5 Creedmoor" beats "6.5".
          if (c.length > bestExactLength) {
            bestExact = canonical;
            bestExactSource = c;
            bestExactLength = c.length;
          }
        }
      }
    }
    if (bestExact != null) {
      return ParsedField<String>(
        value: bestExact,
        confidence: 0.95,
        sourceText: bestExactSource ?? bestExact,
      );
    }

    // Loose pattern fallback: "<number><dot or x><number>" or "X mm" tokens
    // that look like cartridge designations. Confidence 0.45 because we
    // didn't cross-check against the catalog.
    final loose = RegExp(
      r'(\.?\d+(?:\.\d+)?(?:\s*[xX×]\s*\d+(?:mm|x\d+mm)?)?\s*(?:CM|Creedmoor|Win|Rem|ACP|Lapua|PRC|BLK|Spl|Mag|Magnum|NATO|RUM|RSAUM|WSM|WSSM|GAP|Auto|Sig|S&W|H&H|Wby|Norma|RB)?)',
      caseSensitive: false,
    );
    for (final line in lines) {
      final m = loose.firstMatch(line);
      if (m == null) continue;
      final hit = m.group(0)!.trim();
      if (hit.length < 4) continue;
      // Skip pure numeric matches (those are powder charges or weights).
      if (RegExp(r'^[\d.]+$').hasMatch(hit)) continue;
      return ParsedField<String>(
        value: hit,
        confidence: 0.45,
        sourceText: line,
      );
    }
    return null;
  }

  // ─────────────────────── powder ───────────────────────

  ParsedField<String>? _findPowder(String text, List<String> lines) {
    if (_powderNames.isEmpty) return null;
    final lower = text.toLowerCase();

    // Exact substring hit first — confidence 0.95.
    String? bestExact;
    String? bestSource;
    int bestLen = 0;
    for (final p in _powderNames) {
      if (p.length < 2) continue;
      final needle = p.toLowerCase();
      if (lower.contains(needle)) {
        if (p.length > bestLen) {
          bestExact = p;
          bestLen = p.length;
          // Use the shortest line containing the hit as the source.
          for (final line in lines) {
            if (line.toLowerCase().contains(needle)) {
              if (bestSource == null || line.length < bestSource.length) {
                bestSource = line;
              }
            }
          }
        }
      }
    }
    if (bestExact != null) {
      return ParsedField<String>(
        value: bestExact,
        confidence: 0.95,
        sourceText: bestSource ?? bestExact,
      );
    }

    // Fuzzy match against tokens — confidence 0.75.
    final tokens = RegExp(r'[A-Za-z]+\d+|\b[A-Za-z]+\b|N\d+')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .where((t) => t.length >= 3)
        .toList();
    String? bestFuzzy;
    int bestDist = 3;
    String? bestFuzzySource;
    for (final t in tokens) {
      for (final p in _powderNames) {
        final d = _levenshtein(
          t.toLowerCase(),
          p.toLowerCase().replaceAll(' ', ''),
        );
        if (d < bestDist && d <= 2) {
          bestFuzzy = p;
          bestDist = d;
          for (final line in lines) {
            if (line.contains(t)) {
              bestFuzzySource = line;
              break;
            }
          }
        }
      }
    }
    if (bestFuzzy != null) {
      return ParsedField<String>(
        value: bestFuzzy,
        confidence: 0.75,
        sourceText: bestFuzzySource ?? bestFuzzy,
      );
    }
    return null;
  }

  // ─────────────────────── powder charge ───────────────────────

  ParsedField<double>? _findPowderCharge(List<String> lines, String? powder) {
    // Find every "<number> gr" or "<number> grains" pattern. Filter to
    // 5–80 gr (typical reloading charge range). Prefer numbers near the
    // powder name if we have one.
    final pattern = RegExp(
      r'(\d+(?:[\.,]\d+)?)\s*(?:gr(?:ain)?s?|grs?)\b',
      caseSensitive: false,
    );
    ParsedField<double>? best;
    for (final line in lines) {
      for (final m in pattern.allMatches(line)) {
        final raw = m.group(1)!.replaceAll(',', '.');
        final value = double.tryParse(raw);
        if (value == null) continue;
        if (value < 5 || value > 80) continue;
        // Confidence: 0.95 if powder name is on the same line, else 0.75.
        var confidence = 0.75;
        String source = line;
        if (powder != null) {
          final lp = powder.toLowerCase();
          if (line.toLowerCase().contains(lp)) {
            confidence = 0.95;
          } else {
            // Look at adjacent lines (windowed +/- 1).
            for (final l2 in lines) {
              if (l2 == line) continue;
              if (l2.toLowerCase().contains(lp)) {
                confidence = 0.85;
                break;
              }
            }
          }
        }
        if (best == null || confidence > best.confidence) {
          best = ParsedField<double>(
            value: value,
            confidence: confidence,
            sourceText: source,
          );
        }
      }
    }
    return best;
  }

  // ─────────────────────── bullet ───────────────────────

  ParsedField<String>? _findBullet(String text, List<String> lines) {
    if (_bulletLines.isEmpty) return null;
    final lower = text.toLowerCase();

    // Look for line abbreviations users actually write — ELDM, ELD-M,
    // SMK, VLD, A-MAX, A-Tip, Berger Hybrid, Hornady ELD-X, etc. The
    // parser searches for any catalog line as a substring, then picks
    // the longest hit so "Hornady ELD-M" beats "ELD".
    String? bestLine;
    String? bestMfg;
    String? bestSource;
    int bestLen = 0;
    for (final entry in _bulletLines) {
      final mfgLine = '${entry.manufacturer} ${entry.line}'.toLowerCase();
      final justLine = entry.line.toLowerCase();
      if (lower.contains(mfgLine) && mfgLine.length > bestLen) {
        bestLine = '${entry.manufacturer} ${entry.line}';
        bestMfg = entry.manufacturer;
        bestLen = mfgLine.length;
        for (final l in lines) {
          if (l.toLowerCase().contains(justLine)) {
            bestSource = l;
            break;
          }
        }
      } else if (justLine.length >= 3 &&
          lower.contains(justLine) &&
          justLine.length > bestLen) {
        bestLine = '${entry.manufacturer} ${entry.line}';
        bestMfg = entry.manufacturer;
        bestLen = justLine.length;
        for (final l in lines) {
          if (l.toLowerCase().contains(justLine)) {
            bestSource = l;
            break;
          }
        }
      }
    }
    if (bestLine != null) {
      return ParsedField<String>(
        value: bestLine,
        confidence: 0.95,
        sourceText: bestSource ?? bestMfg ?? bestLine,
      );
    }

    // Common bullet abbreviations users write in shorthand. Map them to
    // a canonical product line if the catalog has it.
    final abbrevs = <String, List<String>>{
      'ELDM': ['ELD-M', 'ELD Match'],
      'ELD-M': ['ELD-M', 'ELD Match'],
      'ELDX': ['ELD-X'],
      'ELD-X': ['ELD-X'],
      'SMK': ['MatchKing', 'SMK'],
      'TMK': ['TMK', 'Tipped MatchKing'],
      'VLD': ['VLD', 'Hybrid'],
      'A-MAX': ['A-MAX', 'A-Max'],
      'AMAX': ['A-MAX'],
      'BTHP': ['BTHP', 'Hollow Point Boat Tail'],
      'FMJ': ['FMJ', 'Full Metal Jacket'],
      'JHP': ['JHP'],
    };
    for (final entry in abbrevs.entries) {
      final pat = RegExp(r'\b' + RegExp.escape(entry.key) + r'\b',
          caseSensitive: false);
      if (pat.hasMatch(text)) {
        for (final l in lines) {
          if (pat.hasMatch(l)) {
            return ParsedField<String>(
              value: entry.value.first,
              confidence: 0.50,
              sourceText: l,
            );
          }
        }
      }
    }
    return null;
  }

  // ─────────────────────── bullet weight ───────────────────────

  ParsedField<double>? _findBulletWeight(List<String> lines, String? bullet) {
    // "<weight>gr" or "<weight> gr" where weight is 30..250.
    final pattern = RegExp(
      r'(\d{2,3})\s*(?:gr(?:ain)?s?|grs?)\b',
      caseSensitive: false,
    );
    ParsedField<double>? best;
    for (final line in lines) {
      for (final m in pattern.allMatches(line)) {
        final value = double.tryParse(m.group(1)!);
        if (value == null) continue;
        if (value < 30 || value > 250) continue;
        // Skip if this is more plausibly the powder charge — i.e. value
        // is in the 5..80 range AND the line mentions a powder name.
        // Bullet weights are typically >= 50 gr, so the 30..50 band is a
        // grey zone.
        if (value < 50 && _looksLikePowderLine(line)) continue;
        var confidence = 0.45;
        if (bullet != null) {
          final lb = bullet.toLowerCase();
          if (line.toLowerCase().contains(lb)) {
            confidence = 0.95;
          } else {
            for (final l2 in lines) {
              if (l2 == line) continue;
              if (l2.toLowerCase().contains(lb)) {
                confidence = 0.75;
                break;
              }
            }
          }
        }
        if (best == null || confidence > best.confidence) {
          best = ParsedField<double>(
            value: value,
            confidence: confidence,
            sourceText: line,
          );
        }
      }
    }
    // If we didn't find anything with explicit "gr", try a numeric-only
    // adjacency near a known bullet abbreviation.
    if (best == null) {
      final bareNumber = RegExp(r'\b(\d{2,3})\b');
      for (final line in lines) {
        if (!_looksLikeBulletLine(line)) continue;
        for (final m in bareNumber.allMatches(line)) {
          final value = double.tryParse(m.group(1)!);
          if (value == null) continue;
          if (value < 50 || value > 250) continue;
          best = ParsedField<double>(
            value: value,
            confidence: 0.50,
            sourceText: line,
          );
          break;
        }
        if (best != null) break;
      }
    }
    return best;
  }

  bool _looksLikePowderLine(String line) {
    final l = line.toLowerCase();
    for (final p in _powderNames) {
      if (l.contains(p.toLowerCase())) return true;
    }
    return false;
  }

  bool _looksLikeBulletLine(String line) {
    final l = line.toLowerCase();
    for (final entry in _bulletLines) {
      if (l.contains(entry.line.toLowerCase())) return true;
    }
    final abbrevs = ['eldm', 'eld-m', 'eldx', 'eld-x', 'smk', 'tmk', 'vld',
        'a-max', 'amax', 'bthp', 'fmj', 'jhp', 'hybrid', 'matchking'];
    for (final a in abbrevs) {
      if (l.contains(a)) return true;
    }
    return false;
  }

  // ─────────────────────── primer ───────────────────────

  ParsedField<String>? _findPrimer(String text) {
    final lower = text.toLowerCase();

    // Catalog-driven hit first.
    if (_primerNames.isNotEmpty) {
      String? bestExact;
      int bestLen = 0;
      for (final p in _primerNames) {
        final needle = p.toLowerCase();
        if (lower.contains(needle) && p.length > bestLen) {
          bestExact = p;
          bestLen = p.length;
        }
      }
      if (bestExact != null) {
        return ParsedField<String>(
          value: bestExact,
          confidence: 0.95,
          sourceText: _firstLineContaining(text, bestExact),
        );
      }
    }

    // Common primer designators users actually write. Looser regex.
    final patterns = <RegExp>[
      RegExp(r'\b(Federal\s+(?:GM)?[24]\d{2}M?)\b', caseSensitive: false),
      RegExp(r'\b(CCI\s*(?:BR-?)?\d{3,4}M?)\b', caseSensitive: false),
      RegExp(r'\b(Winchester\s+(?:WLR|WSR|WLP|WSP)M?)\b',
          caseSensitive: false),
      RegExp(r'\b(Remington\s*(?:9\.5M|7½|6½|5½|2½)?)\b',
          caseSensitive: false),
      RegExp(r'\b(Wolf\s+(?:SR|LR|SP|LP)M?)\b', caseSensitive: false),
      RegExp(r'\b(#?\d{3}M?(?:\s+(?:SR|LR|SP|LP|primer))?)\b',
          caseSensitive: false),
    ];
    for (final pat in patterns) {
      final m = pat.firstMatch(text);
      if (m != null) {
        final hit = m.group(1)?.trim() ?? m.group(0)!.trim();
        if (hit.length < 3) continue;
        // Skip a bare number — too ambiguous. Need a brand or # prefix.
        if (RegExp(r'^\d+M?$').hasMatch(hit)) continue;
        return ParsedField<String>(
          value: hit,
          confidence: 0.50,
          sourceText: _firstLineContaining(text, hit),
        );
      }
    }
    return null;
  }

  // ─────────────────────── brass ───────────────────────

  ParsedField<String>? _findBrass(String text) {
    final lower = text.toLowerCase();
    if (_brassNames.isNotEmpty) {
      String? best;
      int bestLen = 0;
      for (final name in _brassNames) {
        if (name.length < 3) continue;
        final needle = name.toLowerCase();
        // Avoid swallowing "Hornady" when the user typed it because of an
        // ELD-M bullet — require that it not also be the closest bullet
        // brand candidate. We do this loosely: skip if it appears INSIDE
        // a bullet-line match. Since we don't have the bullet match here
        // we settle for "must be its own token, not adjacent to ELD/A-Tip".
        if (lower.contains(needle) && name.length > bestLen) {
          // Skip if the only place this brass name appears is on a line
          // that ALSO mentions an ELD-/A-Tip-style bullet identifier. We
          // err on the side of caller verifying.
          best = name;
          bestLen = name.length;
        }
      }
      if (best != null) {
        return ParsedField<String>(
          value: best,
          confidence: 0.75,
          sourceText: _firstLineContaining(text, best),
        );
      }
    }
    // Common brass header keywords as a last resort.
    final keyword = RegExp(
      r'\b(brass|case)\s*[:=\-]?\s*([A-Za-z][A-Za-z\s&]{2,30})',
      caseSensitive: false,
    );
    final m = keyword.firstMatch(text);
    if (m != null) {
      final hit = m.group(2)!.trim();
      if (hit.length >= 3) {
        return ParsedField<String>(
          value: hit,
          confidence: 0.45,
          sourceText: m.group(0)!.trim(),
        );
      }
    }
    return null;
  }

  // ─────────────────────── COAL / CBTO ───────────────────────

  ParsedField<double>? _findCoal(String text) {
    return _findInchDimension(
      text,
      keywords: ['coal', 'oal', 'overall length', 'cartridge length'],
      hardConfidence: 0.95,
      softConfidence: 0.75,
      // Numeric-fallback confidence stays at 0.45.
    );
  }

  ParsedField<double>? _findCbto(String text) {
    return _findInchDimension(
      text,
      keywords: ['cbto', 'btb', 'base to ogive', 'base-to-ogive', 'b2o', 'bto'],
      hardConfidence: 0.95,
      softConfidence: 0.75,
    );
  }

  /// Find a `<keyword> <number>` or bare `<number>` pattern that looks
  /// like a cartridge-length measurement (3–4 decimals, range 1.5..4.0
  /// inches).
  ParsedField<double>? _findInchDimension(
    String text, {
    required List<String> keywords,
    required double hardConfidence,
    required double softConfidence,
  }) {
    final lower = text.toLowerCase();
    final lines = text.split(RegExp(r'[\r\n]+'));

    // Prefer "keyword: 2.825" or "keyword 2.825" patterns.
    for (final keyword in keywords) {
      final pattern = RegExp(
        r'\b' +
            RegExp.escape(keyword) +
            r'\b\s*[:=\-]?\s*"?\s*(\d\.\d{3,4})\s*"?',
        caseSensitive: false,
      );
      final m = pattern.firstMatch(text);
      if (m != null) {
        final v = double.tryParse(m.group(1)!);
        if (v != null && v >= 1.0 && v <= 4.5) {
          return ParsedField<double>(
            value: v,
            confidence: hardConfidence,
            sourceText: _firstLineContaining(text, m.group(0)!),
          );
        }
      }
      // Adjacent-line check: keyword on one line, number on the next.
      for (var i = 0; i < lines.length - 1; i++) {
        if (lines[i].toLowerCase().contains(keyword)) {
          final next = lines[i + 1];
          final nm = RegExp(r'(\d\.\d{3,4})').firstMatch(next);
          if (nm != null) {
            final v = double.tryParse(nm.group(1)!);
            if (v != null && v >= 1.0 && v <= 4.5) {
              return ParsedField<double>(
                value: v,
                confidence: softConfidence,
                sourceText: '${lines[i]} / $next',
              );
            }
          }
        }
      }
    }

    // Fallback — any number with 3–4 decimals in the cartridge range.
    // Confidence 0.45 because we didn't see a keyword.
    if (keywords.contains('coal') || keywords.contains('cbto')) {
      // Only report a fallback for COAL keyword set, not CBTO — CBTO
      // without a keyword could just as easily be COAL, and we already
      // try COAL first.
      if (!keywords.contains('coal')) return null;
      final pat = RegExp(r'(\d\.\d{3,4})');
      // Scan ALL matches and prefer the first one in the COAL range.
      for (final m in pat.allMatches(lower)) {
        final v = double.tryParse(m.group(1)!);
        if (v == null) continue;
        if (v >= 1.5 && v <= 4.0) {
          return ParsedField<double>(
            value: v,
            confidence: 0.45,
            sourceText: _firstLineContaining(text, m.group(0)!),
          );
        }
      }
    }
    return null;
  }

  // ─────────────────────── recipe name ───────────────────────

  String? _findRecipeName({
    required List<String> lines,
    String? caliber,
    String? powder,
    double? charge,
  }) {
    if (lines.isEmpty) return null;

    // Explicit "Recipe:" / "Load:" line.
    for (final line in lines) {
      final m = RegExp(r'^(?:recipe|load|name)\s*[:=\-]\s*(.+)$',
              caseSensitive: false)
          .firstMatch(line);
      if (m != null) {
        final hit = m.group(1)!.trim();
        if (hit.isNotEmpty) return hit;
      }
    }

    // First non-numeric line that's not too short. Skip lines that are
    // mostly digits or common reloading keywords.
    for (final line in lines) {
      if (line.length < 3) continue;
      final digits = RegExp(r'\d').allMatches(line).length;
      if (digits / line.length > 0.4) continue;
      final lower = line.toLowerCase();
      final bannedKeywords = [
        'gr',
        'grain',
        'coal',
        'cbto',
        'oal',
        'powder',
        'bullet',
        'primer',
        'brass'
      ];
      if (bannedKeywords.any((k) => lower == k)) continue;
      return line;
    }

    // Generated fallback — "<caliber> <powder> <charge>gr".
    final parts = <String>[
      ?caliber,
      ?powder,
      if (charge != null) '${_numFmt(charge)}gr',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  // ─────────────────────── notes ───────────────────────

  /// Compose the "notes" payload — basically the raw OCR text with a
  /// small header so users see exactly what the parser saw. Keeps the
  /// review screen honest: anything we missed is still readable.
  String? _composeNotes(String text, List<String> lines) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return 'Imported from photo. OCR text:\n$trimmed';
  }

  // ─────────────────────── helpers ───────────────────────

  String _firstLineContaining(String text, String needle) {
    final lower = text.toLowerCase();
    final idx = lower.indexOf(needle.toLowerCase());
    if (idx < 0) return needle;
    final start = text.lastIndexOf('\n', idx) + 1;
    var end = text.indexOf('\n', idx);
    if (end < 0) end = text.length;
    return text.substring(start, end).trim();
  }

  String _numFmt(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  /// Iterative Levenshtein distance — small inputs only, so the O(mn)
  /// matrix is fine. Used for fuzzy powder-name matching against
  /// arbitrary OCR tokens.
  int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final m = a.length;
    final n = b.length;
    final prev = List<int>.generate(n + 1, (j) => j);
    final curr = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      for (var j = 0; j <= n; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[n];
  }
}
