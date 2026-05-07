// FILE: lib/services/drive_backup_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The cross-platform implementation of `CloudBackupProvider` backed by
// Google Drive's special "appDataFolder". Works on iOS, Android, and any
// other platform Flutter supports — wherever the user can sign in with
// Google. Unlike `ICloudBackupService` which is iOS-only, this is the
// "always available with a Google account" option.
//
// What is the Drive `appDataFolder`? It's a SPECIAL hidden folder Google
// Drive provides to each Drive-using app. Files stored there:
//   - Are scoped per-app — only the app that wrote them can read them.
//   - Are scoped per-Google-account — different account = different folder.
//   - Are HIDDEN from the user's normal drive.google.com UI. The user can
//     see they exist (and revoke the app's access) via Google account
//     settings, but they don't show up when browsing "My Drive".
//   - Count against the user's standard Drive storage quota.
// It's the perfect place for app-managed backups: invisible noise in the
// user's Drive, no risk of accidental human deletion, and trivially
// revocable.
//
// What is "OAuth"? OAuth is the protocol Google (and most other identity
// providers) use to grant a third-party app permission to call their APIs
// on behalf of a signed-in user. The user signs in once, sees a consent
// sheet ("LoadOut wants to manage its own configuration data"), and the
// app receives a short-lived "access token" it can include with each API
// call. We don't see the user's password — Google handles that.
//
// AUTH FLOW (`google_sign_in` 7.x — the new singleton API):
//   1. `GoogleSignIn.instance.initialize()` once per process.
//   2. `attemptLightweightAuthentication()` first — returns null if the
//      user has never signed in or has revoked us. NO UI.
//   3. If null, `authenticate(scopeHint: ['email', 'profile'])` — full
//      interactive sign-in.
//   4. `authorizationForScopes([driveAppdataScope])` — silent check for
//      the Drive scope. Null if not yet granted.
//   5. If null, `authorizeScopes([driveAppdataScope])` — interactive
//      grant. On iOS this is a separate consent sheet; on Android it can
//      usually fold into the same flow as sign-in.
//   6. `authorizationHeaders([driveAppdataScope])` — returns
//      `{'Authorization': 'Bearer ya29...'}` headers.
//
// HOW THE HTTP CLIENT WORKS: the official `googleapis` package wants an
// `http.Client` that injects the OAuth bearer token on every request.
// There used to be a helper package called
// `extension_google_sign_in_as_googleapis_auth` that produced one, but it
// hasn't yet been updated for the `google_sign_in` 7.x singleton API.
// So we hand-roll a minimal `_GoogleAuthClient` that does exactly that —
// it's a `BaseClient` that wraps the package:http default client and
// injects whatever headers the auth call returned. Lifted into its own
// type so it stays testable.
//
// FILE NAMING: every uploaded blob carries a `.lo1` suffix
// ("LoadOut format version 1"). `list()` filters on this so a future
// scenario where this file's appDataFolder is shared with a sibling
// LoadOut feature wouldn't show those files in the backup list.
//
// Public surface:
//
//   - `driveAppdataScope` — the OAuth scope string. PUBLIC constant.
//   - `displayName` — `"Google Drive"`.
//   - `isAvailable()` — calls `attemptLightweightAuthentication` (NO UI)
//     and checks the scope grant. Returns false until the user has gone
//     through interactive sign-in once. We deliberately don't trigger
//     consent sheets here — surprise prompts are a bad UX.
//   - `upload(blob, {filename})` — looks up an existing file by name
//     and either creates or updates. Drive doesn't enforce unique names,
//     so the lookup prevents duplicates piling up across re-uploads.
//   - `list()` — `files.list(spaces: 'appDataFolder')`, filter to `.lo1`,
//     sort newest-first.
//   - `download(meta)` — `files.get(..., DownloadOptions.fullMedia)`. The
//     response is a streamed `Media`; we stage it through the temp dir to
//     give the OS a chance to swap if the blob is large, then read all
//     bytes back in.
//   - `delete(meta)` — `files.delete(fileId)`. Irreversible.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// One of two concrete implementations of `CloudBackupProvider`. The other
// is `ICloudBackupService`. Drive is the cross-platform option — Android
// users have nothing equivalent to iCloud, so Drive is their primary path,
// and iOS users who don't use iCloud (or who want a backup that lives
// outside Apple's ecosystem) can use Drive instead.
//
// In the layer cake:
//
//   Backup screen
//     ↓ via CloudBackupProvider interface
//   DriveBackupService                 ← this file
//     ↓
//   googleapis (drive/v3) + google_sign_in
//     ↓ via _GoogleAuthClient (this file)
//     ↓
//   Google Drive REST API
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. THE AUTH BRIDGE PACKAGE LAGS. As of this writing,
//    `extension_google_sign_in_as_googleapis_auth` doesn't support
//    `google_sign_in` 7.x. We rolled our own `_GoogleAuthClient` to
//    bridge the gap. When the official bridge catches up, we should
//    swap to it.
// 2. NO SURPRISE CONSENT SHEETS. `isAvailable()` only does silent checks.
//    Interactive sign-in happens lazily inside `_openSession`, which is
//    called from each upload/list/download/delete entry point. The user
//    therefore sees the sheet exactly when they tap a backup button —
//    not on app launch, not on screen entry.
// 3. SCOPE GRANULARITY. We use `drive.appdata` — the narrowest Drive
//    scope, which only grants access to OUR appDataFolder. We
//    deliberately don't request `drive.file` or `drive` (full Drive
//    access). Privacy-by-default; if the user inspects the consent sheet
//    they see we cannot read their other Drive files.
// 4. SESSION LIFETIME. Every method opens a fresh `_DriveSession`,
//    runs its work, and closes the underlying socket pool in a finally
//    block. We deliberately don't cache a long-lived session — token
//    refresh is handled by `google_sign_in`, and short-lived sessions
//    are simpler to reason about.
// 5. TEMP FILE STAGING ON DOWNLOAD. Drive returns the blob as a
//    streaming `Media` object. We sink to disk first, then read the file
//    back as bytes. The reason is memory pressure: large blobs streamed
//    fully into memory can OOM low-end devices. Going through disk lets
//    the OS swap if needed.
// 6. DEDUPED UPSERT. The Drive REST API doesn't enforce unique filenames,
//    so two `upload()` calls with the same filename would yield two
//    distinct files. `_findByName` runs a `name = '<escaped>'` query
//    inside the appDataFolder space and switches between `create` and
//    `update` based on the result. We escape single quotes in the
//    filename to keep the q parameter safe.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - The Backup screen instantiates this as one entry in its list of
//   `CloudBackupProvider`s, on every platform.
// - The hand-rolled `_GoogleAuthClient` is private to this file (leading
//   underscore) and not re-exported.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Network: every method except `displayName` and the auth-flow init
//   talks to Google servers (sign-in, OAuth refresh, Drive REST).
// - UI: `_openSession` may surface a Google sign-in sheet and a separate
//   Drive scope consent sheet on iOS the FIRST time the user backs up.
//   Subsequent calls reuse cached credentials silently.
// - Disk: download stages bytes in `path_provider.getTemporaryDirectory()`
//   then deletes the staging file.
// - Plugin: `google_sign_in`, `googleapis`, `http`.
// - Persistence: `google_sign_in` caches its tokens internally; we don't
//   write anything from this file.

