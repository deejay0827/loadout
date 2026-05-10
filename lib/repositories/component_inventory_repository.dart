// FILE: lib/repositories/component_inventory_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns every database operation against [ComponentInventory] and its
// audit-log sibling [ComponentInventoryAdjustments]. The two tables
// were added in schema v31 to give LoadOut parity with The Reloader's
// Log on on-hand component tracking — how much powder is left in each
// jug, how many primers are in the carton, how many bullets are in
// the tray, how many cases are in the brass bin, how many factory
// rounds are in the box.
//
// Public methods on `ComponentInventoryRepository`:
//   * `watchAll()` / `getAll()` — every inventory row, ordered by
//     kind then component name. The list-view screen subscribes via
//     `StreamBuilder` and rebuilds on every insert / update / delete.
//   * `watchByKind(kind)` — filtered to one of `'powder' | 'primer' |
//     'bullet' | 'brass' | 'cartridge'`. The list view groups by
//     kind, so the per-kind helper is convenient for the section
//     headers but the screen does the partition in Dart against
//     `watchAll()` to keep one stream subscription.
//   * `getById(id)` — single-row fetch.
//   * `insert(entry)` — upsert a new row. Auto-fills the `unit` column
//     from `kind` if the caller hasn't already populated it.
//   * `update(id, entry)` — patches an existing row, bumping
//     `updatedAt` so Cloud Sync's last-writer-wins reconciler can
//     pick the right side.
//   * `delete(id)` — hard-deletes the inventory row AND every
//     adjustment that hangs off it, in a single transaction. The
//     adjustments table holds an FK reference, so dropping the
//     parent without dropping the children would leave dangling
//     audit rows.
//   * `adjust(id, delta, reason, ...)` — records a quantity change.
//     Wraps both writes (the inventory `quantity` update and the
//     ledger insert) in a single transaction so the master row and
//     its history can never drift apart. Negative deltas are
//     clamped to zero on the master row but preserved verbatim in
//     the ledger so a "fired more than I had on hand" event still
//     produces a useful audit trail.
//   * `setQuantity(id, newQuantity, reason)` — absolute set with an
//     accompanying ledger row that records `delta = newQuantity -
//     currentQuantity`. Used when the user does a physical recount
//     and re-baselines.
//   * `watchAdjustments(inventoryId)` — live stream of every ledger
//     row for a given inventory id, newest first. Powers the audit
//     log on the form screen.
//   * `deductForBatch(batch)` — convenience cascade that walks a
//     batch and emits the right adjustments (powder grains × round
//     count, one primer per round, one bullet per round, optionally
//     one brass case per round). Best-effort: if no inventory row
//     matches the recipe component name the deduction is skipped
//     silently — the batch-completion flow can't fail because of an
//     untracked container.
//
// Unit conventions live in `unitForKind` so every consumer agrees
// on "gr" (powder), "ct" (primer / bullet / brass), "rd" (cartridge).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same repository pattern as the rest of `lib/repositories/`. Every
// screen and service that touches inventory talks to this class
// rather than the drift APIs directly:
//
//   * `lib/screens/inventory/inventory_list_screen.dart` subscribes
//     to `watchAll()` for the grouped list.
//   * `lib/screens/inventory/inventory_form_screen.dart` calls
//     `insert` / `update` / `delete` plus `watchAdjustments` for the
//     audit log card.
//   * `lib/screens/inventory/inventory_adjust_dialog.dart` calls
//     `adjust` for the quick "+10" / "-50" sheet.
//   * `lib/repositories/component_inventory_repository.dart` itself
//     is constructed once in `lib/app.dart` and provided via
//     `Provider<ComponentInventoryRepository>`.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **Two-table writes must be atomic.** `adjust` writes to
//     `ComponentInventory.quantity` AND `ComponentInventoryAdjustments`
//     in the same `db.transaction(...)`. Without the transaction,
//     a crash between the two writes would leave an audit log that
//     doesn't match the current quantity — defeating the whole
//     point of having a ledger.
//   * **Negative-delta clamping is asymmetric on purpose.** The
//     master row's `quantity` is clamped to zero (a -50 against
//     a 30 leaves quantity=0). The ledger row records the actual
//     -50 the user requested, so the audit trail tells the truth
//     about what the user did even when the math underran.
//   * **No FK cascade in SQLite.** Drift declares the FK but
//     SQLite doesn't enforce it by default in this codebase, so
//     `delete(id)` has to scrub adjustments manually. Forgetting
//     this would leave orphaned audit rows after every delete.
//   * **`deductForBatch` is best-effort by design.** The batch
//     flow can't fail because of an untracked container (the user
//     hasn't always logged every jug they've bought). Mismatches
//     are silently skipped; the flow's caller is expected to surface
//     a "Some inventory was not deducted" hint when the count of
//     successful deductions is less than the count of recipe
//     components the batch consumed.
//   * **`unit` is computed at insert time and stored.** Re-deriving
//     the unit on every read works today, but storing it means
//     future `kind` additions ("wad" for shotshell, etc.) can ship
//     with their own unit string without requiring a backfill
//     migration of every existing row.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/inventory/inventory_list_screen.dart
// - lib/screens/inventory/inventory_form_screen.dart
// - lib/screens/inventory/inventory_adjust_dialog.dart
// - lib/app.dart — Provider construction.
// - test/component_inventory_repository_test.dart — unit tests.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads / writes against the local SQLite database via drift. Every
// `adjust` / `setQuantity` / `delete` runs inside a `transaction(...)`
// so the master row and the audit ledger stay consistent. No JSON
// encoding (every column is typed). No network. No shared
// preferences.

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../utils/natural_sort.dart';

