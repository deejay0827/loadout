// FILE: lib/services/cloud_sync_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Continuous, end-to-end-encrypted, cross-device sync of the user's
// LoadOut SQLite database. Sits one layer ABOVE the existing backup
// infrastructure ([ExportService], [BackupCrypto], the three
// [CloudBackupProvider] implementations) and orchestrates pushes
// (`syncUp`) and pulls (`syncDown`) on the canonical encrypted blob
// `loadout_sync.encrypted` in the active provider's app folder.
//
// The privacy contract from CLAUDE.md §13 is preserved EXACTLY:
//
//   * Same passphrase-derived key (`BackupCrypto`).
//   * Same AES-256-GCM + PBKDF2-200k cipher.
//   * Same provider abstraction — blob lives in the user's own iCloud
//     Drive / Google Drive / OneDrive container.
//   * No LoadOut-operated backend touches the blob.
//
// What this service ADDS on top of the existing backup screen:
//
//   1. A persistent on/off bit (`sync_enabled`) so the rest of the
//      app can ask "is sync running?" without poking at provider
//      internals.
//   2. A `lastSyncedAt` / `lastRemoteUpdateAt` pair that drives the
//      Settings → Cloud Sync screen status line and the AppBar
//      indicator dot.
//   3. A debounced [syncUp] call wired into the global
//      [AutoSaveService]. When AutoSave fires for any form, sync
//      schedules an upload 5 seconds later; the timer resets on
//      every save, so a rapid burst of edits coalesces into one
//      upload at the end.
//   4. Boot-time [syncDown] called from `app.dart` so opening the
//      app on a phone picks up changes saved earlier on a tablet.
//   5. A manual [reconcile] (download → merge → upload) for the
//      "Sync Now" button.
//
// PASSPHRASE STORAGE: per CLAUDE.md §17, we cache the passphrase in
// `flutter_secure_storage` keyed by provider — `sync_passphrase_icloud`,
// `sync_passphrase_gdrive`, `sync_passphrase_onedrive`. The Cloud Sync
// screen prompts once on enable, persists the value, and never asks
// again on this device unless the user disconnects. Other devices
// re-prompt at first enable (no LoadOut server distributes the
// passphrase). LOSING THE PASSPHRASE IS UNRECOVERABLE — same caveat as
// the existing manual backup flow.
//
// MERGE MECHANICS:
//   * One canonical blob, `loadout_sync.encrypted`. Don't shard by
//     table — keeps the merge logic local.
//   * On `syncDown`, decrypt → parse JSON → walk every user-data
//     table. For each remote row:
//       - if no local row with the same id, insert it,
//       - if a local row exists and `local.updatedAt >= remote.updatedAt`,
//         keep local,
//       - else apply remote (`InsertMode.insertOrReplace`).
//   * Local-only rows (created since the last sync) are LEFT ALONE.
//     They'll be pushed on the next `syncUp`.
//   * Last-writer-wins by row `updatedAt`. Tables without an
//     `updatedAt` column (e.g. seed-only tables, append-only
//     `TestSessions`) fall back to `createdAt`, then to "remote
//     wins on collision" — the simplest deterministic fallback.
//   * No CRDT — explicitly out of scope for v1. Personal reloading
//     data on two devices is a soft conflict at most.
//
// CONFLICT EXAMPLE (the rare case):
//   Device A (offline) edits load #42 at 14:00; the new
//   `updatedAt` is 14:00. Device B (offline) edits load #42 at
//   13:30; its `updatedAt` is 13:30. Device A reconnects first,
//   pushes — remote blob now has 14:00. Device B reconnects, pulls
//   — sees remote 14:00 vs local 13:30, overwrites local with
//   remote. B's edit is lost. This is acceptable for personal
//   data; users who care about this should use the manual
//   "Backup → Restore" Pro flow which prompts for confirmation.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Pre-launch reloaders running LoadOut on a phone + tablet were
// asked to manually backup and restore between devices. That works
// for migration but not for "I added a new load on my phone, will
// it show up on my iPad?" — which is what cross-device sync
// actually means in 2026. Without `CloudSyncService` we'd be
// telling Pro users "yes you have cloud, but you have to manually
// click backup and restore." Continuous sync removes that friction.
//
// In the layer cake:
//
//   AutoSaveService.notifyDirty() ──── flush() ──── manual button
//          │                              │              │
//          ▼                              ▼              ▼
//   CloudSyncService.scheduleSyncUp / syncUp / reconcile         ← this file
//          │                              │              │
//          ▼                              ▼              ▼
//   ExportService.exportToJson()  +  BackupCrypto  +  CloudBackupProvider
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. DEBOUNCE + COALESCE. Every form save fires AutoSave; without
//    debouncing, a 10-character recipe-name change would push 10
//    times. We coalesce all dirty bits into one upload after a
//    5-second quiet window. Calling `syncUp` while one is already
//    in flight queues a follow-up rather than running concurrently
//    (two simultaneous PUTs to the same blob would race).
// 2. NEVER LOSE DATA. The merge in `syncDown` MUST NOT drop local-only
//    rows — they're the user's just-typed data. We accomplish that
//    by walking the inbound list and only ever inserting / overwriting
//    on remote-id match; local rows whose ids don't appear remotely
//    stay untouched. This is asymmetric on purpose.
// 3. TIMESTAMP COMPARISON IS FRAGILE. Drift uses ISO-8601 strings
//    when serializing DateTime in JSON. We parse via DateTime.parse
//    and compare with `>=` so a row touched at the exact same
//    millisecond by both devices keeps local. Rows whose
//    `updatedAt` is null on both sides default to "remote wins" so
//    the inbound payload doesn't get silently dropped.
// 4. PROVIDER SWITCHING. If the user disables sync on iCloud, then
//    re-enables on Drive, the Drive blob may be older than what
//    iCloud had. We DO NOT auto-merge across providers — switching
//    is a clean "tear down old → bring up new" operation. The
//    Settings UI explains this; this service treats provider
//    changes as a fresh enable.
// 5. PASSPHRASE LOSS. If the user clears their device or installs
//    on a new device without remembering the passphrase, they
//    cannot decrypt the existing blob. There is no recovery path —
//    by design — so the UI is loud about this. We surface a
//    `SyncPullResult.passphraseMismatch` value that the screen
//    renders as a "Re-enter passphrase?" dialog rather than
//    silently corrupting the user's local DB.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — providers `CloudSyncService` once at the root,
//   wires `syncDown()` to fire after the home screen first builds
//   (best-effort; no UI block on cold start).
// - lib/services/auto_save_service.dart — `AutoSaveController`
//   forwards a "saved" event into `scheduleSyncUp()` so a quiet
//   5s later the cloud blob updates.
// - lib/screens/sync/cloud_sync_screen.dart — full UI for
//   enable/disable/provider/passphrase + Sync Now.
// - lib/screens/home/home_screen.dart — AppBar indicator dot.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads/writes `SharedPreferences` keys
//   `sync_enabled` / `sync_provider` /
//   `sync_last_synced_iso` / `sync_last_remote_iso`.
// - Reads/writes `flutter_secure_storage`
//   `sync_passphrase_<provider>` for the active provider.
// - Calls into `ExportService.exportToJson()` and
//   `ExportService.importFromJson()` against the live `AppDatabase`,
//   so a sync touches every user-data table.
// - Calls one of the three `CloudBackupProvider`s for upload /
//   download / list, which in turn talks to the user's iCloud /
//   Drive / OneDrive endpoint.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/database.dart';
import 'backup_crypto.dart';
import 'cloud_backup.dart';
import 'entitlement_notifier.dart';
import 'export_service.dart';