import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'cloud_backup.dart';

/// Cross-platform backup target backed by Google Drive's special
/// `appDataFolder`. Files written here are visible only to LoadOut, on a
/// per-Google-account basis — no other app and no human browsing
/// drive.google.com sees them. The user can revoke access at any time
/// from their Google account settings.
///
/// Auth flow (google_sign_in 7.x):
///   1. `GoogleSignIn.instance.initialize()` once per process.
///   2. `authenticate(scopeHint: ['email'])` — interactive sign-in if
///      needed, returns the [GoogleSignInAccount].
///   3. `account.authorizationClient.authorizeScopes([driveAppdataScope])`
///      — additional scope grant. On iOS the user gets a separate
///      consent sheet; on Android the scope can usually be granted in
///      the same flow as sign-in.
///   4. The bridge `extension_google_sign_in_as_googleapis_auth` is *not*
///      compatible with the v7 singleton API yet, so we hand-roll a
///      minimal [http.BaseClient] that injects the bearer token. That
///      feeds the v3 [drive.DriveApi].
///
/// File naming: every uploaded blob is suffixed with `.lo1` so a future
/// `list()` can filter to LoadOut backups even if the user (in some
/// future version) shares the appDataFolder across apps.
class DriveBackupService implements CloudBackupProvider {
  DriveBackupService();

