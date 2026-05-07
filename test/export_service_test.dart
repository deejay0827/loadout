import 'dart:convert';

import 'package:drift/drift.dart' show TableInfo, Table, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/services/backup_crypto.dart';
import 'package:loadout/services/export_service.dart';

void main() {
  group('ExportService round-trip', () {
    late AppDatabase source;
    late AppDatabase target;

    setUp(() {
      source = AppDatabase.forTesting(NativeDatabase.memory());
      target = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await source.close();
      await target.close();
    });

    test('exports user-data tables and re-imports into a fresh DB', () async {
      // Seed source DB with one row of every user-mutable table.
      await source.into(source.customComponents).insert(
            CustomComponentsCompanion.insert(
              kind: 'powder',
              name: 'Test Powder',
              notes: const Value('cool'),
            ),
          );
      final powderLotId = await source.into(source.powderLots).insert(
            PowderLotsCompanion.insert(name: 'Varget'),
          );
      await source.into(source.brassLots).insert(
            BrassLotsCompanion.insert(
              name: 'Lot A',
              caliber: '6.5 Creedmoor',
              count: 100,
            ),
          );
      final firearmId = await source.into(source.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Tikka T3X'),
          );
      final loadId = await source.into(source.userLoads).insert(
            UserLoadsCompanion.insert(
              name: 'Match load',
              caliber: const Value('6.5 Creedmoor'),
              powderChargeGr: const Value(41.5),
              powderLotId: Value(powderLotId),
            ),
          );
      await source.into(source.testSessions).insert(
            TestSessionsCompanion.insert(
              sessionDate: DateTime(2026, 5, 1),
              recipeId: Value(loadId),
              firearmId: Value(firearmId),
              velocityAvgFps: const Value(2820),
            ),
          );

      // Export.
      final svc = ExportService(source);
      final json = await svc.exportToJson();
      final wrapper = jsonDecode(json) as Map<String, dynamic>;
      expect(wrapper['loadout_export_version'], kLoadOutExportVersion);
      expect(wrapper['schema_version'], source.schemaVersion);
      final tables = wrapper['tables'] as Map<String, dynamic>;
      expect((tables['user_loads'] as List).length, 1);
      expect((tables['user_firearms'] as List).length, 1);
      expect((tables['custom_components'] as List).length, 1);
      expect((tables['powder_lots'] as List).length, 1);
      expect((tables['brass_lots'] as List).length, 1);
      expect((tables['test_sessions'] as List).length, 1);

      // Import into a fresh DB.
      final targetSvc = ExportService(target);
      final summary = await targetSvc.importFromJson(json);
      expect(summary.fatalError, isNull);
      expect(summary.totalAdded, greaterThanOrEqualTo(6));
      expect(summary.hasErrors, isFalse);

      // Verify row counts on the target match the source for the touched
      // tables.
      Future<int> count(TableInfo<Table, dynamic> t) async {
        final c = await target
            .customSelect('SELECT COUNT(*) AS n FROM ${t.actualTableName}')
            .getSingle();
        return c.read<int>('n');
      }

      expect(await count(target.userLoads), 1);
      expect(await count(target.userFirearms), 1);
      expect(await count(target.customComponents), 1);
      expect(await count(target.powderLots), 1);
      expect(await count(target.brassLots), 1);
      expect(await count(target.testSessions), 1);
    });

    test('skipDuplicates leaves existing rows intact', () async {
      await target.into(target.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Existing rifle'),
          );
      // The existing row has id=1 — same as the inbound row will.
      await source.into(source.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Inbound rifle'),
          );

      final json = await ExportService(source).exportToJson();
      final summary = await ExportService(target).importFromJson(json);
      expect(summary.fatalError, isNull);
      // user_firearms had 1 inbound row, all skipped under default policy.
      expect(summary.tables['user_firearms']!.skipped, 1);
      expect(summary.tables['user_firearms']!.added, 0);

      final rows = await target.select(target.userFirearms).get();
      expect(rows.length, 1);
      expect(rows.first.name, 'Existing rifle');
    });

    test('overwrite mode replaces existing rows', () async {
      await target.into(target.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Existing rifle'),
          );
      await source.into(source.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'Inbound rifle'),
          );

      final json = await ExportService(source).exportToJson();
      final summary = await ExportService(target).importFromJson(
        json,
        mode: ImportMergeMode.overwrite,
      );
      expect(summary.fatalError, isNull);
      expect(summary.tables['user_firearms']!.added, 1);
      expect(summary.tables['user_firearms']!.skipped, 0);

      final rows = await target.select(target.userFirearms).get();
      expect(rows.length, 1);
      expect(rows.first.name, 'Inbound rifle');
    });

    test('rejects payloads with future export version', () async {
      final futurePayload = jsonEncode({
        'loadout_export_version': kLoadOutExportVersion + 1,
        'schema_version': 4,
        'tables': <String, dynamic>{},
      });
      final summary =
          await ExportService(target).importFromJson(futurePayload);
      expect(summary.fatalError, isNotNull);
      expect(summary.fatalError, contains('newer version'));
    });
  });

  group('BackupCrypto', () {
    test('round-trips a payload through encrypt/decrypt', () async {
      final crypto = BackupCrypto();
      const passphrase = 'correct horse battery staple';
      const payload = '{"hello":"world","nested":{"a":1,"b":[1,2,3]}}';
      final blob = await crypto.encrypt(passphrase, payload);
      final restored = await crypto.decrypt(passphrase, blob);
      expect(restored, payload);
    });

    test('rejects wrong passphrase', () async {
      final crypto = BackupCrypto();
      final blob = await crypto.encrypt('hunter2hunter2', 'data');
      expect(
        () => crypto.decrypt('wrong-pass', blob),
        throwsA(isA<BackupDecryptException>()),
      );
    });

    test('rejects passphrases shorter than the minimum', () async {
      final crypto = BackupCrypto();
      expect(
        () => crypto.encrypt('short', 'x'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('detects tampered ciphertext', () async {
      final crypto = BackupCrypto();
      const passphrase = 'correct horse battery staple';
      final blob = await crypto.encrypt(passphrase, 'data goes here');
      // Flip a byte deep inside the ciphertext.
      blob[blob.length - 1] ^= 0x42;
      expect(
        () => crypto.decrypt(passphrase, blob),
        throwsA(isA<BackupDecryptException>()),
      );
    });

    test('produces different blobs on repeated encrypt calls', () async {
      final crypto = BackupCrypto();
      const passphrase = 'correct horse battery staple';
      final a = await crypto.encrypt(passphrase, 'same payload');
      final b = await crypto.encrypt(passphrase, 'same payload');
      expect(a, isNot(equals(b)));
    });
  });
}