/// Stable string identifier for each sync provider. Matches the
/// `sync_provider` SharedPreferences value AND the suffix used to
/// scope the per-provider passphrase entry in
/// `flutter_secure_storage`.
class SyncProviderId {
  SyncProviderId._();

  /// iCloud Drive (iOS / macOS only).
  static const String icloud = 'icloud';

  /// Google Drive (cross-platform).
  static const String gdrive = 'gdrive';

  /// Microsoft OneDrive (cross-platform).
  static const String onedrive = 'onedrive';
}

/// Coarse sync activity. Rendered as a dot on the Home AppBar and as
/// a status line on the Cloud Sync screen.
enum SyncStatus {
  /// Disabled, or enabled but currently quiet.
  idle,

  /// `syncUp` is in flight (we're encrypting + uploading).
  syncingUp,

  /// `syncDown` is in flight (we're downloading + merging).
  syncingDown,

  /// Last operation hit a conflict the merge couldn't resolve. Rare;
  /// the user is asked to pick "use mine" or "use remote".
  conflict,

  /// Last operation failed (network, auth, etc.).
  error,
}

/// Result of [CloudSyncService.syncDown]. The merge mechanics need to
/// distinguish "no remote yet" from "decryption failed" from
/// "downloaded N rows" without throwing on every cold-start scenario.
class SyncPullResult {
  const SyncPullResult({
    required this.outcome,
    this.summary,
    this.message,
  });

