// FILE: lib/widgets/animal_silhouettes.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Loads, parses, caches, and rescales hand-authored SVG silhouettes for the
// 16 animal targets shipped with the Range Day v2.3 catalog (deer, mule deer,
// elk, moose, pronghorn, bear, boar, mountain lion, coyote, fox, rabbit,
// groundhog, prairie dog, wild turkey, pheasant, and a novelty bigfoot).
//
// Public surface on the static class `AnimalSilhouettes`:
//   * `isAnimalShape(shapeId)` — true when the supplied `shape_id` from
//     `targets.json` resolves to one of the 16 known assets.
//   * `loadAnimalPath(shapeId)` — returns the cached or newly-parsed
//     `Path` in source SVG coordinates. First call pays the rootBundle read
//     + parse cost (~5ms); subsequent calls are O(1) cache hits.
//   * `scalePathToBounds(source, bounds)` — uniformly scales a source path
//     to fit a destination Rect while preserving aspect ratio and bottom-
//     aligning the silhouette (feet rest on the bottom of the rect, which
//     is the post connection point on a real range target).
//   * `buildAnimalPath(bounds, shapeId)` — convenience: load + scale in
//     one async call.
//
// The class is purely static; there is no constructor / instance.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Range Day's target picker and on-screen target widget need to render
// animal silhouettes that look like real game animals — not crude wireframes
// drawn from primitives. Hand-authored SVGs deliver that fidelity, but
// Flutter's `Canvas` API draws `Path` objects, not raw SVG XML. This file
// is the bridge: read the SVG once, extract every `<path d="..."/>` blob,
// parse them through the `path_drawing` package, fold them into a single
// `Path`, then cache the result so subsequent picker / preview / range
// renderings cost nothing.
//
// If this file were deleted, every place that renders an animal target
// would have to repeat the rootBundle.loadString + regex + parse dance,
// and the picker would visibly stutter as the user scrolls through the
// 16 entries. Caching is the headline reason the file is a separate
// service rather than inline parse calls.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * SVG `<path>` elements come in singletons AND clusters. prairie_dog
//     ships as 4 sibling `<path>` elements; the parser must combine them
//     into one Path via `Path.addPath(subpath, Offset.zero)` so a single
//     `canvas.drawPath` call renders the full silhouette. The regex is
//     deliberately permissive about attribute order and whitespace inside
//     the opening tag (`<path  fill="..." d=" ... "/>` parses).
//   * The cache uses two maps: `_pathCache` for completed loads and
//     `_loadFutures` for in-flight ones. The in-flight map prevents the
//     same SVG from being parsed twice when two widgets simultaneously
//     request it on first launch (race condition before the preload
//     `Future.wait` completes).
//   * Bottom-alignment is load-bearing for the post-mounted target
//     visualization. The math: scale uniformly to whichever axis is the
//     binding constraint, then translate so the source's bottom edge
//     lines up with `bounds.bottom`. Translating by `bounds.bottom -
//     scaledHeight - src.top * scale` looks unintuitive but it correctly
//     accounts for SVGs whose bounding box doesn't start at (0, 0).
//   * `Path.transform` takes a 16-element `Float64List` from `Matrix4.storage`,
//     not a `Matrix4` object directly.
//   * `parseSvgPathData` from `path_drawing` does NOT raise on malformed
//     input — it returns an empty `Path`. We rely on visual review of
//     the 16 shipped SVGs during this phase; a malformed file would render
//     as an empty silhouette rather than throwing.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `lib/main.dart` — preloads all 16 paths fire-and-forget after Firebase
//     initialization (per Appendix H.4 of the Range Day Realistic v2.3
//     rewrite).
//   * `lib/widgets/target_silhouettes.dart` — sibling file for non-animal
//     silhouettes, parallel design with shared parsing strategy.
//   * Range Day target picker + on-screen target widget (consume via
//     `buildAnimalPath` once those screens are wired in subsequent phases
//     of the v2.3 rewrite).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Reads asset files from `assets/silhouettes/animals/*.svg` via
//     Flutter's `rootBundle.loadString`. No filesystem writes, no network
//     calls, no native channels.
//   * Caches parsed `Path` objects in process memory for the lifetime of
//     the app process. Total cache size is bounded by the 16 silhouettes
//     (~250 KB of SVG source, smaller after parse).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_drawing/path_drawing.dart';
import 'package:svg_path_parser/svg_path_parser.dart' as svg_strict;
import 'dart:async';

