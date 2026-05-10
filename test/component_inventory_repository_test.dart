// FILE: test/component_inventory_repository_test.dart
//
// Unit tests for `lib/repositories/component_inventory_repository.dart`.
// Mirrors the in-memory drift pattern used by
// `atmosphere_preset_repository_test.dart` and the rest of the
// repository tests. Verifies CRUD round-trips, the audit-log
// transactional contract, and the watch-stream ordering.
//
// The tests are deliberately exhaustive on the audit log: any
// regression that lets the master `quantity` and the
// `ComponentInventoryAdjustments` ledger drift apart breaks the
// "where did 60 grains of Varget go?" answerability that justifies
// the second table existing at all.
//
// Schema check: the suite also walks `wipeUserData()` to make sure
// the v31 migration's tables get cleaned up alongside the rest.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/repositories/component_inventory_repository.dart';

void main() {
  group('ComponentInventoryRepository', () {
    late AppDatabase db;
    late ComponentInventoryRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = ComponentInventoryRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('empty-state initial query yields no rows', () async {
      final all = await repo.getAll();
      expect(all, isEmpty);
      final firstWatch = await repo.watchAll().first;
      expect(firstWatch, isEmpty);
    });

    test('insert + readback persists every column and derives unit',
        () async {
      // Powder row — explicit unit absent, repo should derive "gr".
      final powderId = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon H4350',
          quantity: 1462.4,
          unit: '',
          referenceId: const Value(42),
          unitCostUsd: const Value(45.99),
          reorderThreshold: const Value(500),
          lotNumber: const Value('LOT2026-A'),
          openedAt: Value(DateTime(2026, 5, 1)),
          notes: const Value('Sale at Brownells'),
        ),
      );
      expect(powderId, greaterThan(0));
      final powder = await repo.getById(powderId);
      expect(powder, isNotNull);
      expect(powder!.kind, kInventoryKindPowder);
      expect(powder.componentName, 'Hodgdon H4350');
      expect(powder.quantity, closeTo(1462.4, 1e-6));
      expect(powder.unit, 'gr', reason: 'derived from kind');
      expect(powder.referenceId, 42);
      expect(powder.unitCostUsd, closeTo(45.99, 1e-6));
      expect(powder.reorderThreshold, closeTo(500, 1e-6));
      expect(powder.lotNumber, 'LOT2026-A');
      expect(powder.openedAt, DateTime(2026, 5, 1));
      expect(powder.notes, 'Sale at Brownells');
      expect(powder.createdAt, isNotNull);
      expect(powder.updatedAt, isNotNull);

      // Primer row — derived unit "ct".
      final primerId = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPrimer,
          componentName: 'Federal #210M',
          quantity: 1500,
          unit: '',
        ),
      );
      final primer = await repo.getById(primerId);
      expect(primer!.unit, 'ct');

      // Cartridge row — derived unit "rd".
      final cartId = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindCartridge,
          componentName: 'Hornady 6.5 Creedmoor 140gr ELD-Match',
          quantity: 200,
          unit: '',
        ),
      );
      final cart = await repo.getById(cartId);
      expect(cart!.unit, 'rd');
    });

    test('explicit unit overrides derived value', () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Override test',
          quantity: 100,
          unit: 'lb',
        ),
      );
      final row = await repo.getById(id);
      expect(row!.unit, 'lb');
    });

    test('watchAll orders by kind then natural component name',
        () async {
      // Insert in scrambled order across multiple kinds.
      await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindBullet,
        componentName: 'Berger 109gr',
        quantity: 100,
        unit: '',
      ));
      await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPrimer,
        componentName: 'Federal #210M',
        quantity: 1000,
        unit: '',
      ));
      await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPowder,
        componentName: 'Hodgdon H4350',
        quantity: 500,
        unit: '',
      ));
      await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPowder,
        componentName: 'Alliant Reloder 16',
        quantity: 600,
        unit: '',
      ));
      await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindCartridge,
        componentName: 'Hornady 140gr',
        quantity: 50,
        unit: '',
      ));

      final rows = await repo.watchAll().first;
      expect(
        rows.map((r) => '${r.kind}:${r.componentName}').toList(),
        const [
          // Powder (kind 0) — alphabetical within the kind.
          'powder:Alliant Reloder 16',
          'powder:Hodgdon H4350',
          // Primer (kind 1).
          'primer:Federal #210M',
          // Bullet (kind 2).
          'bullet:Berger 109gr',
          // Brass (kind 3) — none.
          // Cartridge (kind 4).
          'cartridge:Hornady 140gr',
        ],
      );
    });

    test('update writes new values and bumps updatedAt', () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon Varget',
          quantity: 1000,
          unit: '',
        ),
      );
      final originalUpdatedAt = (await repo.getById(id))!.updatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final ok = await repo.update(
        id,
        ComponentInventoryCompanion(
          quantity: const Value(1462.4),
          notes: const Value('Topped up'),
          openedAt: Value(DateTime(2026, 1, 5)),
        ),
      );
      expect(ok, isTrue);
      final row = await repo.getById(id);
      expect(row, isNotNull);
      expect(row!.quantity, closeTo(1462.4, 1e-6));
      expect(row.notes, 'Topped up');
      expect(row.openedAt, DateTime(2026, 1, 5));
      expect(row.updatedAt.isAfter(originalUpdatedAt), isTrue);
      // Untouched columns persist.
      expect(row.kind, kInventoryKindPowder);
      expect(row.componentName, 'Hodgdon Varget');
    });

    test('update of unknown id returns false', () async {
      final ok = await repo.update(
        99999,
        ComponentInventoryCompanion(quantity: const Value(0)),
      );
      expect(ok, isFalse);
    });

    test('delete cascades through the adjustments ledger', () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPrimer,
          componentName: 'Federal #210M',
          quantity: 1000,
          unit: '',
        ),
      );
      // Two adjustments recorded.
      await repo.adjust(id,
          delta: -100, reason: kAdjustReasonManual, notes: 'Range trip');
      await repo.adjust(id,
          delta: 500, reason: kAdjustReasonManual, notes: 'Sale buy');
      expect((await repo.getAdjustments(id)).length, 2);

      final removed = await repo.delete(id);
      expect(removed, 1);
      expect(await repo.getById(id), isNull);
      expect(await repo.getAdjustments(id), isEmpty);
    });

    test(
      'adjust updates the master quantity AND writes a ledger row '
      'inside one transaction',
      () async {
        final id = await repo.insert(
          ComponentInventoryCompanion.insert(
            kind: kInventoryKindPowder,
            componentName: 'Hodgdon Varget',
            quantity: 1000,
            unit: '',
          ),
        );

        // Negative delta — consume.
        final after = await repo.adjust(
          id,
          delta: -42.5,
          reason: kAdjustReasonManual,
          notes: 'Test session',
        );
        expect(after, closeTo(957.5, 1e-6));

        final masterAfter = await repo.getById(id);
        expect(masterAfter!.quantity, closeTo(957.5, 1e-6));

        final ledger = await repo.getAdjustments(id);
        expect(ledger.length, 1);
        expect(ledger.first.delta, closeTo(-42.5, 1e-6));
        expect(ledger.first.reason, kAdjustReasonManual);
        expect(ledger.first.notes, 'Test session');

        // Sleep to push the second adjust into a strictly later
        // second so the createdAt-desc order is deterministic on
        // SQLite's second-precision DateTime columns.
        await Future<void>.delayed(const Duration(milliseconds: 1100));

        // Positive delta — replenish.
        await repo.adjust(
          id,
          delta: 100,
          reason: kAdjustReasonManual,
        );
        final masterAfterReplenish = await repo.getById(id);
        expect(masterAfterReplenish!.quantity, closeTo(1057.5, 1e-6));

        final ledger2 = await repo.getAdjustments(id);
        expect(ledger2.length, 2);
        // Newest first.
        expect(ledger2.first.delta, closeTo(100, 1e-6));
        expect(ledger2.last.delta, closeTo(-42.5, 1e-6));
      },
    );

    test('adjust clamps master quantity at zero but ledger keeps truth',
        () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPrimer,
          componentName: 'Federal #210M',
          quantity: 30,
          unit: '',
        ),
      );
      final after = await repo.adjust(
        id,
        delta: -50,
        reason: kAdjustReasonManual,
      );
      // Clamped at 0 on the master row.
      expect(after, 0);
      final master = await repo.getById(id);
      expect(master!.quantity, 0);
      // But the ledger records the true -50 delta.
      final ledger = await repo.getAdjustments(id);
      expect(ledger.length, 1);
      expect(ledger.first.delta, closeTo(-50, 1e-6));
    });

    test('adjust on unknown id returns null and writes nothing', () async {
      final result = await repo.adjust(
        424242,
        delta: -10,
        reason: kAdjustReasonManual,
      );
      expect(result, isNull);
      // Confirm no adjustment row leaked through.
      final rows =
          await db.select(db.componentInventoryAdjustments).get();
      expect(rows, isEmpty);
    });

    test('setQuantity records delta and resets master', () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon Varget',
          quantity: 957.5,
          unit: '',
        ),
      );
      final after = await repo.setQuantity(
        id,
        newQuantity: 800,
        notes: 'Recount after spill',
      );
      expect(after, closeTo(800, 1e-6));
      final ledger = await repo.getAdjustments(id);
      expect(ledger.length, 1);
      // delta = 800 - 957.5 = -157.5
      expect(ledger.first.delta, closeTo(-157.5, 1e-6));
      expect(ledger.first.reason, kAdjustReasonAdjustment);
      expect(ledger.first.notes, 'Recount after spill');
    });

    test('setQuantity rejects negatives and clamps to zero', () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon Varget',
          quantity: 100,
          unit: '',
        ),
      );
      final after = await repo.setQuantity(id, newQuantity: -50);
      expect(after, 0);
      final master = await repo.getById(id);
      expect(master!.quantity, 0);
    });

    test('watchAdjustments emits live updates ordered newest-first',
        () async {
      final id = await repo.insert(
        ComponentInventoryCompanion.insert(
          kind: kInventoryKindBullet,
          componentName: 'Berger 109gr',
          quantity: 200,
          unit: '',
        ),
      );
      // Recorded in order; expect newest-first on read.
      await repo.adjust(id, delta: -10, reason: kAdjustReasonManual);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await repo.adjust(id, delta: -20, reason: kAdjustReasonManual);
      final emission = await repo.watchAdjustments(id).first;
      expect(emission.length, 2);
      expect(emission.first.delta, closeTo(-20, 1e-6),
          reason: 'newest first');
      expect(emission.last.delta, closeTo(-10, 1e-6));
    });

    test('findByName matches case-insensitively and trims whitespace',
        () async {
      await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPowder,
        componentName: 'Hodgdon Varget',
        quantity: 500,
        unit: '',
      ));
      final hit = await repo.findByName(
        kind: kInventoryKindPowder,
        componentName: '  hodgdon varget  ',
      );
      expect(hit, isNotNull);
      expect(hit!.componentName, 'Hodgdon Varget');
      // Wrong kind returns null.
      final miss = await repo.findByName(
        kind: kInventoryKindPrimer,
        componentName: 'Hodgdon Varget',
      );
      expect(miss, isNull);
    });

    test(
      'findByName picks the most-recently-opened container when '
      'multiple rows match',
      () async {
        final older = await repo.insert(ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon H4350',
          quantity: 800,
          unit: '',
          openedAt: Value(DateTime(2025, 1, 1)),
        ));
        final newer = await repo.insert(ComponentInventoryCompanion.insert(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon H4350',
          quantity: 1000,
          unit: '',
          openedAt: Value(DateTime(2026, 4, 1)),
        ));
        final hit = await repo.findByName(
          kind: kInventoryKindPowder,
          componentName: 'Hodgdon H4350',
        );
        expect(hit, isNotNull);
        expect(hit!.id, newer);
        expect(hit.id, isNot(older));
      },
    );

    test('deductForBatch deducts powder grains × rounds and writes ledger',
        () async {
      // Set up inventory: powder + primer + bullet matching the
      // recipe component names. No brass row — fresh-brass flag is
      // off, so brass should be skipped regardless.
      final powderId = await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPowder,
        componentName: 'Hodgdon H4350',
        quantity: 1000,
        unit: '',
      ));
      final primerId = await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPrimer,
        componentName: 'Federal #210M',
        quantity: 1500,
        unit: '',
      ));
      final bulletId = await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindBullet,
        componentName: 'Berger 140gr',
        quantity: 200,
        unit: '',
      ));

      // Build a recipe (UserLoad) and a batch that consumed 50 rounds.
      final recipeId = await db.into(db.userLoads).insert(
            UserLoadsCompanion.insert(
              name: 'Test load',
              caliber: const Value('6.5 Creedmoor'),
              powder: const Value('Hodgdon H4350'),
              powderChargeGr: const Value(41.5),
              bullet: const Value('Berger 140gr'),
              primer: const Value('Federal #210M'),
            ),
          );
      final batchId = await db.into(db.batches).insert(
            BatchesCompanion.insert(
              name: 'Match prep',
              recipeId: Value(recipeId),
              count: 100,
              firedCount: const Value(50),
            ),
          );
      final recipe =
          await (db.select(db.userLoads)..where((u) => u.id.equals(recipeId)))
              .getSingle();
      final batch =
          await (db.select(db.batches)..where((b) => b.id.equals(batchId)))
              .getSingle();

      final result = await repo.deductForBatch(batch, recipe: recipe);
      expect(result.deducted, 3, reason: 'powder + primer + bullet');
      expect(result.skipped, 0);
      expect(result.anyDeducted, isTrue);
      expect(result.anySkipped, isFalse);

      final powder = await repo.getById(powderId);
      // 1000 - (41.5 * 50) = 1000 - 2075 → clamped to 0.
      expect(powder!.quantity, 0);
      final primer = await repo.getById(primerId);
      expect(primer!.quantity, closeTo(1450, 1e-6));
      final bullet = await repo.getById(bulletId);
      expect(bullet!.quantity, closeTo(150, 1e-6));

      // Each deduction writes a ledger row tagged 'batch' with the
      // batch id.
      final powderLedger = await repo.getAdjustments(powderId);
      expect(powderLedger.length, 1);
      expect(powderLedger.first.reason, kAdjustReasonBatch);
      expect(powderLedger.first.batchLogId, batchId);
    });

    test('deductForBatch is best-effort when inventory rows are missing',
        () async {
      // Only powder is tracked; primer and bullet inventory don't
      // exist. The deduct call must not throw — it should record
      // the powder deduction and report the others as skipped.
      final powderId = await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPowder,
        componentName: 'Hodgdon H4350',
        quantity: 1000,
        unit: '',
      ));
      final recipeId = await db.into(db.userLoads).insert(
            UserLoadsCompanion.insert(
              name: 'Untracked',
              powder: const Value('Hodgdon H4350'),
              powderChargeGr: const Value(40),
              bullet: const Value('Untracked Bullet'),
              primer: const Value('Untracked Primer'),
            ),
          );
      final batchId = await db.into(db.batches).insert(
            BatchesCompanion.insert(
              name: 'X',
              recipeId: Value(recipeId),
              count: 10,
              firedCount: const Value(10),
            ),
          );
      final recipe =
          await (db.select(db.userLoads)..where((u) => u.id.equals(recipeId)))
              .getSingle();
      final batch =
          await (db.select(db.batches)..where((b) => b.id.equals(batchId)))
              .getSingle();

      final result = await repo.deductForBatch(batch, recipe: recipe);
      expect(result.deducted, 1);
      expect(result.skipped, 2,
          reason: 'primer + bullet not tracked → skipped');

      final powder = await repo.getById(powderId);
      expect(powder!.quantity, closeTo(600, 1e-6));
    });

    test('deductForBatch with freshBrass=true also deducts brass',
        () async {
      final brassId = await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindBrass,
        componentName: 'Lapua',
        quantity: 200,
        unit: '',
      ));
      final recipeId = await db.into(db.userLoads).insert(
            UserLoadsCompanion.insert(
              name: 'Brass deduct',
              brass: const Value('Lapua'),
            ),
          );
      final batchId = await db.into(db.batches).insert(
            BatchesCompanion.insert(
              name: 'X',
              recipeId: Value(recipeId),
              count: 50,
              firedCount: const Value(50),
            ),
          );
      final recipe =
          await (db.select(db.userLoads)..where((u) => u.id.equals(recipeId)))
              .getSingle();
      final batch =
          await (db.select(db.batches)..where((b) => b.id.equals(batchId)))
              .getSingle();

      // Default freshBrass=false → brass not deducted.
      final r1 = await repo.deductForBatch(batch, recipe: recipe);
      expect(r1.deducted, 0);
      var brass = await repo.getById(brassId);
      expect(brass!.quantity, 200);

      // freshBrass=true → brass deducted by `firedCount`.
      final r2 = await repo.deductForBatch(
        batch,
        recipe: recipe,
        freshBrass: true,
      );
      expect(r2.deducted, 1);
      brass = await repo.getById(brassId);
      expect(brass!.quantity, closeTo(150, 1e-6));
    });

    test('unitForKind matches the documented mapping', () {
      expect(unitForKind(kInventoryKindPowder), 'gr');
      expect(unitForKind(kInventoryKindPrimer), 'ct');
      expect(unitForKind(kInventoryKindBullet), 'ct');
      expect(unitForKind(kInventoryKindBrass), 'ct');
      expect(unitForKind(kInventoryKindCartridge), 'rd');
      expect(unitForKind('mystery'), 'ct',
          reason: 'unknown kind falls back to count');
    });
  });

  group('AppDatabase.wipeUserData() with component inventory', () {
    test('wipes both inventory tables, preserves the empty state',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final repo = ComponentInventoryRepository(db);
      final id = await repo.insert(ComponentInventoryCompanion.insert(
        kind: kInventoryKindPowder,
        componentName: 'To be wiped',
        quantity: 100,
        unit: '',
      ));
      await repo.adjust(id, delta: -10, reason: kAdjustReasonManual);
      expect((await repo.getAll()).length, 1);
      expect((await repo.getAdjustments(id)).length, 1);

      await db.wipeUserData();

      expect((await repo.getAll()).length, 0);
      // Adjustments are scrubbed too — the FK cascade in delete /
      // wipeUserData drops them in order.
      final allAdjustments =
          await db.select(db.componentInventoryAdjustments).get();
      expect(allAdjustments, isEmpty);
    });
  });
}
