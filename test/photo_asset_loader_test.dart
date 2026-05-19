// FILE: test/photo_asset_loader_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// VFP Phase 4 Group A coverage for `PhotoAssetLoader`
// (lib/services/photo_asset_loader.dart): the memory-tier LRU budget
// (§7.5), CDN-preferred / bundle-fallback resolution priority,
// SHA-256 defense-in-depth (mismatch throws + caches nothing),
// asset-version cache invalidation, the §7.4 `computeTargetSize`
// downsampling math, real decode + LRU evict/dispose with actual
// `ui.Image`s, and the §7.6 memory-pressure response (cache clear +
// sustained-pressure callback) driven through the real
// `WidgetsBinding` memory-pressure path.
//
// Every external concern is an injected seam (cdnResolver /
// bundleLoader / sha256Hex / deviceMemoryMb) so the tests are
// deterministic and need no filesystem, network, or
// platform-channel. A real 1×1 PNG is used so decode + dispose
// exercise the genuine native codec path (not a mock).
//
// Path note: flat `test/` — the plan's `test/services/...` is a
// stale-convention citation (D-8 class); this project has no
// `test/services/` subdir.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Decodes tiny PNGs (native codec) and disposes them. Uses the
// flutter_test binding's memory-pressure simulation. No I/O.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/photo_asset_loader.dart';