  /// Drive scope that grants access to ONLY the per-app appDataFolder.
  /// This is the minimum-privilege option Drive offers — much narrower
  /// than `drive.file` or `drive`.
  static const String driveAppdataScope =
      'https://www.googleapis.com/auth/drive.appdata';

  static const String _appDataFolder = 'appDataFolder';

  bool _initialized = false;

  @override
  String get displayName => 'Google Drive';

  /// True when Drive is reachable. We only try to silently authorize the
  /// scope here; we do NOT trigger an interactive sign-in. The user
  /// drives that explicitly through [_ensureAuthorized] when they tap a
  /// backup action.
  ///
  /// This means a brand-new install will see "Drive: Sign in to back up"
  /// rather than "Drive available" until the user explicitly initiates
  /// sign-in. That's the desired UX — no surprise consent prompts.
  @override
  Future<bool> isAvailable() async {
    try {
      await _ensureInitialized();
      // attemptLightweightAuthentication doesn't show UI; if it returns
      // null we just say "not available yet" without bothering the user.
      final attempt =
          await GoogleSignIn.instance.attemptLightweightAuthentication();
      if (attempt == null) return false;
      final scoped = await attempt.authorizationClient.authorizationForScopes(
        const [driveAppdataScope],
      );
      return scoped != null;
    } catch (e) {
      debugPrint('DriveBackupService.isAvailable: $e');
      return false;
    }
  }

  /// Run an interactive sign-in + scope grant if necessary. Returns a
  /// ready-to-use [drive.DriveApi]. The caller is responsible for
  /// cleaning up the underlying http client via [_GoogleAuthClient.close]
  /// — wrap calls in try/finally.
  Future<_DriveSession> _openSession() async {
    await _ensureInitialized();
    var account = await GoogleSignIn.instance.attemptLightweightAuthentication();
    account ??= await GoogleSignIn.instance.authenticate(
      scopeHint: const ['email', 'profile'],
    );
    var authz = await account.authorizationClient.authorizationForScopes(
      const [driveAppdataScope],
    );
    authz ??= await account.authorizationClient.authorizeScopes(
      const [driveAppdataScope],
    );
    final headers = await account.authorizationClient.authorizationHeaders(
      const [driveAppdataScope],
    );
    if (headers == null) {
      throw StateError(
        'Google sign-in completed without an access token for the Drive '
        'appData scope. Try signing out and signing back in.',
      );
    }
    final client = _GoogleAuthClient(headers);
    return _DriveSession(client, drive.DriveApi(client));
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize();
    _initialized = true;
  }

