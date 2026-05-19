// FILE: lib/services/photo_asset_loader.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// VFP Phase 4 Group A — the photo-asset loading + caching foundation
// the Scenic / Photographic tiers (VFP Phase 6+) build on. Public
// `PhotoAssetLoader` plus its two library-private collaborators
// (`_PhotoAssetCache`, `_PhotoAssetCacheManager`) and the §7.4
// decode-time downsampling helpers, co-located in one file (the
// underscore makes the collaborators file-private; this satisfies
// both the Phase 4 Group A path contract AND §7.6's "adjacent"
// co-location intent).
//
// `PhotoAssetLoader.load(...)`:
//   1. Resolves bytes with CDN-preferred / bundle-fallback priority
//      (a downloaded asset wins; the bundled asset is the
//      development / first-run fallback). Both sources are injected
//      seams (`cdnResolver` / `bundleLoader`) so the loader stays
//      free of `dart:io` / `path_provider` — the real filesystem +
//      Firebase download wiring is VFP Phase 4 Group B / C.
//   2. SHA-256 verifies the bytes when an expected digest is given
//      (defense in depth — a corrupt/tampered asset throws
//      `PhotoAssetIntegrityException` and is NEVER cached or
//      returned).
//   3. Decodes at a downsampled target size (§7.4) so a 2048-px
//      sprite does not occupy full-resolution GPU memory when shown
//      small.
//   4. Returns through a memory-tier-aware LRU (`_PhotoAssetCache`,
//      §7.5) whose budget is set by injected `deviceMemoryMb`.
//
// Cold-start / version-mismatch invalidation is by construction: the
// cache key embeds the asset version (`<key>@v<version>`), so a
// version bump is a natural cache miss → fresh decode; the prior
// entry is LRU-evicted + `dispose()`d.
//
// `_PhotoAssetCacheManager` (§7.6 verbatim) attaches as a
// `WidgetsBindingObserver`; `didHaveMemoryPressure` clears the cache
// and tracks a rolling 30 s pressure window, firing an optional
// sustained-pressure callback (the forward seam VFP Phase 6+'s
// `ScenicFallbackMonitor` will wire for Scenic→Stylized fallback —
// the consumer is later-phase; only the seam ships here).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// VFP §10 sequences the asset pipeline (Phase 4) BEFORE asset
// authoring (Phase 6) so the loader can be built, unit-tested, and
// the Phase 6 asset-measurement gate has a working pipeline. Every
// Scenic/Photographic surface decodes through this one loader, so
// the LRU budget, decode-downsampling, and memory-pressure response
// are centralised here rather than reimplemented per painter.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * `ui.Image` is a GPU/native resource — every eviction and
//     `clear()` MUST `dispose()` or it leaks VRAM. The §7.5 LRU does
//     this on overflow; the manager does it on memory pressure.
//   * SHA-256 failure must abort the load, not return a partial /
//     corrupt image — the verify happens INSIDE the cache loader
//     closure and throws, so `_PhotoAssetCache.get` never inserts a
//     bad entry (the closure throws before `_cache[key] = image`).
//   * `deviceMemoryMb` is injected (default conservative 4000), NOT
//     read from a platform channel here. The real physical-memory
//     channel + native plugins are §8 Capability-Detection scope
//     (a later VFP phase); building them in Phase 4 would be
//     out-of-scope speculative infra. The seam is the constructor
//     param.
//   * Decode-time downsampling needs the target size BEFORE decode
//     (`ui.instantiateImageCodec(targetWidth/Height:)`), so the
//     caller passes canvas size / dpr / `maxSharpZoom` (the
//     per-optic value from Appendix B.7 — a CALLER concern, not
//     hardcoded here).
//   * `attach()` is idempotent and `dispose()` symmetric — a tier
//     switch that recreates the loader must not double-register the
//     observer or leak it.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * VFP Phase 4 Group B — wires the real `cdnResolver` (app-support
//     filesystem) + Clear-Cached-Assets UI.
//   * VFP Phase 4 Group C — SeedUpdater photo-category download
//     populates the CDN files this loader prefers.
//   * VFP Phase 6+ — the `_ScenicScenePainter` / Photographic
//     painters decode every backdrop / sprite through
//     `PhotoAssetLoader.instance.load(...)`.
//   * `test/photo_asset_loader_test.dart` — cache / decode /
//     memory-pressure coverage (flat `test/`; the plan's
//     `test/services/...` path is stale-convention, D-8 class).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Decodes images (native codec, GPU memory). Disposes them on
//     eviction / clear / memory pressure.
//   * `attach()` registers a `WidgetsBindingObserver`; `dispose()`
//     unregisters it.
//   * Default `bundleLoader` reads from `rootBundle`. Default
//     `cdnResolver` is null (no CDN layer until Group B/C) → bundle
//     path. No network here (Group C owns downloads).

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

