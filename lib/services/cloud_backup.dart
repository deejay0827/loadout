// Provider-agnostic types shared by [ICloudBackupService] and
// [DriveBackupService]. Kept tiny on purpose: the Backup screen only needs
// timestamps and sizes to render its list, and an opaque handle to round-trip
// to the underlying provider on download/delete.

/// Lightweight metadata about a single backup blob in the user's cloud
/// storage. The Backup screen renders these in a list and uses [providerHandle]
/// to round-trip to the per-provider service when downloading or deleting.
///
/// Both providers expose roughly the same shape; [providerHandle] holds the
/// cheapest identifier each one needs (filename for iCloud, file id for
/// Drive). Treat it as opaque.
class CloudBackupMetadata {
  const CloudBackupMetadata({
    required this.filename,
    required this.size,
    this.modifiedAt,
    required this.providerHandle,
  });

  final String filename;

  /// Size of the encrypted blob in bytes. UI converts this to KB/MB.
  final int size;

  /// Last-modified timestamp from the provider. Null when the provider
  /// can't report one (rare).
  final DateTime? modifiedAt;

  /// Provider-specific identifier — Drive `fileId` or iCloud relative path.
  /// Treat as opaque outside the matching service.
  final Object providerHandle;
}

/// Common contract every backup provider implements. The Backup screen
/// holds a list of these and lets the user pick which one to drive. Both
/// providers can be inactive (iCloud signed-out, Google account not linked)
/// — the screen tests [isAvailable] before showing the action buttons.
abstract class CloudBackupProvider {
  /// Human-readable provider name for the UI (e.g. "iCloud Drive").
  String get displayName;

  /// True if this provider is currently usable. iCloud returns false on
  /// Android, when the iCloud capability isn't enabled, or when iCloud
  /// isn't signed in. Drive returns false until the user signs in with
  /// Google.
  Future<bool> isAvailable();

  /// Upload [blob] under [filename]. Overwrites if a file with the same
  /// name already exists. Throws on transport / quota errors.
  Future<void> upload(
    List<int> blob, {
    String filename = 'loadout-backup.lo1',
  });

  /// Returns metadata for every LoadOut backup the provider can see.
  /// Order is newest-first when timestamps are available.
  Future<List<CloudBackupMetadata>> list();

  /// Download the blob referenced by [meta]. Throws if the provider can no
  /// longer find the file (deleted from another device).
  Future<List<int>> download(CloudBackupMetadata meta);

  /// Permanently delete the blob referenced by [meta]. The encrypted blob
  /// has no LoadOut-side mirror, so a delete here is irreversible.
  Future<void> delete(CloudBackupMetadata meta);
}
