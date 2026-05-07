// FILE: lib/services/icloud_backup_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The iOS-only implementation of `CloudBackupProvider`. Wraps the
// `icloud_storage` Flutter plugin to read and write encrypted backup blobs
// inside an Apple iCloud "ubiquity container". The user's iCloud Drive ends
// up holding the encrypted bytes — LoadOut never sees them after upload, and
// they never go through any of our servers.
//
// What is "iCloud Drive"? It's Apple's user-facing cloud storage. Each Apple
// ID has a quota, and each app can carve out a private folder ("ubiquity
// container") inside it that ONLY that app can read or write. Files there
// can also be made visible to the user via the Files app — that's how the
// `Backups` subdirectory becomes browsable under "iCloud Drive → LoadOut →
// Backups" in Files.app.
//
// What is a "ubiquity container"? Apple's term for the per-app slice of
// iCloud Drive. Identified by a string of the form `iCloud.<bundle id>`.
// Ours is `iCloud.com.johnsondigital.loadout`. To use it, the app must
// declare the entitlement `com.apple.developer.icloud-services` with
// `CloudDocuments` in `ios/Runner/Runner.entitlements` AND the same
// container ID must be enabled at developer.apple.com → Identifiers →
// `com.johnsondigital.loadout` → "iCloud Documents". Until both are in
// place, every plugin call below fails.
//
// PRIVACY DESIGN: we use the user's OWN iCloud account, not a LoadOut
// server-side iCloud bucket. That means:
// - LoadOut never sees the blob after upload.
// - The user's blob never leaves Apple's infrastructure.
// - Storage quota comes out of the user's iCloud allotment.
// - Privacy is the user's normal Apple privacy posture — not a separate
//   contract with us.
// (And because the blob itself is encrypted with the user's passphrase via
// `BackupCrypto`, even a plaintext leak from Apple wouldn't reveal load data.)
//
// Public surface (all overrides of `CloudBackupProvider`):
//
//   - `containerId` — the CloudKit container identifier, mirrored in the
//     iOS entitlements file. Public constant so it can be referenced in
//     diagnostics if needed.
//   - `displayName` — `"iCloud Drive"`.
//   - `isAvailable()` — calls `ICloudStorage.gather` (a list operation) as
//     a probe. Even an empty list means the container resolved; any
//     exception means iCloud isn't signed in, the capability isn't
//     provisioned, or the entitlement was stripped at build time. Always
//     false on non-iOS platforms.
//   - `upload(blob, {filename})` — stages the bytes in a temp file, then
//     calls `ICloudStorage.upload` to copy them into the container under
//     `Documents/Backups/<filename>`. The plugin's API is path-based, not
//     bytes-based, so the temp-file dance is unavoidable. Cleans up the
//     staging file in a finally block (best-effort; the temp dir is
//     OS-purged anyway).
//   - `list()` — calls `ICloudStorage.gather`, filters to files under
//     `Backups/` ending in `.lo1`, sorts newest-first. The `.lo1` suffix
//     is LoadOut's "encrypted backup, format version 1" marker; we filter
//     so a future second feature (e.g. exported chronograph CSVs) writing
//     into the same container wouldn't pollute the list.
//   - `download(meta)` — pulls the file via `ICloudStorage.download`,
//     reads it from disk, deletes the staging file. Returns bytes.
//   - `delete(meta)` — calls `ICloudStorage.delete`. Irreversible.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// One of two concrete implementations of `CloudBackupProvider`. The other
// is `DriveBackupService`. The Backup screen typically shows iCloud first
// on iOS (when available) and Drive as the cross-platform fallback.
//
// In the layer cake:
//
//   Backup screen
//     ↓ via CloudBackupProvider interface
//   ICloudBackupService               ← this file
//     ↓
//   icloud_storage plugin
//     ↓
//   Apple's CloudKit / NSFileCoordinator under the hood
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. iOS-ONLY. Every method early-returns or throws `UnsupportedError` on
//    non-iOS platforms. We chose `UnsupportedError` (not just a silent no-op)
//    so any accidental call from cross-platform code surfaces loudly during
//    development.
// 2. ENTITLEMENT GATING. The CloudKit container can only be accessed when
//    the iCloud Documents entitlement is enabled on the App ID at
//    developer.apple.com. If a build is signed without it, every call
//    fails. `isAvailable()` returns false in that case rather than
//    crashing — the Backup screen then shows a helpful "iCloud isn't
//    available" message instead of a stack trace.
// 3. iCLOUD SIGN-IN STATE IS DYNAMIC. The user can sign out of iCloud
//    in Settings.app at any time, including while the app is suspended.
//    Reflecting that in `isAvailable()` requires the live probe — caching
//    the result would lie to the user.
// 4. PATH-BASED API. The plugin uploads/downloads via file paths. We
//    stage in `path_provider.getTemporaryDirectory()` so the OS will
//    purge the staging file even if our cleanup misses.
// 5. FILE LIST PAGING. `ICloudStorage.gather` returns the full list at
//    once — no paging. Acceptable for this feature because backups are
//    rare and small.
// 6. FILE DELETION ORDERING. We delete the staging file in `download` AFTER
//    reading bytes. The plugin's destination file lives long enough for us
//    to read; the iCloud copy is the canonical one and is unaffected.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - The Backup screen instantiates this on iOS as one entry in its list
//   of `CloudBackupProvider`s.
// - It is not referenced from any non-iOS code path. The screen guards
//   construction with `Platform.isIOS`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Disk: writes/reads in `path_provider.getTemporaryDirectory()` for
//   staging. The temp directory is OS-purged on uninstall and after
//   inactivity.
// - Network: upload/download/delete all touch Apple's iCloud servers via
//   the plugin.
// - Plugin: `icloud_storage`. Requires the matching iOS entitlement.
// - No persistence beyond the cloud blob itself.

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:icloud_storage/icloud_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'cloud_backup.dart';