  @override
  Future<void> upload(
    List<int> blob, {
    String filename = 'loadout-backup.lo1',
  }) async {
    final session = await _openSession();
    try {
      // Look for an existing file with the same name so we can update in
      // place (Drive doesn't enforce unique names; we don't want to leave
      // duplicates lying around).
      final existing = await _findByName(session.api, filename);

      final media = drive.Media(
        Stream<List<int>>.value(blob),
        blob.length,
      );

      if (existing == null) {
        final fileMeta = drive.File(
          name: filename,
          parents: [_appDataFolder],
        );
        await session.api.files.create(fileMeta, uploadMedia: media);
      } else {
        // For updates, only the media body changes — the name and parent
        // stay the same.
        final fileMeta = drive.File();
        await session.api.files.update(
          fileMeta,
          existing.id!,
          uploadMedia: media,
        );
      }
    } finally {
      session.close();
    }
  }

  @override
  Future<List<CloudBackupMetadata>> list() async {
    final session = await _openSession();
    try {
      final response = await session.api.files.list(
        spaces: _appDataFolder,
        $fields:
            'files(id,name,modifiedTime,size),nextPageToken',
        pageSize: 200,
      );
      final files = response.files ?? const <drive.File>[];
      final filtered = files
          .where((f) => (f.name ?? '').endsWith('.lo1'))
          .toList();
      filtered.sort((a, b) {
        final aTime = a.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
      return filtered.map((f) {
        final size = int.tryParse(f.size ?? '0') ?? 0;
        return CloudBackupMetadata(
          filename: f.name ?? '(unnamed)',
          size: size,
          modifiedAt: f.modifiedTime,
          providerHandle: f.id ?? '',
        );
      }).toList(growable: false);
    } finally {
      session.close();
    }
  }

  @override
  Future<List<int>> download(CloudBackupMetadata meta) async {
    final fileId = meta.providerHandle as String;
    if (fileId.isEmpty) {
      throw StateError('Drive backup is missing its file id.');
    }
    final session = await _openSession();
    try {
      final media = await session.api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      // Stage the bytes through the temp directory for symmetry with
      // [ICloudBackupService.download], then return them in memory. Drive
      // doesn't pre-buffer — this gives the OS a chance to swap if the
      // blob is very large.
      final temp = await getTemporaryDirectory();
      final stagedFile =
          File('${temp.path}/${meta.filename}.drive-download');
      final sink = stagedFile.openWrite();
      try {
        await media.stream.forEach(sink.add);
      } finally {
        await sink.close();
      }
      final bytes = await stagedFile.readAsBytes();
      try {
        await stagedFile.delete();
      } catch (_) {
        // Best-effort.
      }
      return bytes;
    } finally {
      session.close();
    }
  }

  @override
  Future<void> delete(CloudBackupMetadata meta) async {
    final fileId = meta.providerHandle as String;
    if (fileId.isEmpty) {
      throw StateError('Drive backup is missing its file id.');
    }
    final session = await _openSession();
    try {
      await session.api.files.delete(fileId);
    } finally {
      session.close();
    }
  }

  Future<drive.File?> _findByName(
    drive.DriveApi api,
    String filename,
  ) async {
    final escaped = filename.replaceAll("'", r"\'");
    final response = await api.files.list(
      spaces: _appDataFolder,
      q: "name = '$escaped'",
      $fields: 'files(id,name)',
      pageSize: 1,
    );
    final files = response.files ?? const <drive.File>[];
    if (files.isEmpty) return null;
    return files.first;
  }
}

/// Pairs a [drive.DriveApi] with the underlying [http.Client] so callers
/// can close the socket pool when they're done.
class _DriveSession {
  _DriveSession(this.client, this.api);
  final _GoogleAuthClient client;
  final drive.DriveApi api;
  void close() => client.close();
}

/// Tiny [http.BaseClient] that injects auth headers grabbed from the
/// [GoogleSignInAuthorizationClient]. Equivalent to the
/// `extension_google_sign_in_as_googleapis_auth` helper but works with
/// the google_sign_in 7.x singleton API where the extension hasn't yet
/// caught up. Lifted into its own type so it stays testable.
class _GoogleAuthClient extends http.BaseClient {
  _GoogleAuthClient(this._headers);
  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

