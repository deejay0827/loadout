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