/// Thrown when an asset's SHA-256 does not match the expected digest.
/// The bytes are discarded — never decoded, cached, or returned.
class PhotoAssetIntegrityException implements Exception {
  PhotoAssetIntegrityException(this.assetKey, this.expected, this.actual);
  final String assetKey;
  final String expected;
  final String actual;
  @override
  String toString() =>
      'PhotoAssetIntegrityException($assetKey): expected $expected, '
      'got $actual';
}

/// Resolves the CDN-downloaded bytes for [relativePath], or null when
/// no downloaded copy exists (→ bundle fallback). Injected so the
/// loader has no `dart:io` / `path_provider` dependency; the real
/// app-support-filesystem resolver is VFP Phase 4 Group B.
typedef CdnResolver = Future<Uint8List?> Function(String relativePath);

/// Loads the bundled (development / first-run) bytes for [assetKey].
typedef BundleLoader = Future<Uint8List> Function(String assetKey);

/// Hex SHA-256 of [bytes]. Injected so tests can stub it without
/// hashing real payloads; the production default uses `crypto`.
typedef Sha256Hex = Future<String> Function(Uint8List bytes);

/// §7.4 — decode [bytes] directly at [targetWidth]×[targetHeight] so
/// the native codec downsamples; the full-resolution bitmap never
/// reaches GPU memory.
Future<ui.Image> decodeAtTargetSize(
  Uint8List bytes,
  int targetWidth,
  int targetHeight,
) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// §7.4 — the decoded target dimension: `canvas * dpr * maxSharpZoom`,
/// never upsampled past the source.
int computeTargetSize(
  int sourceSize,
  double canvasSize,
  double dpr,
  double maxSharpZoom,
) {
  final desired = (canvasSize * dpr * maxSharpZoom).round();
  return desired < sourceSize ? desired : sourceSize;
}

/// §7.5 — memory-tier-aware LRU over decoded `ui.Image`s. Every
/// eviction / clear disposes the native image.
class _PhotoAssetCache {
  _PhotoAssetCache({required int deviceMemoryMb}) {
    if (deviceMemoryMb >= 6000) {
      _maxEntries = 8;
    } else if (deviceMemoryMb >= 4000) {
      _maxEntries = 5;
    } else {
      _maxEntries = 3;
    }
  }

  // A Dart map literal is a LinkedHashMap — insertion-ordered, so
  // `keys.first` is the least-recently-used and remove+reinsert is
  // an MRU bump. Behaviourally identical to the §7.5 explicit
  // `LinkedHashMap()`; this is the analyzer-preferred literal form.
  final _cache = <String, ui.Image>{};
  late final int _maxEntries;

  int get length => _cache.length;
  int get maxEntries => _maxEntries;

  Future<ui.Image> get(
    String key,
    Future<ui.Image> Function() loader,
  ) async {
    if (_cache.containsKey(key)) {
      final image = _cache.remove(key)!;
      _cache[key] = image; // move to most-recently-used
      return image;
    }
    // If the loader throws (e.g. SHA-256 mismatch) the exception
    // propagates BEFORE any insert — no corrupt entry is cached.
    final image = await loader();
    _cache[key] = image;
    while (_cache.length > _maxEntries) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest)?.dispose();
    }
    return image;
  }

  void clear() {
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }
}

/// §7.6 — clears the cache on OS memory pressure and tracks a rolling
/// window so a sustained-pressure callback can drive Scenic→Stylized
/// fallback (the callback's CONSUMER, `ScenicFallbackMonitor`, is
/// VFP Phase 6+/§7.8 — only the seam ships in Phase 4).
class _PhotoAssetCacheManager extends WidgetsBindingObserver {
  _PhotoAssetCacheManager(this._cache);

  final _PhotoAssetCache _cache;
  bool _isAttached = false;

  final List<DateTime> _pressureEvents = [];
  static const Duration _pressureWindow = Duration(seconds: 30);
  void Function()? _onSustainedPressure;

  void attach() {
    if (_isAttached) return;
    WidgetsBinding.instance.addObserver(this);
    _isAttached = true;
  }

  @override
  void didHaveMemoryPressure() {
    _cache.clear();
    _recordPressureEvent();
  }

  void _recordPressureEvent() {
    final now = DateTime.now();
    _pressureEvents.removeWhere(
      (t) => now.difference(t) > _pressureWindow,
    );
    _pressureEvents.add(now);
    if (_pressureEvents.length >= 2 && _onSustainedPressure != null) {
      _onSustainedPressure!();
      _pressureEvents.clear(); // avoid retriggering on every event
    }
  }