/// Phase 7b — value type for an SVG `<path>` parsed into a Flutter
/// `Path` plus its `fill` attribute (lowercased, or null if absent).
/// Internal to this file; carries the data the inverted-pattern
/// heuristic and the white-fill filter both need.
class _ParsedSvgPath {
  _ParsedSvgPath(this.path, this.fillHex) : bounds = path.getBounds();

  final Path path;
  final String? fillHex;
  final Rect bounds;
}

/// Renders hand-authored SVG silhouettes for animal targets.
/// SVGs live in assets/silhouettes/animals/{filename}.svg.
class AnimalSilhouettes {
  /// Map of shape_id (from `targets.json`) to asset filename. KEY
  /// equals SVG filename basename for every row — strict 1:1 mapping
  /// from logical catalog name to physical file. After the v36 catalog
  /// rewrite + the `prairie_dog_standing.svg → prairie_dog.svg` rename,
  /// there are no longer any exceptions.
  static const Map<String, String> _shapeIdToAsset = {
    'bear':           'assets/silhouettes/animals/bear.svg',
    'bigfoot':        'assets/silhouettes/animals/bigfoot.svg',
    'boar':           'assets/silhouettes/animals/boar.svg',
    'coyote':         'assets/silhouettes/animals/coyote.svg',
    'deer':           'assets/silhouettes/animals/deer.svg',
    'elk':            'assets/silhouettes/animals/elk.svg',
    'fox':            'assets/silhouettes/animals/fox.svg',
    'groundhog':      'assets/silhouettes/animals/groundhog.svg',
    'moose':          'assets/silhouettes/animals/moose.svg',
    'mountain_lion':  'assets/silhouettes/animals/mountain_lion.svg',
    'mule_deer':      'assets/silhouettes/animals/mule_deer.svg',
    'pheasant':       'assets/silhouettes/animals/pheasant.svg',
    'prairie_dog':    'assets/silhouettes/animals/prairie_dog.svg',
    'pronghorn':      'assets/silhouettes/animals/pronghorn.svg',
    'rabbit':         'assets/silhouettes/animals/rabbit.svg',
    'wild_turkey':    'assets/silhouettes/animals/wild_turkey.svg',
  };

  /// Cache of parsed Path objects keyed by shape_id.
  /// First use of each shape pays the SVG parse cost; subsequent uses are free.
  static final Map<String, Path> _pathCache = {};
  static final Map<String, Future<Path>> _loadFutures = {};

  static bool isAnimalShape(String shapeId) => _shapeIdToAsset.containsKey(shapeId);

  /// Loads and parses the SVG path for [shapeId]. Cached after first call.
  static Future<Path> loadAnimalPath(String shapeId) async {
    final cached = _pathCache[shapeId];
    if (cached != null) return cached;

    final inFlight = _loadFutures[shapeId];
    if (inFlight != null) return inFlight;

    final assetPath = _shapeIdToAsset[shapeId];
    if (assetPath == null) {
      throw StateError('Unknown animal shape_id: $shapeId');
    }

    final future = _loadAndParse(assetPath);
    _loadFutures[shapeId] = future;
    final path = await future;
    _pathCache[shapeId] = path;
    _loadFutures.remove(shapeId);
    return path;
  }

  static Future<Path> _loadAndParse(String assetPath) async {
    final svgContent = await rootBundle.loadString(assetPath);
    return extractAndCombinePaths(svgContent, assetPath);
  }

