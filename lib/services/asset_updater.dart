// FILE: lib/services/asset_updater.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `AssetUpdater` — the generic, one-shot, fire-and-forget live-update
// service. It pulls a manifest from Firebase Storage on cold start
// and, for every entry whose remote version is strictly greater than
// the locally-tracked version, downloads + validates + atomically
// writes the asset and records the new version. WHAT counts as a
// valid filename, valid content, where it is written, which
// SharedPrefs prefix tracks versions, and what post-apply side
// effect runs are all supplied by an [AssetUpdaterConfig].
//
// VFP Phase 4 Groups C+D: this REPLACES the old `SeedUpdater` class.
// `AssetUpdater(config: seedCatalogConfig)` preserves the entire
// launch-critical seed-catalog hot-fix behaviour bit-for-bit (Group
// C); `AssetUpdater(config: photoAssetConfig)` adds binary photo
// assets (Group D). One class, two configurations — composition,
// not subclassing.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// `SeedUpdater` and a parallel photo-asset downloader would have
// duplicated the same fragile manifest/anti-downgrade/atomic-write/
// security-boundary logic. Pre-live is the right time to unify. The
// execution discipline (the spec's load-bearing constraint) is to
// preserve the seed path's observable behaviour EXACTLY — same
// manifest path, same anti-downgrade, same allowlist + filename
// security boundary, same SharedPrefs keys (incl. the
// `seed_needs_reseed_<key>` re-seed trigger, carried via
// `config.onAssetApplied` — see §0.5 finding C-c in
// asset_updater_config.dart).
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * BIT-FOR-BIT seed preservation. The control flow, gate
//     order (allowlist → well-formed → filename-safety →
//     anti-downgrade → download+validate → write → version bump →
//     post-apply), byte caps, and the exact error model (silence
//     Firebase `object-not-found`; swallow everything at the top so
//     a misconfigured project never crashes the app; reject — never
//     partially overwrite — on validation/parse failure) are lifted
//     verbatim from the real `seed_updater.dart`.
//   * Atomic temp-then-rename is now UNIVERSAL (a defence-in-depth
//     improvement over SeedUpdater's direct `writeAsString`). The
//     on-disk result is byte-identical; only a transient `.tmp`
//     exists mid-write, which the seed loader already ignores.
//   * The manifest is always JSON regardless of content type, so
//     manifest parsing is concrete here; only per-FILE content
//     semantics are delegated to `config.contentValidator`.
//   * `FirebaseStorage` is injectable so the Group D mock-Firebase
//     tests (and any seed integration test) can drive the flow
//     without a real bucket — same seam SeedUpdater exposed.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * lib/main.dart — fires `AssetUpdater(config: seedCatalogConfig)
//     .fetchAndApply()` after `SeedLoader.seedIfNeeded()` (replacing
//     the old `SeedUpdater(db).checkForUpdates()`).
//   * lib/services/asset_updater_configs.dart — the two configs.
//   * test/asset_updater_allowlist_test.dart + (Group D)
//     test/asset_updater_photo_test.dart.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Network: one Storage GET for the manifest + one per stale
//     file. Disk: atomic write under the config's storage root.
//     SharedPreferences: version key + whatever `onAssetApplied`
//     writes. Never touches SQLite. Never throws.

import 'dart:convert';
import 'dart:io';

// `FirebaseException` is re-exported from `firebase_storage`.
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'asset_updater_config.dart';