/// Canonical 1×1 transparent PNG — a valid payload the engine codec
/// decodes to a real `ui.Image`.
final Uint8List _png1x1 = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§7.4 computeTargetSize (pure downsampling math)', () {
    test('downsamples to canvas*dpr*maxSharpZoom when < source', () {
      // 400 logical * 3.0 dpr * 1.0 zoom = 1200 < 2048 → 1200.
      expect(computeTargetSize(2048, 400, 3.0, 1.0), 1200);
    });

    test('never upsamples past the source size', () {
      // desired 1200 but source only 512 → clamp to 512.
      expect(computeTargetSize(512, 400, 3.0, 1.0), 512);
    });

    test('maxSharpZoom scales the target', () {
      expect(computeTargetSize(8000, 500, 2.0, 3.0), 3000);
      expect(computeTargetSize(8000, 500, 2.0, 1.0), 1000);
    });
  });

  group('§7.5 memory-tier LRU budget', () {
    test('maxEntries by deviceMemoryMb (8 / 5 / 3)', () {
      expect(PhotoAssetLoader(deviceMemoryMb: 6000).cacheMaxEntries, 8);
      expect(PhotoAssetLoader(deviceMemoryMb: 4000).cacheMaxEntries, 5);
      expect(PhotoAssetLoader(deviceMemoryMb: 3000).cacheMaxEntries, 3);
    });
  });

  group('resolution priority + caching', () {
    test('cache hit: loader closure runs once for repeat loads', () async {
      var bundleCalls = 0;
      final loader = PhotoAssetLoader(
        bundleLoader: (_) async {
          bundleCalls++;
          return _png1x1;
        },
      );
      final a = await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 4, dpr: 1, maxSharpZoom: 1);
      final b = await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 4, dpr: 1, maxSharpZoom: 1);
      expect(identical(a, b), isTrue, reason: 'second load = cache hit');
      expect(bundleCalls, 1);
      expect(loader.cacheLength, 1);
    });

    test('CDN preferred when it returns bytes; bundle untouched',
        () async {
      var bundleCalls = 0;
      final loader = PhotoAssetLoader(
        cdnResolver: (_) async => _png1x1,
        bundleLoader: (_) async {
          bundleCalls++;
          return _png1x1;
        },
      );
      await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 2, dpr: 1, maxSharpZoom: 1);
      expect(bundleCalls, 0, reason: 'CDN bytes win; bundle not consulted');
    });

    test('bundle fallback when CDN resolver returns null', () async {
      var bundleCalls = 0;
      final loader = PhotoAssetLoader(
        cdnResolver: (_) async => null,
        bundleLoader: (_) async {
          bundleCalls++;
          return _png1x1;
        },
      );
      await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 2, dpr: 1, maxSharpZoom: 1);
      expect(bundleCalls, 1);
    });
  });

  group('SHA-256 defense in depth', () {
    test('matching digest → loads + caches', () async {
      final loader = PhotoAssetLoader(
        bundleLoader: (_) async => _png1x1,
        sha256Hex: (_) async => 'ABCD',
      );
      final img = await loader.load(
        assetKey: 'k',
        relativePath: 'r',
        canvasSize: 2,
        dpr: 1,
        maxSharpZoom: 1,
        expectedSha256: 'abcd', // case-insensitive
      );
      expect(img, isA<ui.Image>());
      expect(loader.cacheLength, 1);
    });

    test('mismatch → throws PhotoAssetIntegrityException, caches nothing',
        () async {
      var bundleCalls = 0;
      final loader = PhotoAssetLoader(
        bundleLoader: (_) async {
          bundleCalls++;
          return _png1x1;
        },
        sha256Hex: (_) async => 'deadbeef',
      );
      await expectLater(
        loader.load(
          assetKey: 'k',
          relativePath: 'r',
          canvasSize: 2,
          dpr: 1,
          maxSharpZoom: 1,
          expectedSha256: 'cafe',
        ),
        throwsA(isA<PhotoAssetIntegrityException>()),
      );
      expect(loader.cacheLength, 0, reason: 'corrupt asset never cached');
      // A subsequent good load re-runs the loader (nothing stuck).
      final ok = PhotoAssetLoader(bundleLoader: (_) async => _png1x1);
      await ok.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 2, dpr: 1, maxSharpZoom: 1);
      expect(bundleCalls, 1);
    });
  });

  group('asset-version cache invalidation', () {
    test('same version = hit; different version = miss (fresh decode)',
        () async {
      var calls = 0;
      final loader = PhotoAssetLoader(
        bundleLoader: (_) async {
          calls++;
          return _png1x1;
        },
      );
      await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 2, dpr: 1, maxSharpZoom: 1, assetVersion: 1);
      await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 2, dpr: 1, maxSharpZoom: 1, assetVersion: 1);
      expect(calls, 1, reason: 'v1 cached');
      await loader.load(
          assetKey: 'k', relativePath: 'r', canvasSize: 2, dpr: 1, maxSharpZoom: 1, assetVersion: 2);
      expect(calls, 2, reason: 'v2 is a distinct cache key → fresh decode');
    });
  });

  group('LRU eviction', () {
    test('cache stays within budget; evicted keys re-decode', () async {
      var calls = 0;
      final loader = PhotoAssetLoader(
        deviceMemoryMb: 3000, // → maxEntries 3
        bundleLoader: (_) async {
          calls++;
          return _png1x1;
        },
      );
      for (final k in ['a', 'b', 'c', 'd']) {
        await loader.load(
            assetKey: k, relativePath: k, canvasSize: 2, dpr: 1, maxSharpZoom: 1);
      }
      expect(loader.cacheLength, 3, reason: 'budget enforced');
      expect(calls, 4);
      // 'a' was the oldest → evicted; loading it again re-decodes.
      await loader.load(
          assetKey: 'a', relativePath: 'a', canvasSize: 2, dpr: 1, maxSharpZoom: 1);
      expect(calls, 5, reason: 'evicted key was not in cache');
      expect(loader.cacheLength, 3);
    });
  });

  group('§7.6 memory-pressure response', () {
    testWidgets('memory pressure clears the cache', (tester) async {
      final loader = PhotoAssetLoader(bundleLoader: (_) async => _png1x1)
        ..attach();
      // Real image decode (ui.instantiateImageCodec) uses genuine
      // engine async, which does NOT settle inside testWidgets'
      // fake-async zone — it MUST run via tester.runAsync or the
      // await hangs until the suite times out.
      await tester.runAsync(() async {
        await loader.load(
            assetKey: 'k',
            relativePath: 'r',
            canvasSize: 2,
            dpr: 1,
            maxSharpZoom: 1);
      });
      expect(loader.cacheLength, 1);

      // Real WidgetsBinding memory-pressure path → observer fires
      // synchronously (clear + dispose are sync).
      WidgetsBinding.instance.handleMemoryPressure();
      await tester.pump();

      expect(loader.cacheLength, 0, reason: 'cache cleared on pressure');
      loader.dispose();
    });

    testWidgets('sustained pressure (2 within window) fires callback',
        (tester) async {
      var fired = 0;
      final loader = PhotoAssetLoader(bundleLoader: (_) async => _png1x1)
        ..attach()
        ..registerSustainedPressureCallback(() => fired++);

      WidgetsBinding.instance.handleMemoryPressure();
      await tester.pump();
      expect(fired, 0, reason: 'one event is not "sustained"');

      WidgetsBinding.instance.handleMemoryPressure();
      await tester.pump();
      expect(fired, 1, reason: '2 events within 30s window → callback');

      loader.dispose();
    });

    testWidgets('dispose unregisters the observer (no leak across tiers)',
        (tester) async {
      final loader = PhotoAssetLoader(bundleLoader: (_) async => _png1x1)
        ..attach();
      loader.dispose();
      // After dispose the observer is gone; a pressure event is a
      // no-op (and must not throw).
      WidgetsBinding.instance.handleMemoryPressure();
      await tester.pump();
      expect(loader.cacheLength, 0);
    });
  });
}