  factory SyncPullResult.notFound() =>
      const SyncPullResult(outcome: SyncPullOutcome.notFound);
  factory SyncPullResult.passphraseMismatch() => const SyncPullResult(
        outcome: SyncPullOutcome.passphraseMismatch,
        message: 'Could not decrypt the remote blob. The passphrase is '
            'wrong, or the file was modified since it was created.',
      );
  factory SyncPullResult.merged(ImportSummary summary) =>
      SyncPullResult(outcome: SyncPullOutcome.merged, summary: summary);
  factory SyncPullResult.error(String message) =>
      SyncPullResult(outcome: SyncPullOutcome.error, message: message);

  final SyncPullOutcome outcome;
  final ImportSummary? summary;
  final String? message;
}

enum SyncPullOutcome {
  /// No `loadout_sync.encrypted` exists in the active provider yet.
  /// Treated as "this is the first device, nothing to merge."
  notFound,

  /// Decrypted + merged successfully.
  merged,

  /// Wrong passphrase or tampered blob. The local DB is untouched.
  passphraseMismatch,

  /// Network / auth / IO error. The local DB is untouched.
  error,
}

/// Continuous Cloud Sync orchestrator. Provided once at the app root
/// alongside `EntitlementNotifier` and consumed by AutoSave + the
/// Cloud Sync screen.
///
/// All sync operations are short-circuited when [isPro] is false —
/// free users get the existing one-shot backup/restore, not
/// continuous sync.
class CloudSyncService extends ChangeNotifier {
  CloudSyncService({
    required AppDatabase database,
    required EntitlementNotifier entitlements,
    required Map<String, CloudBackupProvider> providers,
    BackupCrypto? crypto,
    FlutterSecureStorage? secureStorage,
    SharedPreferences? sharedPreferences,
  })  : _database = database,
        _entitlements = entitlements,
        _providers = providers,
        _crypto = crypto ?? BackupCrypto(),
        _storage = secureStorage ?? const FlutterSecureStorage(),
        _prefsHandle = sharedPreferences {
    _entitlements.addListener(_onEntitlementChanged);
    // ignore: discarded_futures
    _hydrate();
  }

  // ─────────────── Configuration / dependencies ───────────────

  final AppDatabase _database;
  final EntitlementNotifier _entitlements;
  final Map<String, CloudBackupProvider> _providers;
  final BackupCrypto _crypto;
  final FlutterSecureStorage _storage;
  SharedPreferences? _prefsHandle;

  /// SharedPreferences keys used by this service. Public-ish constants
  /// so tests can clear them in setUp.
  static const String kPrefEnabled = 'sync_enabled';
  static const String kPrefProvider = 'sync_provider';
  static const String kPrefLastSynced = 'sync_last_synced_iso';
  static const String kPrefLastRemote = 'sync_last_remote_iso';

  /// Filename for the canonical sync blob. One blob per user, not
  /// sharded by table. The provider's app folder owns it.
  static const String kSyncBlobFilename = 'loadout_sync.encrypted';

  /// Debounce window between an AutoSave event and the resulting
  /// [syncUp]. Long enough to coalesce a burst of saves; short enough
  /// to feel "near-realtime" on the other device.
  static const Duration kDebounce = Duration(seconds: 5);

  // ─────────────── Persistent state ───────────────

  bool _enabled = false;
  String? _activeProviderId;
  DateTime? _lastSyncedAt;
  DateTime? _lastRemoteUpdateAt;
  bool _hydrated = false;

  /// True iff Cloud Sync is turned on for this install. Persisted in
  /// SharedPreferences under `sync_enabled`.
  bool get isEnabled => _enabled;

