import 'dart:async';

import 'package:drift/drift.dart';

import '../database/database.dart';

/// Tuple returned by [BatchRepository.watchAll] / [BatchRepository.getAll].
/// Bundles the [BatchRow] together with the joined recipe / brass lot /
/// firearm rows so the list view can render a rich subtitle without
/// firing one query per row.
typedef BatchWithRefs = ({
  BatchRow batch,
  UserLoadRow? recipe,
  BrassLotRow? brassLot,
  UserFirearmRow? firearm,
});

class BatchRepository {
  BatchRepository(this.db);
  final AppDatabase db;

  // ─────────────────────── Reads ───────────────────────

  /// Watches every batch joined with its referenced recipe / brass lot /
  /// firearm rows. Implemented as a `combineLatest` over the four base
  /// table streams — Drift doesn't ship a 4-arity stream combinator, so
  /// the helper is in this file.
  Stream<List<BatchWithRefs>> watchAll() {
    final batches = (db.select(db.batches)
          ..orderBy([(b) => OrderingTerm.desc(b.updatedAt)]))
        .watch();
    final loads = db.select(db.userLoads).watch();
    final lots = db.select(db.brassLots).watch();
    final firearms = db.select(db.userFirearms).watch();

    return _combineLatest4<List<BatchRow>, List<UserLoadRow>,
        List<BrassLotRow>, List<UserFirearmRow>, List<BatchWithRefs>>(
      batches,
      loads,
      lots,
      firearms,
      (bs, ls, bls, fs) {
        final loadById = {for (final l in ls) l.id: l};
        final lotById = {for (final l in bls) l.id: l};
        final firearmById = {for (final f in fs) f.id: f};
        return [
          for (final b in bs)
            (
              batch: b,
              recipe: b.recipeId == null ? null : loadById[b.recipeId!],
              brassLot:
                  b.brassLotId == null ? null : lotById[b.brassLotId!],
              firearm:
                  b.firearmId == null ? null : firearmById[b.firearmId!],
            ),
        ];
      },
    );
  }

  /// One-shot variant of [watchAll].
  Future<List<BatchWithRefs>> getAll() async {
    final bs = await (db.select(db.batches)
          ..orderBy([(b) => OrderingTerm.desc(b.updatedAt)]))
        .get();
    if (bs.isEmpty) return const [];
    final ls = await db.select(db.userLoads).get();
    final bls = await db.select(db.brassLots).get();
    final fs = await db.select(db.userFirearms).get();
    final loadById = {for (final l in ls) l.id: l};
    final lotById = {for (final l in bls) l.id: l};
    final firearmById = {for (final f in fs) f.id: f};
    return [
      for (final b in bs)
        (
          batch: b,
          recipe: b.recipeId == null ? null : loadById[b.recipeId!],
          brassLot: b.brassLotId == null ? null : lotById[b.brassLotId!],
          firearm: b.firearmId == null ? null : firearmById[b.firearmId!],
        ),
    ];
  }

  Future<BatchRow?> getById(int id) =>
      (db.select(db.batches)..where((b) => b.id.equals(id)))
          .getSingleOrNull();

  Stream<BatchRow?> watchById(int id) =>
      (db.select(db.batches)..where((b) => b.id.equals(id)))
          .watchSingleOrNull();

  // ─────────────────────── Writes ───────────────────────

  Future<int> insert(BatchesCompanion entry) =>
      db.into(db.batches).insert(entry);

  Future<bool> update(int id, BatchesCompanion entry) =>
      (db.update(db.batches)..where((b) => b.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  Future<int> delete(int id) =>
      (db.delete(db.batches)..where((b) => b.id.equals(id))).go();

  /// Replace the saved process-step checklist state.
  Future<void> setProcessState(int id, String json) async {
    await (db.update(db.batches)..where((b) => b.id.equals(id))).write(
      BatchesCompanion(
        processStateJson: Value(json),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Increments [firedCount] by [delta] (typically positive). Clamped at
  /// `[0, count]` so we don't show "Fired 110/100".
  ///
  /// The brass-lot cascade is the caller's responsibility — the batch
  /// detail screen calls [BrassLotRepository.recordFiring] separately when
  /// `brassLotId` is set so the two updates can be presented atomically in
  /// the same UI action.
  Future<void> recordFiring(int id, int delta) async {
    final row = await getById(id);
    if (row == null) return;
    final next = (row.firedCount + delta).clamp(0, row.count);
    await (db.update(db.batches)..where((b) => b.id.equals(id))).write(
      BatchesCompanion(
        firedCount: Value(next),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}

/// 4-arity `combineLatest`. Emits a combined value once every source has
/// produced at least one event, then again on every subsequent emission
/// from any source. Cancels every upstream subscription when the
/// downstream subscription is cancelled.
Stream<R> _combineLatest4<A, B, C, D, R>(
  Stream<A> a,
  Stream<B> b,
  Stream<C> c,
  Stream<D> d,
  R Function(A a, B b, C c, D d) combine,
) {
  final controller = StreamController<R>();
  A? la;
  B? lb;
  C? lc;
  D? ld;
  bool sa = false, sb = false, sc = false, sd = false;
  late final List<StreamSubscription<dynamic>> subs;

  void emit() {
    if (sa && sb && sc && sd) {
      controller.add(combine(la as A, lb as B, lc as C, ld as D));
    }
  }

  controller.onListen = () {
    subs = [
      a.listen((v) {
        la = v;
        sa = true;
        emit();
      }, onError: controller.addError),
      b.listen((v) {
        lb = v;
        sb = true;
        emit();
      }, onError: controller.addError),
      c.listen((v) {
        lc = v;
        sc = true;
        emit();
      }, onError: controller.addError),
      d.listen((v) {
        ld = v;
        sd = true;
        emit();
      }, onError: controller.addError),
    ];
  };
  controller.onCancel = () async {
    for (final s in subs) {
      await s.cancel();
    }
  };
  return controller.stream;
}