  /// Extracts every `<path>` element from the SVG, parses each into a
  /// Flutter `Path`, and composites them into one combined `Path`.
  ///
  /// Phase 7b adds two structural pre-filters before the naive combine:
  ///
  ///   * **Inverted-negative-space detection.** Some authored SVGs
  ///     (the bigfoot SVG in particular) draw the silhouette as a HOLE
  ///     in a giant white canvas-covering path. The combined-paths
  ///     approach renders these as "outlined rectangle". When the
  ///     first path's fill is white-ish AND its bounds cover ≥90% of
  ///     the SVG's viewBox in both axes, we treat the SVG as inverted
  ///     and return `Path.combine(difference, canvasRect, firstPath)` —
  ///     the visible silhouette becomes the negative space.
  ///   * **White-fill filter.** Standard SVGs occasionally include a
  ///     white background rect alongside the dark silhouette paths.
  ///     Filtering those out before the combine prevents the
  ///     silhouette from being rendered on top of a white square that
  ///     would mask the realistic-scene backdrop. If the filter
  ///     leaves no content, we fall back to combining EVERY path so
  ///     we never end up with an empty silhouette (pre-Phase-7b
  ///     behavior preserved as the defensive floor).
  ///
  /// Strict parsing happens via `svg_path_parser` first; if it throws
  /// on a malformed `d` string, we fall back to the lenient
  /// `parseSvgPathData` from `path_drawing`. Either way, an SVG with
  /// only malformed paths still raises `StateError` (preserves the
  /// pre-Phase-7b "fail loud on totally broken SVGs" behaviour).
  ///
  /// Public for tests; the `@visibleForTesting` annotation belongs on
  /// the file but Dart's analyzer is happy with the leading lowercase
  /// name + a doc comment that says "tests only."
  static Path extractAndCombinePaths(String svgContent, String assetPath) {
    final viewBox = _parseViewBox(svgContent);
    final paths = _parseAllPaths(svgContent);

    if (paths.isEmpty) {
      throw StateError('No <path d="..."/> found in $assetPath');
    }

    // 1. Inverted-negative-space pattern.
    if (_isInvertedNegativeSpaceSvg(paths, viewBox)) {
      final canvasRect = Path()..addRect(viewBox);
      return Path.combine(
        PathOperation.difference,
        canvasRect,
        paths.first.path,
      );
    }

    // 2. Standard SVG — filter white-fill paths, then combine.
    final combined = Path();
    for (final p in paths) {
      if (_isWhiteFill(p.fillHex)) continue;
      combined.addPath(p.path, Offset.zero);
    }

    // 3. Defensive fallback: if every path was filtered out (i.e. SVG
    //    is all white-fill — unexpected, but possible), combine every
    //    path so we still get a non-empty silhouette. Matches the
    //    pre-Phase-7b behaviour for SVGs that don't fit either of
    //    the two structural patterns above.
    if (combined.getBounds().isEmpty) {
      final fallback = Path();
      for (final p in paths) {
        fallback.addPath(p.path, Offset.zero);
      }
      return fallback;
    }

    return combined;
  }

  /// Parses every `<path>` block in [svgContent] into a `_ParsedSvgPath`
  /// (Flutter `Path` + optional `fill` attribute, both extracted from
  /// the same `<path>` opening tag).
  ///
  /// Order is preserved — the first `<path>` in the source SVG is the
  /// first entry in the returned list (load-bearing for the
  /// inverted-negative-space heuristic which inspects `paths.first`).
  ///
  /// Parsing strategy: strict `svg_path_parser.parseSvgPath` first.
  /// If it throws on a malformed `d` string, fall back to the lenient
  /// `parseSvgPathData` from `path_drawing` (which silently drops
  /// unparseable segments rather than raising). If both fail, log a
  /// `debugPrint` and skip the path entirely — never crash on a
  /// single bad `d` string.
  static List<_ParsedSvgPath> _parseAllPaths(String svgContent) {
    final pathTagRe = RegExp(
      r'<path\b([^>]*)>',
      multiLine: true,
      dotAll: true,
    );
    final dAttrRe = RegExp(r'\bd\s*=\s*"([^"]+)"');
    final fillAttrRe = RegExp(r'\bfill\s*=\s*"([^"]+)"');

    final result = <_ParsedSvgPath>[];
    for (final match in pathTagRe.allMatches(svgContent)) {
      final attrs = match.group(1) ?? '';
      final dMatch = dAttrRe.firstMatch(attrs);
      if (dMatch == null) continue;
      final d = dMatch.group(1)!;
      final fillMatch = fillAttrRe.firstMatch(attrs);
      final fillHex = fillMatch?.group(1)?.toLowerCase();

      Path? parsed;
      try {
        parsed = svg_strict.parseSvgPath(d);
      } catch (_) {
        // Strict parser rejected — fall back to lenient.
        try {
          parsed = parseSvgPathData(d);
        } catch (e) {
          debugPrint('animal_silhouettes: skipped unparseable path: $e');
          continue;
        }
      }
      result.add(_ParsedSvgPath(parsed, fillHex));
    }
    return result;
  }

