// FILE: lib/services/cloud_backup.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines the provider-AGNOSTIC types that the cloud-backup feature is built
// around. There are exactly two declarations in this file:
//
//   1. `CloudBackupMetadata` — a small data class describing a single backup
//      blob in the user's cloud storage. Carries the four things the Backup
//      screen needs to render: filename, size in bytes, modified date, and
//      an opaque `providerHandle` that the matching service uses to
//      round-trip to the underlying API on download/delete.
//
//   2. `CloudBackupProvider` — an ABSTRACT class (Dart's term for an
//      interface) that every concrete cloud backend implements. Methods:
//        - `displayName` — a human-readable name like "iCloud Drive".
//        - `isAvailable()` — async check; can the app actually use this
//          provider right now? (False on Android for iCloud, false until
//          sign-in for Drive.)
//        - `upload(blob, {filename})` — push a fresh backup. Overwrites
//          if a file with the same name already exists.
//        - `list()` — returns metadata for every LoadOut backup the
//          provider can see, newest-first when timestamps allow.
//        - `download(meta)` — fetch the bytes for a given metadata entry.
//        - `delete(meta)` — permanently remove a backup. The encrypted
//          blob has no LoadOut-side mirror, so this is irreversible.
//
// What is an "abstract class" / "interface" here? In Dart, declaring a
// class as `abstract class` with method signatures only means "any class
// that says `implements CloudBackupProvider` must define all of these
// methods themselves." It's how Dart expresses "these two completely
// different APIs (Apple's iCloud SDK and Google's Drive REST API) can
// be swapped behind the same shape."
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// In the layer cake:
//
//   UI (Backup screen)
//     ↓ holds a List<CloudBackupProvider>
//   CloudBackupProvider               ← this file (interface only)
//     ├── ICloudBackupService         (iOS)
//     └── DriveBackupService          (cross-platform)
//
// The UI never imports `icloud_backup_service.dart` or `drive_backup_service.dart`
// directly — it imports this file and works with the abstract type. The
// concrete services are wired up at provider construction time. That means:
// 1. Adding a third provider (e.g. Dropbox) only touches the registration
//    site, not every screen.
// 2. The screen can be unit-tested with a fake `CloudBackupProvider` that
//    answers from an in-memory map.
// 3. Apple and Google's APIs have nothing in common — Apple uses CloudKit
//    ubiquity containers via the `icloud_storage` plugin, Google uses a
//    REST API via `googleapis`. Neither could absorb the other; the
//    abstraction has to live above both.
//
// `CloudBackupMetadata.providerHandle` is intentionally typed as `Object`
// — it carries either a `String` filename (iCloud) or a `String` Drive
// fileId. Treat as opaque outside the matching service.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. AVAILABILITY IS DYNAMIC. `isAvailable()` can flip between true and
//    false at runtime — user signs out of iCloud, user revokes Google
//    access, user toggles airplane mode. The Backup screen calls it
//    before showing the action buttons, but the buttons themselves still
//    have to handle "no longer available" exceptions gracefully.
// 2. TIMESTAMPS ARE OPTIONAL. Some provider edge cases (newly-uploaded
//    files where the modifiedTime hasn't propagated yet) return null.
//    `modifiedAt` is nullable so the UI can show "—" instead of crashing.
// 3. NO ENUMERATION OF PROVIDERS HERE. This file does NOT contain a
//    factory or registry that hands out the right provider for the
//    current platform — that's the Backup screen's job. Keeping the
//    interface dependency-free means it can be shared with tests without
//    pulling in the iCloud or Google SDKs.
// 4. DELETE IS IRREVERSIBLE. There is no LoadOut-side trash. Once delete
//    succeeds, the blob is gone from the user's cloud — and because it
//    was encrypted at rest, nothing else has a copy.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - /Users/general/Development/Applications/LoadOut/lib/services/icloud_backup_service.dart
//   implements `CloudBackupProvider`.
// - /Users/general/Development/Applications/LoadOut/lib/services/drive_backup_service.dart
//   implements `CloudBackupProvider`.
// - The Backup screen consumes BOTH the interface (typed as
//   `CloudBackupProvider`) and `CloudBackupMetadata` for list rendering.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. This file declares only types. The actual side effects live in the
// concrete services.

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