/// Inventory kind constants. Stored as raw strings in the table so
/// adding new kinds doesn't require a schema migration; using the
/// constants keeps typos out of production data.
const String kInventoryKindPowder = 'powder';
const String kInventoryKindPrimer = 'primer';
const String kInventoryKindBullet = 'bullet';
const String kInventoryKindBrass = 'brass';
const String kInventoryKindCartridge = 'cartridge';

/// Display order for the inventory kinds in the list view. Mirrors
/// the order on the recipe form's component pickers (powder first
/// because it's the highest-engagement consumable).
const List<String> kInventoryKindOrder = <String>[
  kInventoryKindPowder,
  kInventoryKindPrimer,
  kInventoryKindBullet,
  kInventoryKindBrass,
  kInventoryKindCartridge,
];

/// Adjustment-reason discriminators.
const String kAdjustReasonManual = 'manual';
const String kAdjustReasonBatch = 'batch';
const String kAdjustReasonAdjustment = 'adjustment';
const String kAdjustReasonOpened = 'opened';

/// Map a `kind` to its canonical unit string.
///
///   - powder → "gr" (grains)
///   - primer / bullet / brass → "ct" (count)
///   - cartridge → "rd" (rounds)
///
/// Unknown kinds fall back to "ct" — adding a new kind ought to
/// include the right unit here, but the fallback keeps callers
/// safe.
String unitForKind(String kind) {
  switch (kind) {
    case kInventoryKindPowder:
      return 'gr';
    case kInventoryKindCartridge:
      return 'rd';
    case kInventoryKindPrimer:
    case kInventoryKindBullet:
    case kInventoryKindBrass:
    default:
      return 'ct';
  }
}

/// User-facing label for an inventory kind. Title Case per CLAUDE.md
/// § 0a — the Section Headers in the list view show "Powders",
/// "Primers", etc.
String displayKindPlural(String kind) {
  switch (kind) {
    case kInventoryKindPowder:
      return 'Powders';
    case kInventoryKindPrimer:
      return 'Primers';
    case kInventoryKindBullet:
      return 'Bullets';
    case kInventoryKindBrass:
      return 'Brass';
    case kInventoryKindCartridge:
      return 'Factory Cartridges';
    default:
      return kind;
  }
}

/// Singular display label.
String displayKindSingular(String kind) {
  switch (kind) {
    case kInventoryKindPowder:
      return 'Powder';
    case kInventoryKindPrimer:
      return 'Primer';
    case kInventoryKindBullet:
      return 'Bullet';
    case kInventoryKindBrass:
      return 'Brass';
    case kInventoryKindCartridge:
      return 'Factory Cartridge';
    default:
      return kind;
  }
}

/// CRUD + audit-log helpers for [ComponentInventory] and
/// [ComponentInventoryAdjustments].
class ComponentInventoryRepository {
  ComponentInventoryRepository(this.db);
  final AppDatabase db;

  // ─────────────────────── Reads ───────────────────────

  /// Streams every inventory row, ordered by kind (per
  /// [kInventoryKindOrder]) then by component name (natural sort).
  Stream<List<ComponentInventoryRow>> watchAll() {
    return db.select(db.componentInventory).watch().map(_naturalSorted);
  }