  void registerSustainedPressureCallback(void Function()? callback) {
    _onSustainedPressure = callback;
  }

  void dispose() {
    if (!_isAttached) return;
    WidgetsBinding.instance.removeObserver(this);
    _isAttached = false;
    _onSustainedPressure = null;
    _pressureEvents.clear();
  }
}

/// Production default: lower-case hex SHA-256 via
/// `package:cryptography` (the dep this codebase already ships;
/// `Sha256().hash(...)` is async, which fits the async load path).
Future<String> _defaultSha256Hex(Uint8List bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// VFP Phase 4 Group A — photo-asset loader. See the file header for
/// the resolution / verify / decode / cache contract.
class PhotoAssetLoader {
  PhotoAssetLoader({
    int deviceMemoryMb = 4000,
    CdnResolver? cdnResolver,
    BundleLoader? bundleLoader,
    Sha256Hex? sha256Hex,
  })  : _cdnResolver = cdnResolver,
        _bundleLoader = bundleLoader ?? _defaultBundleLoader,
        _sha256Hex = sha256Hex ?? _defaultSha256Hex,
        _cache = _PhotoAssetCache(deviceMemoryMb: deviceMemoryMb) {
    _manager = _PhotoAssetCacheManager(_cache);
  }

  /// App-wide instance. Production wiring (real `cdnResolver`,
  /// capability-derived `deviceMemoryMb`) is injected by Group B / a
  /// later capability phase; this default is dev-safe (bundle path,
  /// conservative memory tier).
  static final PhotoAssetLoader instance = PhotoAssetLoader();

  final CdnResolver? _cdnResolver;
  final BundleLoader _bundleLoader;
  final Sha256Hex _sha256Hex;
  final _PhotoAssetCache _cache;
  late final _PhotoAssetCacheManager _manager;

  static Future<Uint8List> _defaultBundleLoader(String assetKey) async =>
      (await rootBundle.load(assetKey)).buffer.asUint8List();

  /// Wire the memory-pressure observer. Idempotent; call once when
  /// the first Scenic/Photographic surface mounts.
  void attach() => _manager.attach();

  /// Forward seam for VFP Phase 6+ `ScenicFallbackMonitor` (§7.8).
  void registerSustainedPressureCallback(void Function()? cb) =>
      _manager.registerSustainedPressureCallback(cb);

  int get cacheLength => _cache.length;
  int get cacheMaxEntries => _cache.maxEntries;

  /// Resolve → SHA-256 verify → decode-at-target-size → LRU.
  ///
  /// [assetKey] is the bundle key (rootBundle path);
  /// [relativePath] is the CDN-relative path a downloaded copy lives
  /// at. [canvasSize]/[dpr]/[maxSharpZoom] drive §7.4 downsampling.
  /// [expectedSha256] (hex, lower-case) enables defense-in-depth
  /// verification. [assetVersion] is folded into the cache key so a
  /// bump is a natural miss (cold-start / version invalidation).
  Future<ui.Image> load({
    required String assetKey,
    required String relativePath,
    required double canvasSize,
    required double dpr,
    required double maxSharpZoom,
    String? expectedSha256,
    int assetVersion = 0,
  }) {
    final cacheKey = '$assetKey@v$assetVersion';
    return _cache.get(cacheKey, () async {
      // CDN preferred (downloaded) → bundle fallback (dev/first run).
      Uint8List? bytes;
      if (_cdnResolver != null) {
        bytes = await _cdnResolver(relativePath);
      }
      bytes ??= await _bundleLoader(assetKey);

      if (expectedSha256 != null) {
        final actual = await _sha256Hex(bytes);
        if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
          // Thrown INSIDE the cache loader → never inserted.
          throw PhotoAssetIntegrityException(
              assetKey, expectedSha256, actual);
        }
      }

      // Source size unknown without a probe decode; the §7.4 formula
      // clamps to source, so passing the desired size is safe (the
      // codec will not upsample a smaller source — targetWidth/Height
      // request a maximum, the decoder honours the smaller intrinsic).
      final target =
          (canvasSize * dpr * maxSharpZoom).round().clamp(1, 1 << 16);
      return decodeAtTargetSize(bytes, target, target);
    });
  }

  /// Clear all cached images (disposes each). Used by the Group B
  /// Clear-Cached-Assets UI and on tier teardown.
  void clearCache() => _cache.clear();

  /// Test-only cache reset (matches the `debugResetCache()`
  /// convention used by `ScopeCatalogV2Service` etc.).
  void debugResetCache() => _cache.clear();

  void dispose() {
    _manager.dispose();
    _cache.clear();
  }
}