/// iOS-only backup target. Writes the encrypted blob to the app's
/// CloudKit ubiquity container under `Documents/Backups/<filename>`.
///
/// The container ID is `iCloud.com.johnsondigital.loadout` — declared in
/// `ios/Runner/Runner.entitlements` AND must be enabled at
/// developer.apple.com → Identifiers → com.johnsondigital.loadout →
/// "iCloud Documents". Until it is, [isAvailable] returns false and the
/// Backup screen surfaces a "Sign in to iCloud in Settings" message
/// instead of crashing.
///
/// We intentionally don't surface anything beyond filename / size /
/// modified date in [list]. The container is per-app private; LoadOut
/// never inspects the file contents — they're an opaque encrypted blob
/// per [BackupCrypto].
class ICloudBackupService implements CloudBackupProvider {
  ICloudBackupService();

  /// CloudKit container identifier. Mirror this in
  /// `ios/Runner/Runner.entitlements`.
  static const String containerId = 'iCloud.com.johnsondigital.loadout';

  /// Subdirectory inside the container's `Documents/`. Keeps backups
  /// grouped under one Files.app folder so the user can find them.
  static const String _backupsFolder = 'Backups';

  @override
  String get displayName => 'iCloud Drive';

  /// True on iOS when the iCloud container is reachable. We probe by
  /// asking the plugin to list files — this is cheap, requires no UI, and
  /// fails fast if the capability isn't enabled.
  ///
  /// Always false on non-iOS builds (Android, desktop, web).
  @override
  Future<bool> isAvailable() async {
    if (!Platform.isIOS) return false;
    try {
      // A successful gather (even of zero files) means the container
      // resolved. Any exception means iCloud isn't signed in, the
      // capability isn't provisioned, or the entitlement was stripped at
      // build time.
      await ICloudStorage.gather(containerId: containerId);
      return true;
    } catch (e) {
      debugPrint('ICloudBackupService.isAvailable: $e');
      return false;
    }
  }

  @override
  Future<void> upload(
    List<int> blob, {
    String filename = 'loadout-backup.lo1',
  }) async {
    if (!Platform.isIOS) {
      throw UnsupportedError('iCloud Drive is only available on iOS.');
    }
    // The plugin uploads a file by path. Stage the bytes in the temp dir,
    // then ask iCloud to copy them into the container.
    final temp = await getTemporaryDirectory();
    final stagedPath = '${temp.path}/$filename';
    final staged = File(stagedPath);
    await staged.writeAsBytes(Uint8List.fromList(blob), flush: true);

    try {
      await ICloudStorage.upload(
        containerId: containerId,
        filePath: stagedPath,
        destinationRelativePath: '$_backupsFolder/$filename',
      );
    } finally {
      // The plugin streams from disk asynchronously, but once it returns
      // we can drop the staging file — iCloud has its own copy.
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {
        // Cleanup is best-effort. Temp dir gets purged by the OS anyway.
      }
    }
  }

  @override
  Future<List<CloudBackupMetadata>> list() async {
    if (!Platform.isIOS) return const [];
    final files = await ICloudStorage.gather(containerId: containerId);
    final filtered = files.where((f) {
      final relPath = f.relativePath;
      return relPath.startsWith('$_backupsFolder/') &&
          relPath.endsWith('.lo1');
    }).toList();
    filtered.sort((a, b) {
      final aDate = a.contentChangeDate;
      final bDate = b.contentChangeDate;
      return bDate.compareTo(aDate);
    });
    return filtered.map((f) {
      final base = f.relativePath.substring(_backupsFolder.length + 1);
      return CloudBackupMetadata(
        filename: base,
        size: f.sizeInBytes,
        modifiedAt: f.contentChangeDate,
        providerHandle: f.relativePath,
      );
    }).toList(growable: false);
  }

  @override
  Future<List<int>> download(CloudBackupMetadata meta) async {
    if (!Platform.isIOS) {
      throw UnsupportedError('iCloud Drive is only available on iOS.');
    }
    final relativePath = meta.providerHandle as String;
    final temp = await getTemporaryDirectory();
    final localPath = '${temp.path}/${meta.filename}.download';
    await ICloudStorage.download(
      containerId: containerId,
      relativePath: relativePath,
      destinationFilePath: localPath,
    );
    final localFile = File(localPath);
    final bytes = await localFile.readAsBytes();
    try {
      await localFile.delete();
    } catch (_) {
      // Best-effort.
    }
    return bytes;
  }

  @override
  Future<void> delete(CloudBackupMetadata meta) async {
    if (!Platform.isIOS) {
      throw UnsupportedError('iCloud Drive is only available on iOS.');
    }
    final relativePath = meta.providerHandle as String;
    await ICloudStorage.delete(
      containerId: containerId,
      relativePath: relativePath,
    );
  }
}