  /// One-shot snapshot of every inventory row, ordered the same way
  /// [watchAll] orders its emissions.
  Future<List<ComponentInventoryRow>> getAll() async {
    final rows = await db.select(db.componentInventory).get();
    return _naturalSorted(rows);
  }

  /// Streams every inventory row for a single kind, naturally sorted
  /// by component name. Used by callers that want a per-kind picker
  /// (e.g. inventory-aware autocomplete in the recipe form, future).
  Stream<List<ComponentInventoryRow>> watchByKind(String kind) {
    return (db.select(db.componentInventory)..where((r) => r.kind.equals(kind)))
        .watch()
        .map((rows) => rows.toList()
          ..sort((a, b) => naturalCompare(a.componentName, b.componentName)));
  }

  Future<ComponentInventoryRow?> getById(int id) =>
      (db.select(db.componentInventory)..where((r) => r.id.equals(id)))
          .getSingleOrNull();

  /// Looks up an existing inventory row by `(kind, componentName)`.
  /// Used by [deductForBatch] to find the right container to
  /// decrement when a batch consumes stock. Returns null if no
  /// matching row exists — callers treat that as "user hasn't tracked
  /// this jug" and skip the deduction.
  ///
  /// Matching is case-insensitive and trims whitespace so a recipe
  /// stored as "Hodgdon Varget" matches an inventory row stored as
  /// "Hodgdon Varget " (trailing space) without tripping the user.
  /// If multiple rows match, the one with the most-recent
  /// `openedAt` wins (LIFO — the user is presumably reaching for
  /// the most-recently-opened container).
  Future<ComponentInventoryRow?> findByName({
    required String kind,
    required String componentName,
  }) async {
    final query = componentName.trim().toLowerCase();
    if (query.isEmpty) return null;
    final rows = await (db.select(db.componentInventory)
          ..where((r) => r.kind.equals(kind)))
        .get();
    final candidates = rows
        .where((r) => r.componentName.trim().toLowerCase() == query)
        .toList();
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;
    candidates.sort((a, b) {
      final ao = a.openedAt;
      final bo = b.openedAt;
      if (ao == null && bo == null) return b.createdAt.compareTo(a.createdAt);
      if (ao == null) return 1; // null = older
      if (bo == null) return -1;
      return bo.compareTo(ao); // most recent first
    });
    return candidates.first;
  }

  // ─────────────────────── Writes ───────────────────────

  /// Insert a new inventory row. Auto-fills the `unit` column from
  /// `kind` if the caller passes [Value.absent] or an empty string —
  /// mirrors the `unitForKind(kind)` mapping so the UI never has to
  /// remember the unit-string convention.
  Future<int> insert(ComponentInventoryCompanion entry) async {
    final patched = _withDerivedUnit(entry);
    return db.into(db.componentInventory).insert(patched);
  }

  /// Update an existing row. Auto-bumps `updatedAt` so Cloud Sync's
  /// last-writer-wins reconciler picks the right side.
  Future<bool> update(int id, ComponentInventoryCompanion entry) async {
    final patched = _withDerivedUnit(entry);
    final rows = await (db.update(db.componentInventory)
          ..where((r) => r.id.equals(id)))
        .write(patched.copyWith(updatedAt: Value(DateTime.now())));
    return rows > 0;
  }

  /// Hard-delete the inventory row AND every adjustment that hangs
  /// off it, in a single transaction. Required because we don't
  /// enable SQLite FK enforcement; without this manual cascade the
  /// adjustments table would accumulate orphan rows.
  Future<int> delete(int id) async {
    return db.transaction(() async {
      await (db.delete(db.componentInventoryAdjustments)
            ..where((a) => a.inventoryId.equals(id)))
          .go();
      return (db.delete(db.componentInventory)..where((r) => r.id.equals(id)))
          .go();
    });
  }

  // ─────────────────────── Quantity adjustments ───────────────────────