/// Generic live-update service. See the file docstring + the
/// configured behaviour in [AssetUpdaterConfig].
class AssetUpdater {
  AssetUpdater({required this.config, FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  final AssetUpdaterConfig config;
  final FirebaseStorage _storage;

  /// Cap the manifest at 64 KB (ours are well under 1 KB; the SDK
  /// requires a max-bytes arg). Per-file cap is `config.maxFileBytes`
  /// (seed = 8 MB verbatim; photo larger — §0.5 C-f).
  static const _maxManifestBytes = 64 * 1024;

  /// Entry point. Safe to call repeatedly and on a fresh install
  /// (returns silently with no network). NEVER throws.
  Future<void> fetchAndApply() async {
    try {
      final manifest = await _fetchManifest();
      if (manifest == null) return;

      final prefs = await SharedPreferences.getInstance();

      for (final entry in manifest.entries.values) {
        final key = entry.key;

        // Gate 1 — allowlist (the load-bearing security boundary):
        // ignore any key not explicitly recognised.
        if (!config.allowlist.contains(key)) continue;

        // Gate 2 — filename safety (full per-config validator;
        // for seed this is the complete _isSafeManifestFilename
        // logic, NOT a bare extension check — §0.5 C-b).
        if (!config.filenameValidator(entry.filename)) {
          debugPrint(
            'AssetUpdater: rejecting suspicious filename '
            '"${entry.filename}" for $key.',
          );
          continue;
        }

        // Gate 3 — anti-downgrade: never replace a newer local copy
        // with an older remote copy (rollback safety).
        final localVersion =
            prefs.getInt('${config.versionTrackerPrefix}$key') ?? 1;
        if (entry.version <= localVersion) continue;

        // Download + per-config content validation. A rejected file
        // (bad shape / SHA-256 mismatch / network) leaves the local
        // copy untouched — never a partial overwrite.
        final bytes = await _downloadAndValidate(entry);
        if (bytes == null) continue;

        // Mirror the bucket layout under the config's storage root;
        // ensure any subdirectory exists before the atomic write.
        final root = await config.storageRootProvider(key);
        final outFile = File(p.join(root.path, entry.filename));
        await _writeAtomic(outFile, bytes);

        await prefs.setInt(
            '${config.versionTrackerPrefix}$key', entry.version);

        // §0.5 C-c — post-apply side effect. Seed config sets
        // `seed_needs_reseed_<key>=true` here (the launch-critical
        // deferred-re-seed trigger); photo config (Group D)
        // invalidates the decode cache. Without this hook the
        // refactor would silently regress the seed re-seed path.
        await config.onAssetApplied?.call(key, entry.version, prefs);

        debugPrint(
          'AssetUpdater: updated $key to v${entry.version} '
          '(was v$localVersion).',
        );
      }
    } on FirebaseException catch (e) {
      debugPrint('AssetUpdater: Firebase error ${e.code}: ${e.message}');
    } catch (e) {
      // Never let a background update sink the app.
      debugPrint('AssetUpdater: unexpected error: $e');
    }
  }

  /// Fetch + parse the manifest at `config.manifestStoragePath`.
  /// Returns null on any failure (network, 404, parse, wrong shape).
  /// Builds an [AssetEntry] for every well-formed
  /// `{version:int, filename:String}` file (optionally carrying
  /// `sha256`); malformed entries are skipped here — the same
  /// outcome as SeedUpdater's per-entry validity `continue`.
  Future<AssetManifest?> _fetchManifest() async {
    try {
      final ref = _storage.ref(config.manifestStoragePath);
      final raw = await ref.getData(_maxManifestBytes);
      if (raw == null) return null;
      final decoded = json.decode(utf8.decode(raw));
      if (decoded is! Map<String, dynamic>) {
        debugPrint('AssetUpdater: manifest is not a JSON object; ignoring.');
        return null;
      }
      final files = decoded['files'];
      if (files is! Map<String, dynamic>) {
        debugPrint(
          'AssetUpdater: remote manifest has no "files" object; ignoring.',
        );
        return null;
      }
      final out = <String, AssetEntry>{};
      for (final e in files.entries) {
        final spec = e.value;
        if (spec is! Map<String, dynamic>) continue;
        final version = (spec['version'] as num?)?.toInt();
        final filename = spec['filename'];
        if (version == null || filename is! String || filename.isEmpty) {
          continue;
        }
        final sha = spec['sha256'];
        out[e.key] = AssetEntry(
          key: e.key,
          version: version,
          filename: filename,
          expectedSha256: sha is String && sha.isNotEmpty ? sha : null,
        );
      }
      return AssetManifest(out);
    } on FirebaseException catch (e) {
      // `object-not-found` is the EXPECTED state when the bucket is
      // not populated yet (pre-launch / dev) — stay silent so the
      // console isn't littered every cold start. Other codes
      // (permission-denied, etc.) are genuine misconfig — stay loud.
      if (e.code != 'object-not-found') {
        debugPrint('AssetUpdater: manifest fetch failed (${e.code}).');
      }
      return null;
    } on FormatException catch (e) {
      debugPrint('AssetUpdater: manifest JSON parse failed: $e');
      return null;
    }
  }

  /// Download one asset and run the config's content validator.
  /// Returns the raw bytes on success, null on any failure.
  Future<Uint8List?> _downloadAndValidate(AssetEntry entry) async {
    try {
      final ref = _storage.ref(config.storagePathForFile(entry.filename));
      final bytes = await ref.getData(config.maxFileBytes);
      if (bytes == null) return null;
      try {
        config.contentValidator(bytes, entry);
      } on AssetValidationException catch (e) {
        debugPrint('AssetUpdater: ${entry.filename} rejected — $e');
        return null;
      }
      return bytes;
    } on FirebaseException catch (e) {
      if (e.code != 'object-not-found') {
        debugPrint(
            'AssetUpdater: ${entry.filename} fetch failed (${e.code}).');
      }
      return null;
    } on FormatException catch (e) {
      debugPrint('AssetUpdater: ${entry.filename} parse failed: $e');
      return null;
    }
  }

  /// Atomic write: bytes → `<target>.tmp` → rename onto `<target>`.
  /// rename(2) is atomic within a filesystem, so a crash mid-write
  /// never leaves a half-written target (only a discardable `.tmp`,
  /// which readers ignore). Universal across text + binary — the
  /// byte pipeline is identical; `WriteStrategy` is only the
  /// caller/validator encoding contract, not the write path.
  Future<void> _writeAtomic(File target, Uint8List bytes) async {
    final parent = target.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}
