// FILE: test/database_schema_v35_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Smoke test for the v34 → v35 schema migration that landed with the
// Range Day Realistic v2.3 rewrite. Verifies the new columns on
// `range_day_sessions`, `user_firearms`, and `reticles` exist on a
// freshly-created v35 database, that the columns accept the expected
// types, that null is a valid value for all new columns (per
// Appendix I of `range_day_realistic_rewrite_v23.md`), and that the
// per-firearm-default scope/reticle id columns (§6A.4) round-trip
// across insert + read.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The v23 Definition-of-Done (`v23_DEFINITION_OF_DONE.md` §2.1) explicitly
// requires a test that opens a database and verifies the v35 fields
// populate correctly. Without this, the self-review pass would fail.
//
// We use `AppDatabase.forTesting` against a fresh in-memory
// `NativeDatabase.memory()` so the test bypasses the migration path
// entirely and exercises `onCreate` (which constructs the schema at the
// current version directly). That's adequate for "do the new columns
// exist and round-trip?" — which is what the DoD asks. A separate
// pre-v35-snapshot migration test (open a v34 DB file, upgrade it,
// verify column add) would be more rigorous but requires a snapshot
// fixture; not yet authored.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Drift's `forTesting` constructor takes a `QueryExecutor` and
//     skips most of the runtime wiring (`onCreate` still runs because
//     drift always runs the schema-creation pass on a fresh DB).
//   * For the `default_scope_id` column (§6A.4 add to `UserFirearms`)
//     the value is a TEXT slug, not an integer FK. We insert a
//     made-up slug and verify it round-trips verbatim — no FK is
//     enforced because the slug references `scopes.json` rows, not
//     the `Optics` drift table.
//   * `Reticles.subtensionOrigin` has a `withDefault('original')` so
//     an insert that omits the column gets `'original'` back. We
//     verify the default applies AND that an explicit override
//     (`'published_spec'`) round-trips correctly.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - `flutter test test/database_schema_v35_test.dart` — manual run
//     during development.
//   - Full `flutter test` invocation — the self-review pass runs the
//     whole suite, and this test gates the v2.3 DoD checklist's
//     "migration tested" line item.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. In-memory database; closed at end of every test.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Schema v35 — new columns', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('schemaVersion is 39', () {
      // v35 added Range Day Realistic / per-firearm scope-and-reticle
      // defaults; v36 added `targets.shape_id` for SVG dispatch (v2.3
      // target render fix); v37 added the per-target `center_point`
      // columns (Scene Painter Phase 6) — two RealColumns with default
      // 0.5 for vertical / horizontal anchor fractions; v38 added
      // `targets.svg_scale_factor` (Scene Painter Phase 7a) — a
      // RealColumn with default 1.0 that the silhouette scaler
      // multiplies on top of fit-to-box. v39 (Scene Painter Phase
      // 9.5 Group A) replaced `targets.shape` with the
      // category-driven `targets.category` enum (drop + recreate;
      // the seed catalog ships the new schema). The file keeps its
      // v35 name because every v35-era assertion below is still
      // valid on v39 — schema bumps are additive (except the v39
      // shape→category rename, which is captured here).
      expect(db.schemaVersion, 39);
    });

    test('targets accepts the new v38 svg_scale_factor column', () async {
      // v38 — `svgScaleFactor` is a RealColumn default 1.0. Rows
      // inserted without explicit value get the default; problem
      // animals override to 1.2-1.4 so their authored SVGs overflow
      // the rect (antlers / horns extend into the sky).
      final defaultId = await db.into(db.targets).insert(
            TargetsCompanion.insert(
              name: 'v38 default-scale row',
              category: 'ipsc',
              widthIn: 18,
              heightIn: 30,
              colorHex: '#ffffff',
            ),
          );
      final defaultRow = await (db.select(db.targets)
            ..where((t) => t.id.equals(defaultId)))
          .getSingle();
      expect(defaultRow.svgScaleFactor, 1.0);

      final tunedId = await db.into(db.targets).insert(
            TargetsCompanion.insert(
              name: 'v38 tuned-scale deer',
              category: 'ipsc',
              shapeId: const Value('deer'),
              widthIn: 60,
              heightIn: 32,
              colorHex: '#ffffff',
              svgScaleFactor: const Value(1.4),
            ),
          );
      final tuned = await (db.select(db.targets)
            ..where((t) => t.id.equals(tunedId)))
          .getSingle();
      expect(tuned.svgScaleFactor, 1.4);
    });

    test('targets accepts the new v37 center_point columns', () async {
      // v37 — `verticalCenterPctFromTop` and `horizontalCenterPctFromLeft`
      // are RealColumn defaults of 0.5 each. Rows inserted without
      // explicit values get the defaults; rows can override per-target.
      final defaultId = await db.into(db.targets).insert(
            TargetsCompanion.insert(
              name: 'v37 default-center row',
              category: 'ipsc',
              widthIn: 18,
              heightIn: 30,
              colorHex: '#ffffff',
            ),
          );
      final defaultRow = await (db.select(db.targets)
            ..where((t) => t.id.equals(defaultId)))
          .getSingle();
      expect(defaultRow.verticalCenterPctFromTop, 0.5);
      expect(defaultRow.horizontalCenterPctFromLeft, 0.5);

      final tunedId = await db.into(db.targets).insert(
            TargetsCompanion.insert(
              name: 'v37 tuned-center deer',
              category: 'ipsc',
              shapeId: const Value('deer'),
              widthIn: 60,
              heightIn: 32,
              colorHex: '#ffffff',
              verticalCenterPctFromTop: const Value(0.65),
              horizontalCenterPctFromLeft: const Value(0.40),
            ),
          );
      final tuned = await (db.select(db.targets)
            ..where((t) => t.id.equals(tunedId)))
          .getSingle();
      expect(tuned.verticalCenterPctFromTop, 0.65);
      expect(tuned.horizontalCenterPctFromLeft, 0.40);
    });

    test('targets accepts the new v36 shape_id column', () async {
      // v36 — `shape_id` routes animal / popper rows to their
      // user-authored SVGs. Nullable; pre-v36 rows or non-SVG shapes
      // (circle, rectangle, IPSC silhouette) leave it null.
      final animalId = await db.into(db.targets).insert(
            TargetsCompanion.insert(
              name: 'v36 test bear',
              category: 'ipsc',
              shapeId: const Value('bear'),
              widthIn: 60,
              heightIn: 32,
              colorHex: '#ffffff',
            ),
          );
      final animal = await (db.select(db.targets)
            ..where((t) => t.id.equals(animalId)))
          .getSingle();
      expect(animal.shapeId, 'bear');

      final plainId = await db.into(db.targets).insert(
            TargetsCompanion.insert(
              name: 'v36 plain circle',
              category: 'circle',
              widthIn: 12,
              heightIn: 12,
              colorHex: '#ffffff',
            ),
          );
      final plain = await (db.select(db.targets)
            ..where((t) => t.id.equals(plainId)))
          .getSingle();
      expect(plain.shapeId, isNull);
    });

    test('range_day_sessions accepts the 6 new v35 columns', () async {
      final id = await db.into(db.rangeDaySessions).insert(
            RangeDaySessionsCompanion.insert(
              name: 'v35 test session',
              date: DateTime.utc(2026, 5, 11),
              distanceYd: 500.0,
              // The 6 new columns from Appendix I:
              currentMagnification: const Value(10.0),
              currentReticleId: const Value('loadout_mil_tree_flare'),
              dewPointF: const Value(55.0),
              sessionLocalTime: const Value('2026-05-11T14:30:00-05:00'),
              latitudeDeg: const Value(33.7490),
              longitudeDeg: const Value(-84.3880),
            ),
          );
      final row =
          await (db.select(db.rangeDaySessions)..where((s) => s.id.equals(id)))
              .getSingle();
      expect(row.currentMagnification, 10.0);
      expect(row.currentReticleId, 'loadout_mil_tree_flare');
      expect(row.dewPointF, 55.0);
      expect(row.sessionLocalTime, '2026-05-11T14:30:00-05:00');
      expect(row.latitudeDeg, 33.7490);
      expect(row.longitudeDeg, -84.3880);
    });

    test('range_day_sessions new columns all accept null', () async {
      final id = await db.into(db.rangeDaySessions).insert(
            RangeDaySessionsCompanion.insert(
              name: 'minimal session',
              date: DateTime.utc(2026, 5, 11),
              distanceYd: 100.0,
            ),
          );
      final row =
          await (db.select(db.rangeDaySessions)..where((s) => s.id.equals(id)))
              .getSingle();
      expect(row.currentMagnification, isNull);
      expect(row.currentReticleId, isNull);
      expect(row.dewPointF, isNull);
      expect(row.sessionLocalTime, isNull);
      expect(row.latitudeDeg, isNull);
      expect(row.longitudeDeg, isNull);
    });

    test('user_firearms accepts the 3 new v35 default columns', () async {
      // The §6A.4 per-firearm defaults: defaultMagnification (numeric),
      // defaultScopeId (TEXT slug to scopes.json), defaultReticleId
      // (TEXT slug to reticles.json).
      final id = await db.into(db.userFirearms).insert(
            UserFirearmsCompanion.insert(
              name: '6.5 PRS rifle',
              defaultMagnification: const Value(15.0),
              defaultScopeId: const Value('vortex_optics_razor_hd_gen_iii_6_36x56_ffp'),
              defaultReticleId: const Value('loadout_mil_tree_flare'),
            ),
          );
      final row = await (db.select(db.userFirearms)
            ..where((f) => f.id.equals(id)))
          .getSingle();
      expect(row.defaultMagnification, 15.0);
      expect(row.defaultScopeId,
          'vortex_optics_razor_hd_gen_iii_6_36x56_ffp');
      expect(row.defaultReticleId, 'loadout_mil_tree_flare');
    });

    test('user_firearms new default columns all accept null', () async {
      final id = await db.into(db.userFirearms).insert(
            UserFirearmsCompanion.insert(name: 'no-defaults firearm'),
          );
      final row = await (db.select(db.userFirearms)
            ..where((f) => f.id.equals(id)))
          .getSingle();
      expect(row.defaultMagnification, isNull);
      expect(row.defaultScopeId, isNull);
      expect(row.defaultReticleId, isNull);
    });

    test('reticles.subtension_origin defaults to "original"', () async {
      final id = await db.into(db.reticles).insert(
            ReticlesCompanion.insert(
              manufacturerId: 'LoadOut',
              model: 'Test Mil Tree',
              type: 'ffp',
              nativeUnit: 'mil',
              maxExtentUnits: 10.0,
              definitionJson: '[]',
              // subtensionOrigin intentionally omitted → default kicks in
            ),
          );
      final row =
          await (db.select(db.reticles)..where((r) => r.id.equals(id)))
              .getSingle();
      expect(row.subtensionOrigin, 'original');
      expect(row.calibrationProvenance, isNull);
    });

    test('reticles.subtension_origin accepts explicit values', () async {
      final id = await db.into(db.reticles).insert(
            ReticlesCompanion.insert(
              manufacturerId: 'LoadOut',
              model: 'LPVO Chevron',
              type: 'sfp',
              nativeUnit: 'mil',
              maxExtentUnits: 5.0,
              definitionJson: '[]',
              subtensionOrigin: const Value('published_spec'),
              calibrationProvenance: const Value(
                '{"manufacturer":"Trijicon","reticle_name":"BAC Triangle"}',
              ),
            ),
          );
      final row =
          await (db.select(db.reticles)..where((r) => r.id.equals(id)))
              .getSingle();
      expect(row.subtensionOrigin, 'published_spec');
      expect(row.calibrationProvenance, contains('Trijicon'));
    });

    test('reticles.subtension_origin accepts "public_domain"', () async {
      final id = await db.into(db.reticles).insert(
            ReticlesCompanion.insert(
              manufacturerId: 'Public Domain',
              model: 'Plex',
              type: 'sfp',
              nativeUnit: 'mil',
              maxExtentUnits: 5.0,
              definitionJson: '[]',
              subtensionOrigin: const Value('public_domain'),
            ),
          );
      final row =
          await (db.select(db.reticles)..where((r) => r.id.equals(id)))
              .getSingle();
      expect(row.subtensionOrigin, 'public_domain');
    });
  });
}