  /// Apply a relative quantity change to inventory row [id] and
  /// record the change in the audit log. Both writes happen inside a
  /// single `db.transaction(...)` so the master row's `quantity`
  /// and the ledger row are guaranteed consistent.
  ///
  /// `delta` may be positive (replenishment) or negative
  /// (consumption). The master row's `quantity` is clamped to zero
  /// to avoid negative on-hand counts, but the ledger row records
  /// the actual delta the caller passed — including any underrun —
  /// so the audit log tells the truth.
  ///
  /// Returns the new master `quantity` after the clamp, or null if
  /// the inventory row doesn't exist.
  Future<double?> adjust(
    int id, {
    required double delta,
    required String reason,
    int? batchLogId,
    String? notes,
  }) async {
    return db.transaction(() async {
      final current = await (db.select(db.componentInventory)
            ..where((r) => r.id.equals(id)))
          .getSingleOrNull();
      if (current == null) return null;
      final next = (current.quantity + delta).clamp(0.0, double.infinity);
      await (db.update(db.componentInventory)..where((r) => r.id.equals(id)))
          .write(ComponentInventoryCompanion(
        quantity: Value(next),
        updatedAt: Value(DateTime.now()),
      ));
      await db
          .into(db.componentInventoryAdjustments)
          .insert(ComponentInventoryAdjustmentsCompanion.insert(
            inventoryId: id,
            delta: delta,
            reason: reason,
            batchLogId: Value(batchLogId),
            notes: Value(notes),
          ));
      return next;
    });
  }

  /// Set the master `quantity` to an absolute value. Records an
  /// adjustment row with `delta = newQuantity - currentQuantity` so
  /// the ledger still represents the change rather than the new
  /// total.
  ///
  /// Used after a physical recount when the user wants to
  /// re-baseline rather than apply incremental deltas.
  Future<double?> setQuantity(
    int id, {
    required double newQuantity,
    String reason = kAdjustReasonAdjustment,
    String? notes,
  }) async {
    return db.transaction(() async {
      final current = await (db.select(db.componentInventory)
            ..where((r) => r.id.equals(id)))
          .getSingleOrNull();
      if (current == null) return null;
      final clamped =
          newQuantity < 0 ? 0.0 : newQuantity;
      final delta = clamped - current.quantity;
      await (db.update(db.componentInventory)..where((r) => r.id.equals(id)))
          .write(ComponentInventoryCompanion(
        quantity: Value(clamped),
        updatedAt: Value(DateTime.now()),
      ));
      await db
          .into(db.componentInventoryAdjustments)
          .insert(ComponentInventoryAdjustmentsCompanion.insert(
            inventoryId: id,
            delta: delta,
            reason: reason,
            notes: Value(notes),
          ));
      return clamped;
    });
  }

  // ─────────────────────── Audit log reads ───────────────────────

  /// Live stream of every adjustment for the inventory row [inventoryId],
  /// newest first. Powers the audit-log card on the form screen.
  Stream<List<ComponentInventoryAdjustmentRow>> watchAdjustments(
      int inventoryId) {
    return (db.select(db.componentInventoryAdjustments)
          ..where((a) => a.inventoryId.equals(inventoryId))
          ..orderBy([(a) => OrderingTerm.desc(a.createdAt)]))
        .watch();
  }

  /// One-shot fetch of the audit log for a single inventory row,
  /// newest first.
  Future<List<ComponentInventoryAdjustmentRow>> getAdjustments(
      int inventoryId) {
    return (db.select(db.componentInventoryAdjustments)
          ..where((a) => a.inventoryId.equals(inventoryId))
          ..orderBy([(a) => OrderingTerm.desc(a.createdAt)]))
        .get();
  }

  // ─────────────────────── Batch cascade ───────────────────────

