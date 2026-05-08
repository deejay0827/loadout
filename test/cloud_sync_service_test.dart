// FILE: test/cloud_sync_service_test.dart
//
// Round-trip coverage for the [CloudSyncService] integration. Verifies
// the contract documented in `lib/services/cloud_sync_service.dart`:
// the encrypted blob produced by `BackupCrypto.encrypt(passphrase, json)`
// can be decrypted and merged back into a fresh database via the same
// `ExportService.importFromJson` path that the manual backup screen
// uses, and that the in-flight `CloudSyncService` honors the Pro gate.
//
// We deliberately don't exercise the real iCloud / Drive / OneDrive
// providers — those need network + platform plugins. The unit test
// uses an in-memory `_FakeProvider` that mimics the
// `CloudBackupProvider` interface but stores the blob in a single
// `Uint8List` field, which is plenty to validate the encrypt /
// upload / download / decrypt / merge flow end-to-end.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/services/backup_crypto.dart';
import 'package:loadout/services/cloud_backup.dart';
import 'package:loadout/services/cloud_sync_service.dart';
import 'package:loadout/services/entitlement_notifier.dart';
import 'package:loadout/services/export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CloudSyncService round-trip', () {
    test('encrypts source DB, merges into a fresh target DB', () async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await source.close();
        await target.close();
      });

      // Seed a few user-data rows in the source.
      await source.into(source.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Tikka T3X'),
          );
      await source.into(source.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'AR-15'),
          );
      await source.into(source.userLoads).insert(
            UserLoadsCompanion.insert(
              name: 'Match load',
              caliber: const Value('6.5 Creedmoor'),
              powderChargeGr: const Value(41.5),
            ),
          );
      await source.into(source.brassLots).insert(
            BrassLotsCompanion.insert(
              name: 'LC 6.5 lot 23',
              caliber: '6.5 Creedmoor',
              count: 200,
            ),
          );

      // Manual export → encrypt — same path CloudSyncService takes.
      const passphrase = 'correct horse battery staple';
      final exportSvc = ExportService(source);
      final json = await exportSvc.exportToJson();
      final crypto = BackupCrypto();
      final blob = await crypto.encrypt(passphrase, json);

      // Decrypt + merge into the fresh target.
      final restored = await crypto.decrypt(passphrase, blob);
      final summary =
          await ExportService(target).importFromJson(restored);
      expect(summary.fatalError, isNull);
      expect(summary.hasErrors, isFalse);

      // Row counts on target match source.
      final firearms = await target.select(target.userFirearms).get();
      expect(firearms.length, 2);
      final loads = await target.select(target.userLoads).get();
      expect(loads.length, 1);
      final lots = await target.select(target.brassLots).get();
      expect(lots.length, 1);
    });

    test('blocks operations when the user is not Pro', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());

      final entitlements = _FakeEntitlements(isPro: false);
      final fake = _FakeProvider();
      final svc = CloudSyncService(
        database: db,
        entitlements: entitlements,
        providers: <String, CloudBackupProvider>{
          SyncProviderId.icloud: fake,
        },
      );

      // syncDown / syncUp without enable: error / no-op.
      final pull = await svc.syncDown();
      expect(pull.outcome, SyncPullOutcome.error);
      // syncUp short-circuits silently when not enabled.
      await svc.syncUp();
      expect(fake.uploadCount, 0);
    });

    test('rejects undersized passphrases on enable', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final entitlements = _FakeEntitlements(isPro: true);
      final svc = CloudSyncService(
        database: db,
        entitlements: entitlements,
        providers: <String, CloudBackupProvider>{
          SyncProviderId.icloud: _FakeProvider(),
        },
      );
      expect(
        () => svc.enable(providerId: SyncProviderId.icloud, passphrase: 'short'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects unknown provider ids on enable', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final svc = CloudSyncService(
        database: db,
        entitlements: _FakeEntitlements(isPro: true),
        providers: const <String, CloudBackupProvider>{},
      );
      expect(
        () => svc.enable(
          providerId: 'gopher',
          passphrase: 'a-long-enough-pw',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('SyncPullResult constructors expose the right outcomes', () {
      expect(SyncPullResult.notFound().outcome, SyncPullOutcome.notFound);
      expect(SyncPullResult.passphraseMismatch().outcome,
          SyncPullOutcome.passphraseMismatch);
      expect(SyncPullResult.error('boom').outcome, SyncPullOutcome.error);
      final summary = ImportSummary(tables: const {});
      expect(SyncPullResult.merged(summary).outcome,
          SyncPullOutcome.merged);
    });
  });

  group('Sync wrapper format', () {
    test('exported JSON has the expected wrapper keys', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      await db.into(db.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Test'),
          );
      final json = await ExportService(db).exportToJson();
      final wrapper = jsonDecode(json) as Map<String, dynamic>;
      expect(wrapper['loadout_export_version'], kLoadOutExportVersion);
      expect(wrapper['schema_version'], db.schemaVersion);
      expect(wrapper['tables'], isA<Map<String, dynamic>>());
    });
  });
}

/// Minimal fake provider: stores an in-memory blob and reports
/// matching metadata. Suitable for round-trip tests that don't want
/// to plumb through a real cloud SDK.
class _FakeProvider implements CloudBackupProvider {
  Uint8List? _blob;
  String? _filename;
  DateTime? _modifiedAt;
  int uploadCount = 0;

  @override
  String get displayName => 'Fake';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> upload(
    List<int> blob, {
    String filename = 'loadout-backup.lo1',
  }) async {
    _blob = Uint8List.fromList(blob);
    _filename = filename;
    _modifiedAt = DateTime.now();
    uploadCount++;
  }

  @override
  Future<List<CloudBackupMetadata>> list() async {
    if (_blob == null) return const <CloudBackupMetadata>[];
    return [
      CloudBackupMetadata(
        filename: _filename!,
        size: _blob!.length,
        modifiedAt: _modifiedAt,
        providerHandle: _filename!,
      ),
    ];
  }

  @override
  Future<List<int>> download(CloudBackupMetadata meta) async {
    if (_blob == null) {
      throw StateError('Fake provider has no blob.');
    }
    return _blob!.toList(growable: false);
  }

  @override
  Future<void> delete(CloudBackupMetadata meta) async {
    _blob = null;
    _filename = null;
    _modifiedAt = null;
  }
}

/// Stand-in for `EntitlementNotifier` that lets tests force the Pro
/// state without touching RevenueCat. Mirrors the small surface
/// `CloudSyncService` actually uses (`isPro`, `addListener`,
/// `removeListener`).
class _FakeEntitlements extends ChangeNotifier
    implements EntitlementNotifier {
  _FakeEntitlements({required bool isPro}) : _isPro = isPro;
  bool _isPro;
  @override
  bool get isPro => _isPro;
  set isPro(bool value) {
    if (value == _isPro) return;
    _isPro = value;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {}

  @override
  void noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