  /// Currently active provider id. Persisted under `sync_provider`.
  /// Null when sync is disabled.
  String? get activeProviderId => _activeProviderId;

  /// True once the SharedPreferences read has resolved. Settings UI
  /// can use this to render a placeholder while the bool flips, so
  /// "Sync Off" doesn't flash for users who actually have it on.
  bool get isHydrated => _hydrated;

  /// True iff the current entitlement allows continuous sync. The
  /// service will *refuse to syncUp / syncDown* when this is false,
  /// even if `_enabled` was persisted true (e.g. the user's
  /// subscription expired).
  bool get isPro => _entitlements.isPro;

  /// Wall-clock time of the most recent successful upload. Updated by
  /// [syncUp]. Null until the first successful push.
  ValueListenable<DateTime?> get lastSyncedAt => _lastSyncedAtNotifier;
  final ValueNotifier<DateTime?> _lastSyncedAtNotifier =
      ValueNotifier<DateTime?>(null);

  /// Wall-clock time of the remote blob the last [syncDown] read.
  /// Lets the UI distinguish "we last pushed at 14:23" from "the
  /// remote was last touched at 13:51".
  ValueListenable<DateTime?> get lastRemoteUpdateAt =>
      _lastRemoteUpdateAtNotifier;
  final ValueNotifier<DateTime?> _lastRemoteUpdateAtNotifier =
      ValueNotifier<DateTime?>(null);

  /// Live activity dot. Combine with [isEnabled] to render the
  /// AppBar indicator.
  ValueListenable<SyncStatus> get status => _statusNotifier;
  final ValueNotifier<SyncStatus> _statusNotifier =
      ValueNotifier<SyncStatus>(SyncStatus.idle);

  // ─────────────── Internal flow control ───────────────

  Timer? _debounceTimer;
  bool _busy = false;
  bool _queuedFollowUp = false;

  // ─────────────── Lifecycle ───────────────

