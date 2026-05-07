// FILE: lib/services/seed_updater.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Provides `SeedUpdater`, the one-shot, fire-and-forget service that pulls
// fresh reference-catalog JSON from Firebase Storage on cold start. Its job
// is to let the LoadOut team ship corrections to the bundled catalog data
// (cartridges, powders, bullets, primers, brass, firearms, firearm_parts)
// WITHOUT requiring an App Store / Play Store release.
//
// The flow on launch is:
//
//   1. `main.dart` opens the SQLite database, runs `SeedLoader.seedIfNeeded()`
//      against the currently-cached JSON (bundled or downloaded), then calls
//      `unawaited(SeedUpdater(db).checkForUpdates())` and proceeds to
//      `runApp()`. The user sees the UI immediately — the network check is
//      not on the splash path.
//   2. `checkForUpdates()` downloads `seed_data/manifest.json` from Firebase
//      Storage and compares each entry's `version` against the SharedPrefs
//      key `seed_version_<key>` (defaulting to `1`).
//   3. For every file whose remote version is strictly greater, it
//      downloads the JSON, validates the shape, writes it to
//      `<applicationDocumentsDirectory>/seed_data/<filename>`, bumps the
//      cached version, and sets a SharedPrefs flag
//      (`seed_needs_reseed_<key> = true`) telling the next launch's
//      `seedIfNeeded()` to repopulate the corresponding Drift table from
//      the new file.
//
// Re-seeding is deferred to the next launch on purpose: re-running
// `_seedX()` requires deleting and re-inserting potentially thousands of
// rows inside a transaction, which is heavy work. Doing it on launch N+1
// means the user already saw their dropdowns populated at launch N (with
// the old data, which is harmless), and by launch N+1 the new file is on
// disk and the seed runs synchronously before the UI builds.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The bundled `assets/seed_data/*.json` files are baked into the app binary
// at build time. Fixing a typo in a powder name, adding a new cartridge,
// or correcting a SAAMI value normally requires a full release: bump
// `pubspec.yaml`, archive, upload, wait days for review, hope users
// upgrade. Using Firebase Storage as a CDN for the same JSON files means
// we can hot-fix the catalog by uploading a new file + bumping a version
// in `manifest.json`. The next time a user opens the app, they see the
// fix.
//
// Reference data only — the privacy posture is preserved. Nothing about a
// user's loads, firearms, or custom components ever leaves the device
// (see `PRIVACY_POLICY.md`). This is one-way, our-server-to-device.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The check MUST be fire-and-forget. Blocking the UI on a network round
// trip would pessimize cold-start time for every user, every launch,
// even though most launches won't have an update to apply. The cost of
// "the user sees the old catalog for one extra launch" is much smaller
// than the cost of "every launch waits 1-2 seconds for a manifest GET."
//
// SharedPreferences is used for two state fields per file:
//
//   - `seed_version_<key>`: monotonically-increasing integer. Default 1
//     for fresh installs (matching the bundled manifest's starting
//     version). Updated to the remote value after a successful download.
//   - `seed_needs_reseed_<key>`: boolean flag set to true when a download
//     completes; cleared by `SeedLoader` after the re-seed transaction
//     commits.
//
// Anti-downgrade is enforced: if the remote manifest version is LESS than
// the cached version (which can happen during a rollback), we do nothing.
// We don't downgrade local data because the local data is presumed
// newer-than-bundled, and replacing it with an older version would
// silently regress fixes the user already received.
//
// Validation: we don't blindly trust the JSON we download. After parsing
// we sanity-check the shape — for `cartridges.json` the top-level value
// must be a `List`; for the others it must be a `Map` with a
// `manufacturers` key whose value is a `List`. A malformed file is
// rejected (we log and keep the local one); we never partially overwrite
// a good local file with a bad downloaded one.
//
// Failure modes:
//   - Network failure: skipped this launch; tried again next launch.
//   - 404 on the manifest or a file: logged, next launch tries again.
//     We never delete cached files in response to a 404 — the bundled
//     fallback in the app is always present.
//   - JSON parse failure: rejected; cached file (if any) and SharedPrefs
//     flags are left as they were.
//   - Storage SDK throws (e.g. unauthenticated, permission-denied):
//     swallowed at the top level so a misconfigured Firebase project
//     never crashes the app.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/main.dart` — fires the check after `SeedLoader.seedIfNeeded()`.
// - `lib/database/seed_loader.dart` — reads files written here from the
//   documents directory in preference to the bundled assets, and clears
//   the `seed_needs_reseed_<key>` flag once it has re-seeded.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Network: one HTTP GET for the manifest, plus one per stale file.
// - Disk: writes <docs>/seed_data/<filename> for any updated file.
// - SharedPreferences: writes `seed_version_<key>` and
//   `seed_needs_reseed_<key>` per updated file.
// - Does NOT touch SQLite. The actual table re-seed is deferred to the
//   next launch's `SeedLoader.seedIfNeeded()`.

