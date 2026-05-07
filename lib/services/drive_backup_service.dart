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