  /// Walk a [BatchRow] and emit deductions for each component the
  /// batch consumed. Best-effort: missing inventory rows are skipped
  /// silently so an untracked container can never block the
  /// batch-completion flow.
  ///
  /// Math:
  ///   - powder: `recipe.powderChargeGr * (delta || batch.firedCount)` grains
  ///   - primer: 1 per round
  ///   - bullet: 1 per round
  ///   - brass:  1 per round IFF `freshBrass == true` (default false;
  ///     a typical reload reuses cases so we don't decrement brass
  ///     stock on every batch)
  ///
  /// `roundsConsumed` defaults to `batch.firedCount`. Pass an
  /// explicit value when the call site wants to deduct mid-batch
  /// (e.g. when finishing only part of a batch).
  ///
  /// Returns a small struct describing what was deducted and what
  /// was skipped, so the caller can surface a hint when some rows
  /// weren't found.
  Future<DeductionResult> deductForBatch(
    BatchRow batch, {
    UserLoadRow? recipe,
    int? roundsConsumed,
    bool freshBrass = false,
  }) async {
    final consumed = roundsConsumed ?? batch.firedCount;
    final result = DeductionResult();
    if (consumed <= 0) return result;

    // Powder: grains × rounds.
    if (recipe?.powder != null && recipe?.powderChargeGr != null) {
      final powderName = recipe!.powder!.trim();
      if (powderName.isNotEmpty) {
        final row = await findByName(
          kind: kInventoryKindPowder,
          componentName: powderName,
        );
        final grams = recipe.powderChargeGr! * consumed;
        if (row != null) {
          await adjust(
            row.id,
            delta: -grams,
            reason: kAdjustReasonBatch,
            batchLogId: batch.id,
            notes: 'Batch "${batch.name}"',
          );
          result.deducted++;
        } else {
          result.skipped++;
        }
      }
    }

    // Primer: one per round.
    if (recipe?.primer != null) {
      final primerName = recipe!.primer!.trim();
      if (primerName.isNotEmpty) {
        final row = await findByName(
          kind: kInventoryKindPrimer,
          componentName: primerName,
        );
        if (row != null) {
          await adjust(
            row.id,
            delta: -consumed.toDouble(),
            reason: kAdjustReasonBatch,
            batchLogId: batch.id,
            notes: 'Batch "${batch.name}"',
          );
          result.deducted++;
        } else {
          result.skipped++;
        }
      }
    }

    // Bullet: one per round.
    if (recipe?.bullet != null) {
      final bulletName = recipe!.bullet!.trim();
      if (bulletName.isNotEmpty) {
        final row = await findByName(
          kind: kInventoryKindBullet,
          componentName: bulletName,
        );
        if (row != null) {
          await adjust(
            row.id,
            delta: -consumed.toDouble(),
            reason: kAdjustReasonBatch,
            batchLogId: batch.id,
            notes: 'Batch "${batch.name}"',
          );
          result.deducted++;
        } else {
          result.skipped++;
        }
      }
    }

    // Brass: only when explicitly fresh (a reload reuses brass).
    if (freshBrass && recipe?.brass != null) {
      final brassName = recipe!.brass!.trim();
      if (brassName.isNotEmpty) {
        final row = await findByName(
          kind: kInventoryKindBrass,
          componentName: brassName,
        );
        if (row != null) {
          await adjust(
            row.id,
            delta: -consumed.toDouble(),
            reason: kAdjustReasonBatch,
            batchLogId: batch.id,
            notes: 'Batch "${batch.name}"',
          );
          result.deducted++;
        } else {
          result.skipped++;
        }
      }
    }

    return result;
  }

  // ─────────────────────── Internal helpers ───────────────────────

  /// Sort inventory rows by kind (using [kInventoryKindOrder]) then
  /// by `componentName` (natural sort). Stable across calls so the
  /// list view doesn't reshuffle when a row's `quantity` changes.
  static List<ComponentInventoryRow> _naturalSorted(
      List<ComponentInventoryRow> rows) {
    final list = [...rows];
    int kindOrder(String kind) {
      final idx = kInventoryKindOrder.indexOf(kind);
      return idx < 0 ? kInventoryKindOrder.length : idx;
    }
    list.sort((a, b) {
      final k = kindOrder(a.kind).compareTo(kindOrder(b.kind));
      if (k != 0) return k;
      return naturalCompare(a.componentName, b.componentName);
    });
    return list;
  }

  /// If the caller didn't pass a unit (or passed an empty string),
  /// derive it from `kind` via [unitForKind]. Lets every call site
  /// just pass `kind` + `componentName` + `quantity` without having
  /// to remember the unit-string convention.
  ComponentInventoryCompanion _withDerivedUnit(
      ComponentInventoryCompanion entry) {
    final hasUnit = entry.unit.present && entry.unit.value.trim().isNotEmpty;
    if (hasUnit) return entry;
    final kind = entry.kind.present ? entry.kind.value : kInventoryKindPowder;
    return entry.copyWith(unit: Value(unitForKind(kind)));
  }
}

/// Outcome of a [ComponentInventoryRepository.deductForBatch] call.
/// `deducted` is the number of recipe components whose inventory was
/// found and decremented; `skipped` is the number whose inventory
/// row was missing. The caller can compute "all components tracked"
/// as `skipped == 0`.
class DeductionResult {
  int deducted = 0;
  int skipped = 0;

  /// True when at least one component was decremented.
  bool get anyDeducted => deducted > 0;

  /// True when at least one component had no inventory row to
  /// decrement.
  bool get anySkipped => skipped > 0;
}