import 'dart:convert';
import 'dart:io';

// `FirebaseException` is re-exported from `firebase_storage` so we don't
// need a separate `firebase_core` import.
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/database.dart';

/// Storage path prefix where the manifest and the seed JSON files live.
/// Mirrored locally under `<docs>/seed_data/...`.
const _storagePrefix = 'seed_data';

/// Filename of the manifest in both Firebase Storage and the documents dir.
const _manifestFilename = 'manifest.json';

/// SharedPreferences key prefixes. One pair per logical file
/// (e.g. `seed_version_cartridges`, `seed_needs_reseed_cartridges`).
const seedVersionPrefix = 'seed_version_';
const seedNeedsReseedPrefix = 'seed_needs_reseed_';

/// Logical keys we recognize in a manifest. Anything outside this set is
/// ignored — keeps a malicious or future-shape manifest from writing
/// arbitrary files into the documents directory.
const _allowedKeys = <String>{
  'cartridges',
  'powders',
  'bullets',
  'primers',
  'brass',
  'firearms',
  'firearm_parts',
  'optics',
};

/// Pulls fresh reference-catalog JSON from Firebase Storage and caches it
/// to the documents directory. See file-level docstring for the full flow.
class SeedUpdater {
  SeedUpdater(this.db, {FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  /// The application database. Currently unused inside this class — held
  /// because callers conceptually pair the updater with a database, and
  /// because future schema-aware update gating (e.g. "skip a file if the
  /// app's schema version is older than the file requires") would need it.
  final AppDatabase db;
  final FirebaseStorage _storage;

  /// Entry point. Safe to call repeatedly; safe to call on a fresh install
  /// (returns silently if the network is unavailable). Never throws.
  Future<void> checkForUpdates() async {
    try {
      final manifest = await _fetchRemoteManifest();
      if (manifest == null) return;

      final files = manifest['files'];
      if (files is! Map<String, dynamic>) {
        debugPrint(
          'SeedUpdater: remote manifest has no "files" object; ignoring.',
        );
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final docsDir = await _ensureSeedDataDir();

      for (final entry in files.entries) {
        final key = entry.key;
        if (!_allowedKeys.contains(key)) continue;

        final spec = entry.value;
        if (spec is! Map<String, dynamic>) continue;

        final remoteVersion = (spec['version'] as num?)?.toInt();
        final filename = spec['filename'];
        if (remoteVersion == null || filename is! String || filename.isEmpty) {
          continue;
        }

        // Don't trust the manifest's filename to navigate out of the
        // seed_data directory — only allow simple basenames.
        if (filename.contains('/') || filename.contains('\\')) {
          debugPrint(
            'SeedUpdater: rejecting suspicious filename "$filename" for $key.',
          );
          continue;
        }

        final localVersion = prefs.getInt('$seedVersionPrefix$key') ?? 1;

        // Anti-downgrade: never replace a newer local copy with an older
        // remote copy.
        if (remoteVersion <= localVersion) continue;

        final downloaded = await _downloadAndValidate(key, filename);
        if (downloaded == null) continue;

        final outFile = File(p.join(docsDir.path, filename));
        await outFile.writeAsString(downloaded);

        await prefs.setInt('$seedVersionPrefix$key', remoteVersion);
        await prefs.setBool('$seedNeedsReseedPrefix$key', true);

        debugPrint(
          'SeedUpdater: updated $key to v$remoteVersion '
          '(was v$localVersion); will re-seed on next launch.',
        );
      }
    } on FirebaseException catch (e) {
      debugPrint('SeedUpdater: Firebase error ${e.code}: ${e.message}');
    } catch (e) {
      // Never let a background update sink the app.
      debugPrint('SeedUpdater: unexpected error: $e');
    }
  }

  /// Downloads `seed_data/manifest.json` from Storage and parses it into
  /// a Map. Returns null on any failure (network, 404, parse).
  Future<Map<String, dynamic>?> _fetchRemoteManifest() async {
    try {
      final ref = _storage.ref('$_storagePrefix/$_manifestFilename');
      final bytes = await ref.getData(_maxManifestBytes);
      if (bytes == null) return null;
      final text = utf8.decode(bytes);
      final decoded = json.decode(text);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('SeedUpdater: manifest is not a JSON object; ignoring.');
        return null;
      }
      return decoded;
    } on FirebaseException catch (e) {
      // `object-not-found` is the *expected* state when the Storage bucket
      // hasn't been populated yet (pre-launch, or in dev environments
      // without the catalog uploaded). Stay silent in that case so the
      // dev console isn't littered with a benign warning every cold
      // start. Other codes (permission-denied, unauthenticated, etc.)
      // mean something is genuinely misconfigured and stay loud.
      if (e.code != 'object-not-found') {
        debugPrint('SeedUpdater: manifest fetch failed (${e.code}).');
      }
      return null;
    } on FormatException catch (e) {
      debugPrint('SeedUpdater: manifest JSON parse failed: $e');
      return null;
    }
  }

  /// Downloads one seed file and validates its shape against what the seed
  /// loader expects. Returns the raw JSON string on success, null on any
  /// failure.
  Future<String?> _downloadAndValidate(String key, String filename) async {
    try {
      final ref = _storage.ref('$_storagePrefix/$filename');
      final bytes = await ref.getData(_maxSeedBytes);
      if (bytes == null) return null;

      final text = utf8.decode(bytes);
      final decoded = json.decode(text);

      if (!_validateShape(key, decoded)) {
        debugPrint(
          'SeedUpdater: $filename has unexpected shape; rejecting.',
        );
        return null;
      }
      return text;
    } on FirebaseException catch (e) {
      // Same rationale as `_fetchRemoteManifest`: silence the expected
      // `object-not-found` so a not-yet-populated Storage bucket doesn't
      // spam the console.
      if (e.code != 'object-not-found') {
        debugPrint('SeedUpdater: $filename fetch failed (${e.code}).');
      }
      return null;
    } on FormatException catch (e) {
      debugPrint('SeedUpdater: $filename JSON parse failed: $e');
      return null;
    }
  }

  /// Returns true when the parsed JSON matches the expected top-level shape
  /// for `key`. `cartridges` is a flat list; everything else is an object
  /// with a `manufacturers` list.
  bool _validateShape(String key, Object? decoded) {
    if (key == 'cartridges') {
      return decoded is List;
    }
    if (decoded is! Map<String, dynamic>) return false;
    final manufacturers = decoded['manufacturers'];
    return manufacturers is List;
  }

  /// Ensures `<applicationDocumentsDirectory>/seed_data/` exists and
  /// returns it.
  Future<Directory> _ensureSeedDataDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _storagePrefix));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cap the manifest at 64 KB; in practice ours is well under 1 KB but
  /// the SDK requires a max-bytes argument.
  static const _maxManifestBytes = 64 * 1024;

  /// Cap any single seed file at 8 MB. The largest bundled file today is
  /// `cartridges.json` at well under 1 MB, so 8x leaves headroom for
  /// growth without giving an attacker an unlimited write.
  static const _maxSeedBytes = 8 * 1024 * 1024;
}