  /// Returns the SVG's `viewBox` as a Rect, or a 1024×1024 default
  /// when the SVG omits the attribute. The default size is arbitrary
  /// — the heuristic compares ratios (cover ≥ 0.9), so absolute
  /// units don't matter as long as the same scale is used on both
  /// sides of the comparison.
  static Rect _parseViewBox(String svgContent) {
    final svgTagRe = RegExp(
      r'<svg\b([^>]*)>',
      multiLine: true,
      dotAll: true,
    );
    final viewBoxAttrRe = RegExp(r'\bviewBox\s*=\s*"([^"]+)"');

    final svgMatch = svgTagRe.firstMatch(svgContent);
    if (svgMatch == null) {
      return const Rect.fromLTWH(0, 0, 1024, 1024);
    }
    final viewBoxMatch = viewBoxAttrRe.firstMatch(svgMatch.group(1) ?? '');
    if (viewBoxMatch == null) {
      // Fall back to the `width` and `height` attributes if present.
      final widthRe = RegExp(r'\bwidth\s*=\s*"([\d.]+)');
      final heightRe = RegExp(r'\bheight\s*=\s*"([\d.]+)');
      final w = widthRe.firstMatch(svgMatch.group(1) ?? '');
      final h = heightRe.firstMatch(svgMatch.group(1) ?? '');
      if (w != null && h != null) {
        return Rect.fromLTWH(0, 0,
            double.parse(w.group(1)!), double.parse(h.group(1)!));
      }
      return const Rect.fromLTWH(0, 0, 1024, 1024);
    }
    final parts = viewBoxMatch.group(1)!
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length != 4) {
      return const Rect.fromLTWH(0, 0, 1024, 1024);
    }
    return Rect.fromLTWH(
      double.parse(parts[0]),
      double.parse(parts[1]),
      double.parse(parts[2]),
      double.parse(parts[3]),
    );
  }

  /// Returns `true` for white / near-white fill attributes. Matches
  /// `#fff`, `#ffffff`, `#ffffffff`, the literal word `white`, and the
  /// near-white nibble patterns (every digit `e` or `f`) common in
  /// raster-traced SVGs after anti-aliasing.
  ///
  /// `null` (no `fill` attribute on the path) returns `false` —
  /// per SVG spec the inherited default fill is black, not white,
  /// so a missing fill is intentionally not treated as white.
  static bool _isWhiteFill(String? fillHex) {
    if (fillHex == null) return false;
    final f = fillHex.trim().toLowerCase();
    if (f == 'white') return true;
    if (!f.startsWith('#')) return false;
    final hex = f.substring(1);
    if (hex == 'fff' || hex == 'ffffff' || hex == 'ffffffff') return true;
    // Near-white nibble pattern: every hex digit is `e` or `f`.
    if (RegExp(r'^[ef]{3}$').hasMatch(hex)) return true;
    if (RegExp(r'^[ef]{6}$').hasMatch(hex)) return true;
    if (RegExp(r'^[ef]{8}$').hasMatch(hex)) return true;
    return false;
  }

  /// Returns `true` when the SVG appears to use the inverted
  /// negative-space pattern (giant white canvas-covering first path
  /// with the silhouette cut out as a hole). The bigfoot SVG matches
  /// this; the bear / deer / elk / etc. don't.
  ///
  /// Heuristic (NOT a perfect classifier):
  ///   * `paths.first.fillHex` is white-ish, AND
  ///   * `paths.first.bounds` cover at least 90% of [viewBox] in BOTH
  ///     axes.
  ///
  /// 90% is a deliberate margin — some inverted SVGs leave a tiny
  /// breathing strip between the canvas-cover and the actual edge.
  /// Animal SVGs with conventional structure don't come anywhere
  /// close to triggering this (their first path is typically the
  /// silhouette body, fill `#000000`, much smaller than viewBox).
  static bool _isInvertedNegativeSpaceSvg(
    List<_ParsedSvgPath> paths,
    Rect viewBox,
  ) {
    if (paths.isEmpty) return false;
    final first = paths.first;
    if (!_isWhiteFill(first.fillHex)) return false;
    if (viewBox.width <= 0 || viewBox.height <= 0) return false;
    final coverageX = first.bounds.width / viewBox.width;
    final coverageY = first.bounds.height / viewBox.height;
    return coverageX >= 0.9 && coverageY >= 0.9;
  }

  /// Synchronous cache-hit accessor for use from `CustomPainter.paint`.
  /// Returns the SVG path scaled to [bounds] when the source path is
  /// already in [_pathCache] (typically because `main.dart` preloaded
  /// it at app boot per Appendix H.4 of the Range Day Realistic v2.3
  /// rewrite). Returns `null` when the cache is cold — callers should
  /// fall back to a procedural shape for that frame; the next repaint
  /// after preload completes will return the real path.
  ///
  /// Synchronous companion to [buildAnimalPath]. Use the async variant
  /// from any non-paint codepath.
  ///
  /// [scaleFactor] (v38+) is a multiplier on top of the natural
  /// fit-to-box scale. Default 1.0 (no change). Values like 1.2-1.4
  /// let problem animals (antlers, horns, tall tails) overflow the
  /// rect cleanly — bottom-alignment is preserved, so the body
  /// stays seated on the pole top while the antlers / horns extend
  /// up into the canvas sky region.
  static Path? cachedScaledPath(
    Rect bounds,
    String shapeId, {
    double scaleFactor = 1.0,
  }) {
    final source = _pathCache[shapeId];
    if (source == null) return null;
    return scalePathToBounds(source, bounds, scaleFactor: scaleFactor);
  }

  /// Returns a Path that fits [bounds] while preserving the source SVG's
  /// aspect ratio. The silhouette is centered horizontally and bottom-aligned
  /// (feet rest at the bottom of the rect, matching the post connection point).
  ///
  /// [scaleFactor] (v38+) multiplies the uniform fit-to-box scale.
  /// At 1.0 (default) the silhouette stays inside the rect. At >1.0
  /// the silhouette overflows the rect's top edge while staying
  /// bottom-aligned — used by the realistic scene painter to let
  /// antlers / horns extend into the sky region above the target.
  static Path scalePathToBounds(
    Path source,
    Rect bounds, {
    double scaleFactor = 1.0,
  }) {
    final src = source.getBounds();
    if (src.width <= 0 || src.height <= 0) return source;

    final scaleX = bounds.width / src.width;
    final scaleY = bounds.height / src.height;
    final fitScale = scaleX < scaleY ? scaleX : scaleY;  // uniform fit
    final scale = fitScale * scaleFactor;

    final scaledWidth = src.width * scale;
    final scaledHeight = src.height * scale;
    final dx = bounds.left + (bounds.width - scaledWidth) / 2 - src.left * scale;
    final dy = bounds.bottom - scaledHeight - src.top * scale;  // bottom-align

    final matrix = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale, scale);
    return source.transform(matrix.storage);
  }

  /// Convenience: load + scale in one call.
  static Future<Path> buildAnimalPath(Rect bounds, String shapeId) async {
    final source = await loadAnimalPath(shapeId);
    return scalePathToBounds(source, bounds);
  }
}
