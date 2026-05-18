# Iron-Sights Consumer-Contract Trace — VFP Phase 2 Group D (§0.5 Level 3)

**Date:** 2026-05-18. **Method:** §0.5 Level 3 — trace every
consumer back to its source of truth; identify ALL parallel systems
before specifying handling. `grep -rn "ScopeViewInputs(" lib/` +
read of every site.

## 1. `ScopeViewInputs` construction trace (single funnel)

| Site | Role |
|---|---|
| `lib/screens/range_day/scope_view_screen.dart:105` | `const ScopeViewInputs({...})` ctor — `scopeMagnification` / `spec1xMagnification` are **`required` non-null `double`**; `reticle` is **`required` non-null `ReticleDefinition`** |
| `lib/screens/range_day/scope_view_screen.dart:1402→1434` | `buildScopeViewInputs({... OpticRow? optic ...})` — the **only** thing that calls the ctor |
| `lib/screens/range_day/range_day_detail_screen.dart:8257` | the **only** caller of `buildScopeViewInputs` (Scope View open) |

So there is exactly **one construction funnel** and **one caller**.
Plan-cited path `lib/screens/scope_view_screen.dart:159-166` is
**stale** — real path `lib/screens/range_day/scope_view_screen.dart`,
ctor at :105 (D-8-class path drift; **now 4×** — Phase 1 reticle
test, Phase 2 A scope-catalog test, Phase 2 C firearm-form, Phase 2 D
scope_view_screen — V6.12 one-time path sweep).

## 2. Parallel-system finding (the load-bearing §0.5 result)

`buildScopeViewInputs` consumes the **legacy `OpticRow`** (drift
`Optics` table, `database.g.dart:19528`) — **NOT** the v2.3
`ScopeV2Row` (`scopes.json`) where the iron-sights category lives.
Two parallel optic systems:

- **Legacy:** `_opticsId` → `Optics` drift → `OpticRow` → `optic:`
  arg of `buildScopeViewInputs`.
- **v2.3:** `_defaultScopeId` → `scopes.json` / `ScopeV2Row` →
  `category == "iron-sights"` (Groups A/B). **Invisible to
  `buildScopeViewInputs`.**

`buildScopeViewInputs` magnification logic
(`scope_view_screen.dart:1416-1446`): `specMag=10.0; initialMag=10.0`
defaults; `if (optic != null) { specMag = _parseMaxMag(...) ?? 10;
initialMag = specMag.clamp(4.5, 30.0); }`. **Every path yields a
non-null double** — `optic==null` → 10.0 default (the common case for
a v2.3-only / iron firearm with no legacy `OpticRow`); a legacy "1x"
row → `1.0.clamp(4.5,30)=4.5`. **No null-pointer risk exists today**;
the non-null `scopeMagnification`/`spec1xMagnification` contract is
satisfied by construction defaults.

## 3. Per-task disposition

| Task | Disposition |
|---|---|
| 1 — trace every ctor site | ✅ done (this §1; single funnel + single caller) |
| 2 — iron sentinels at the ctor site | **Premise mismatch (surfaced, no dead code added).** The funnel can't see v2.3 iron, and there is **no NPE** to prevent (defaults cover the non-null contract). Adding an unreachable iron branch to a legacy-`OpticRow` funnel would be speculative/duplicative code for a path VFP Phase 26 *replaces* with iron→`IronSightsPainter`. The 1.0/1.0 sentinel is instead recorded as the **binding doc-comment contract** (task 3) for the Phase 26 iron-construction path. |
| 3 — sentinel doc-comment | ✅ added verbatim to `ScopeViewInputs` class doc-comment (+ the §0.5 trace note) |
| 4 — firearm-form auto-pair skip | ✅ **already implemented by Group C** (`firearm_form_screen.dart:591` `if (scope.isIronSights) { …clear…; return; }` precedes `defaultReticleIdForScope`/`reticleById`). Verified; no duplicate edit. |
| 5 — Range Day null-guard | ✅ **holds** (no code change). `_applyV2DefaultsFromFirearm` (`range_day_detail_screen.dart:1496`): `final v2ReticleId = f.defaultReticleId; if (v2ReticleId == null \|\| v2ReticleId.isEmpty) return;`. Iron firearms store null `defaultReticleId` (Group C) → method early-returns, no reticle resolution, no NPE. Verified by test. |
| 6 — smoke | **Partial by plan design.** "No null exceptions" is provable now (contracts above). "Rendering goes through `IronSightsPainter`" is **NOT achievable in Phase 2** — `IronSightsPainter` is **VFP Phase 21** and tier-aware iron routing is **VFP Phase 26**. Group D guarantees *no-NPE at the construction contracts*; the iron-render assertion is a Phase 21/26 exit criterion. Surfaced. |

## 4. Re-broadened invariant (operator Group-D exit criterion)

Group C scope-excluded iron rows from the "every scope has a reticle
mapping" test. Per the operator's Group-D exit criterion, the
invariant is **re-broadened to TOTAL** in
`test/firearm_form_iron_sights_test.dart`: *every* scope row is now
asserted correctly partitioned — **non-iron ⇒ has a reticle mapping;
iron ⇒ has NONE (by design)** — so the catalog is fully covered
again rather than carved-out, and a regression either way fails.

## 5. Standing / V6.12 feed (cumulative)

- §0.5 finding #2 (scope→reticle invariant): **RESOLVED** — re-broadened
  to total (§4); no longer a carve-out.
- Task-2 premise mismatch + task-6 Phase-21/26 dependency: V6.12
  should reconcile Group D's task list to the parallel-system
  reality (the magnification contract is default-satisfied; the
  binding artifact is the doc-comment, consumed by Phase 26).
- D-8 path-citation drift now **4×** — reinforces the one-time V6.12
  `test/` + code-ref path sweep already in the feed.
- Carried unchanged, Phase-11-gated: D-9d, D-1, D-2, D-5.