  Future<SharedPreferences> _prefs() async {
    return _prefsHandle ??= await SharedPreferences.getInstance();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs();
      _enabled = prefs.getBool(kPrefEnabled) ?? false;
      _activeProviderId = prefs.getString(kPrefProvider);
      final lastSyncedIso = prefs.getString(kPrefLastSynced);
      final lastRemoteIso = prefs.getString(kPrefLastRemote);
      if (lastSyncedIso != null) {
        _lastSyncedAt = DateTime.tryParse(lastSyncedIso);
        _lastSyncedAtNotifier.value = _lastSyncedAt;
      }
      if (lastRemoteIso != null) {
        _lastRemoteUpdateAt = DateTime.tryParse(lastRemoteIso);
        _lastRemoteUpdateAtNotifier.value = _lastRemoteUpdateAt;
      }
    } catch (e) {
      debugPrint('CloudSyncService: hydrate failed: $e');
    } finally {
      _hydrated = true;
      notifyListeners();
    }
  }

  void _onEntitlementChanged() {
    // If a user downgrades from Pro mid-session, we don't reach into
    // their cloud blob — we just stop syncing. The next renew brings
    // them back up.
    if (!_entitlements.isPro && _enabled) {
      _statusNotifier.value = SyncStatus.idle;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _entitlements.removeListener(_onEntitlementChanged);
    _debounceTimer?.cancel();
    _lastSyncedAtNotifier.dispose();
    _lastRemoteUpdateAtNotifier.dispose();
    _statusNotifier.dispose();
    super.dispose();
  }

  // ─────────────── Public API ───────────────

  /// Turn Cloud Sync on. Persists the choice, caches the passphrase
  /// scoped to `providerId`, and runs an initial reconcile so any
  /// pre-existing remote blob merges in immediately.
  ///
  /// [providerId] must be one of [SyncProviderId.icloud],
  /// [SyncProviderId.gdrive], [SyncProviderId.onedrive].
  /// [passphrase] is verified by [BackupCrypto] only at upload /
  /// download time — `enable` itself accepts any non-empty value of
  /// at least [BackupCrypto.minPassphraseLength] characters.
  Future<void> enable({
    required String providerId,
    required String passphrase,
  }) async {
    if (!_providers.containsKey(providerId)) {
      throw ArgumentError.value(providerId, 'providerId',
          'Unknown sync provider. Expected one of ${_providers.keys.toList()}.');
    }
    if (passphrase.length < BackupCrypto.minPassphraseLength) {
      throw ArgumentError.value('<redacted>', 'passphrase',
          'Passphrase must be at least '
          '${BackupCrypto.minPassphraseLength} characters.');
    }
    final prefs = await _prefs();
    await prefs.setBool(kPrefEnabled, true);
    await prefs.setString(kPrefProvider, providerId);
    await _storage.write(
      key: _passphraseKey(providerId),
      value: passphrase,
    );
    _enabled = true;
    _activeProviderId = providerId;
    notifyListeners();

    // Best-effort initial pull — if the user just connected on a
    // second device, we want their existing blob to merge before
    // they touch anything. Failures are surfaced via status only;
    // we never throw out of `enable` for transient cloud errors.
    try {
      await syncDown();
    } catch (e) {
      debugPrint('CloudSyncService.enable: initial syncDown failed: $e');
      _statusNotifier.value = SyncStatus.error;
    }
  }

  /// Turn Cloud Sync off. Clears the persisted bit and the provider
  /// id, plus the cached passphrase for the active provider. The
  /// remote blob is NOT deleted — disabling on this device should not
  /// affect other devices that still rely on it. The user can clear
  /// the remote blob from the manual Backup → Manage screen if they
  /// truly want everything gone.
  Future<void> disable() async {
    final prefs = await _prefs();
    await prefs.setBool(kPrefEnabled, false);
    final wasProvider = _activeProviderId;
    await prefs.remove(kPrefProvider);
    if (wasProvider != null) {
      await _storage.delete(key: _passphraseKey(wasProvider));
    }
    _enabled = false;
    _activeProviderId = null;
    _statusNotifier.value = SyncStatus.idle;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    notifyListeners();
  }

  /// Schedule an upload after [kDebounce] of quiet. Called by
  /// [AutoSaveController._runSave] once a save lands. Safe to call
  /// during the debounce window; the timer simply restarts.
  ///
  /// No-op when sync is disabled, the user isn't Pro, or no provider
  /// is active.
  void scheduleSyncUp() {
    if (!_enabled || !_entitlements.isPro || _activeProviderId == null) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(kDebounce, () {
      // ignore: discarded_futures
      syncUp();
    });
  }

  /// Push the current local DB to the active provider. Called by the
  /// debounced AutoSave handler and by the manual "Sync Now" button.
  ///
  /// `force = true` skips the "already busy" guard and queues no
  /// follow-up — used by [reconcile] to chain a fresh push after a
  /// pull without bouncing through the busy gate.
  Future<void> syncUp({bool force = false}) async {
    if (!_enabled || !_entitlements.isPro || _activeProviderId == null) {
      return;
    }
    if (!force && _busy) {
      // Don't run two pushes in parallel; queue a follow-up so the
      // very latest state still lands once the in-flight one
      // finishes.
      _queuedFollowUp = true;
      return;
    }
    final providerId = _activeProviderId!;
    final provider = _providers[providerId];
    if (provider == null) return;
    final passphrase = await _storage.read(key: _passphraseKey(providerId));
    if (passphrase == null || passphrase.isEmpty) {
      // Should never happen: enable() always writes the passphrase.
      // Treat as "not configured" rather than silently corrupting.
      _statusNotifier.value = SyncStatus.error;
      return;
    }
    _busy = true;
    _statusNotifier.value = SyncStatus.syncingUp;
    try {
      final json = await ExportService(_database).exportToJson();
      final blob = await _crypto.encrypt(passphrase, json);
      await provider.upload(blob, filename: kSyncBlobFilename);
      final now = DateTime.now();
      _lastSyncedAt = now;
      _lastSyncedAtNotifier.value = now;
      final prefs = await _prefs();
      await prefs.setString(kPrefLastSynced, now.toUtc().toIso8601String());
      _statusNotifier.value = SyncStatus.idle;
    } catch (e, stack) {
      _statusNotifier.value = SyncStatus.error;
      if (kDebugMode) {
        debugPrint('CloudSyncService.syncUp: $e');
        debugPrintStack(stackTrace: stack);
      }
    } finally {
      _busy = false;
      if (_queuedFollowUp) {
        _queuedFollowUp = false;
        // ignore: discarded_futures
        syncUp();
      }
    }
  }

  /// Pull the canonical blob and merge into the local DB. Called on
  /// app startup (best-effort) and by the manual sync button.
  ///
  /// Returns a [SyncPullResult] so the UI can distinguish
  /// "first launch, no blob yet" from "wrong passphrase" from "merged
  /// 12 rows."
  Future<SyncPullResult> syncDown() async {
    if (!_enabled || !_entitlements.isPro || _activeProviderId == null) {
      return SyncPullResult.error('Cloud Sync is not enabled.');
    }
    final providerId = _activeProviderId!;
    final provider = _providers[providerId];
    if (provider == null) {
      return SyncPullResult.error('Sync provider unavailable.');
    }
    final passphrase = await _storage.read(key: _passphraseKey(providerId));
    if (passphrase == null || passphrase.isEmpty) {
      return SyncPullResult.error('Sync passphrase missing.');
    }
    _statusNotifier.value = SyncStatus.syncingDown;
    try {
      final all = await provider.list();
      final blob = all.where((m) => m.filename == kSyncBlobFilename).toList();
      if (blob.isEmpty) {
        _statusNotifier.value = SyncStatus.idle;
        return SyncPullResult.notFound();
      }
      final downloaded = await provider.download(blob.first);
      late final String json;
      try {
        json = await _crypto.decrypt(
          passphrase,
          Uint8List.fromList(downloaded),
        );
      } on BackupDecryptException catch (_) {
        _statusNotifier.value = SyncStatus.conflict;
        return SyncPullResult.passphraseMismatch();
      }
      final summary = await _mergeJson(json);
      final remoteWhen = blob.first.modifiedAt;
      if (remoteWhen != null) {
        _lastRemoteUpdateAt = remoteWhen;
        _lastRemoteUpdateAtNotifier.value = remoteWhen;
        final prefs = await _prefs();
        await prefs.setString(
          kPrefLastRemote,
          remoteWhen.toUtc().toIso8601String(),
        );
      }
      _statusNotifier.value = SyncStatus.idle;
      return SyncPullResult.merged(summary);
    } catch (e, stack) {
      _statusNotifier.value = SyncStatus.error;
      if (kDebugMode) {
        debugPrint('CloudSyncService.syncDown: $e');
        debugPrintStack(stackTrace: stack);
      }
      return SyncPullResult.error(e.toString());
    }
  }

  /// Full bidirectional reconciliation — download, merge by
  /// `updatedAt`, then push the merged result. Called by the
  /// manual "Sync Now" button so the act of pressing it leaves
  /// every connected device with the same final state regardless
  /// of which tab raised it.
  Future<SyncPullResult> reconcile() async {
    final pull = await syncDown();
    // Push regardless of pull outcome — even when remote was empty
    // (`notFound`), pushing now establishes the canonical blob for
    // future devices. We `force` past the busy guard because
    // syncDown above already drove status; serializing is fine.
    await syncUp(force: true);
    return pull;
  }

  // ─────────────── Internals ───────────────

  String _passphraseKey(String providerId) => 'sync_passphrase_$providerId';

  /// Decode the inbound JSON, walk every user-data table in
  /// `kUserDataTableOrder`, and apply the remote rows under the
  /// "newest updatedAt wins" rule.
  Future<ImportSummary> _mergeJson(String json) async {
    final Map<String, dynamic> wrapper;
    try {
      wrapper = jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return ImportSummary(fatalError: 'Could not parse remote JSON: $e');
    }
    final exportVersion = wrapper['loadout_export_version'];
    if (exportVersion is! int || exportVersion > kLoadOutExportVersion) {
      return ImportSummary(
        fatalError: 'Remote blob uses a newer export format '
            '($exportVersion). Update LoadOut on this device.',
      );
    }
    final inboundSchema = wrapper['schema_version'];
    if (inboundSchema is int && inboundSchema > _database.schemaVersion) {
      return ImportSummary(
        fatalError: 'Remote blob uses database schema v$inboundSchema, '
            'but this device is on v${_database.schemaVersion}. '
            'Update LoadOut and try again.',
      );
    }
    final tables = wrapper['tables'];
    if (tables is! Map) {
      return ImportSummary(fatalError: 'Remote blob is missing the "tables" map.');
    }

    final summary = <String, ImportTableSummary>{};
    return _database.transaction(() async {
      for (final tableName in kUserDataTableOrder) {
        final raw = tables[tableName];
        if (raw is! List) {
          summary[tableName] = ImportTableSummary(tableName: tableName);
          continue;
        }
        final result = ImportTableSummary(tableName: tableName);
        for (final entry in raw) {
          if (entry is! Map<String, dynamic>) {
            result.errors.add('Row was not a JSON object: $entry');
            continue;
          }
          try {
            final applied = await _applyRow(tableName, entry);
            if (applied) {
              result.added++;
            } else {
              result.skipped++;
            }
          } catch (e) {
            result.errors.add('Row failed: $e');
          }
        }
        summary[tableName] = result;
      }
      return ImportSummary(tables: summary);
    });
  }

  /// Apply one inbound row under the "newest `updatedAt` wins" rule.
  /// Returns true if the row was inserted or replaced; false if a
  /// fresher local row beat it.
  Future<bool> _applyRow(
    String tableName,
    Map<String, dynamic> remote,
  ) async {
    final id = remote['id'];
    if (id is! int) return false;
    final remoteUpdated = _parseTimestamp(remote, 'updated_at') ??
        _parseTimestamp(remote, 'updatedAt') ??
        _parseTimestamp(remote, 'created_at') ??
        _parseTimestamp(remote, 'createdAt');
    final localTimestamp = await _localUpdatedAt(tableName, id);

    // If we already have the row and our copy is at least as fresh,
    // keep ours.
    if (localTimestamp != null && remoteUpdated != null) {
      if (!localTimestamp.isBefore(remoteUpdated)) {
        return false;
      }
    }
    // Otherwise let the remote win — even if both timestamps are
    // null. This preserves the existing manual-restore semantics
    // ("inbound wins on collision when neither side has a clock").
    final exportSvc = ExportService(_database);
    final ok = await exportSvc.importFromJson(
      jsonEncode(<String, dynamic>{
        'loadout_export_version': kLoadOutExportVersion,
        'schema_version': _database.schemaVersion,
        'tables': <String, dynamic>{
          tableName: <Map<String, dynamic>>[remote],
        },
      }),
      mode: ImportMergeMode.overwrite,
    );
    final tableSummary = ok.tables[tableName];
    return (tableSummary?.added ?? 0) > 0;
  }

  DateTime? _parseTimestamp(Map<String, dynamic> row, String key) {
    final raw = row[key];
    if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    if (raw is int) {
      // Drift sometimes serializes DateTime as an int when the column
      // configuration uses Unix timestamps. The runtime today uses
      // ISO-8601 strings everywhere we checked, but accepting ints
      // costs us nothing.
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    }
    return null;
  }

  Future<DateTime?> _localUpdatedAt(String tableName, int id) async {
    // Try `updated_at` first, fall back to `created_at`. Some user
    // tables only have one of the two; the COALESCE keeps the query
    // safe across both shapes.
    try {
      final results = await _database.customSelect(
        // The column lookup is deliberately defensive — `updated_at`
        // may not exist on every user-data table. We rely on SQLite's
        // dynamic typing: if the column doesn't exist, the query
        // throws and we fall through to `created_at`.
        'SELECT updated_at AS ts FROM $tableName WHERE id = ? LIMIT 1',
        variables: [Variable<int>(id)],
      ).get();
      if (results.isNotEmpty) {
        final raw = results.first.data['ts'];
        if (raw is int) {
          return DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
        }
        if (raw is String) return DateTime.tryParse(raw);
      }
    } catch (_) {
      // Fall through to created_at.
    }
    try {
      final results = await _database.customSelect(
        'SELECT created_at AS ts FROM $tableName WHERE id = ? LIMIT 1',
        variables: [Variable<int>(id)],
      ).get();
      if (results.isNotEmpty) {
        final raw = results.first.data['ts'];
        if (raw is int) {
          return DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
        }
        if (raw is String) return DateTime.tryParse(raw);
      }
    } catch (_) {
      // No timestamp column on this table — fall through.
    }
    return null;
  }
}
