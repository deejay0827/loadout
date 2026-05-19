# LoadOut Pro-Gating — Canonical Reference (VFP Phase 3 Group B)

**Status:** authoritative for every VFP visual surface. **Date:**
2026-05-19. Supersedes the pre-A2 hard-paywall posture for VFP
surfaces. The CLAUDE.md "Monetization → Pro-gated features" table
remains the canonical *index*; this document is the canonical
*mechanism + UX + per-surface wiring + validation-gates* record.

---

## 1. Strategic posture — operator decision A2

The **entire VFP Range Day target / reticle / preview / zoom
surface is Pro** (V6.11 §1.6, itemized): target & reticle selection,
sample images, scope-view + sighting-picture rendering, zoom /
elevation sliders, and **all three visual tiers including Stylized**.

This was an explicit operator decision (A2). It conflicted with the
pre-A2 CLAUDE.md posture ("anonymous users get every core feature";
the canonical Pro-gate table did not list these surfaces). The
conflict was surfaced per §0.5 and resolved by the operator in
favour of A2.

### 1.1 Plan Authority Hierarchy (operator rule)

When the VFP plan (V6.11+) and a pre-A2 CLAUDE.md statement
conflict on a VFP-surface monetization boundary, **the plan's A2
decision wins** and CLAUDE.md is realigned to match (not the
reverse). General (non-VFP) free-core posture in CLAUDE.md is
unchanged — A2 scopes to the VFP visual surface only. Recorded for
the V6.12 codification feed.

---

## 2. UX pattern — teaser-blur Option 2 (canonical for VFP surfaces)

Free users are **not** hard-paywalled out of VFP surfaces. Instead:

1. The surface renders fully — controls, layout, structure visible.
2. A Gaussian blur is applied to the **Pro visual content**.
3. An "Unlock with Pro" CTA overlays the blurred content.
4. **Interactive controls stay interactive** (sliders drag,
   dropdowns expand, tier-pickers cycle, lists scroll).
5. The blurred preview **responds to control changes in real time**
   (the load-bearing Option-2 behaviour — drag a slider, the
   blurred view re-renders blurred at the new value).
6. Commit / lock-in / expand actions route through `ensurePro` →
   `PaywallScreen`.

Principle: *free users explore and feel the product (every control
responsive, the preview lives and reacts) but cannot commit to a
selection or clearly read the content* — the strongest conversion
signal.

**Two gating mechanisms coexist:**

| Mechanism | File | Used for |
|---|---|---|
| `BlurredProTeaser` | `lib/widgets/blurred_pro_teaser.dart` | **Canonical VFP teaser-blur.** Soft, live, blurred. |
| `ProGate` / `ensurePro` | `lib/widgets/pro_gate.dart` | Hard paywall (lock-tile / paywall route). Non-VFP Pro features (moving-target lead today, etc.). |

**Adjacent consistency item (recorded, resolution pending D7
post-D11 matrix):** moving-target-lead uses `ProGate` (hard
lock-tile), inconsistent with teaser-blur Option 2. If the post-D11
widget matrix confirms it delivers hard-paywall behaviour, refactor
it into the teaser-blur pattern as part of the coherent rollout. If
`ProGate` already supports a teaser mode, no change; V6.12 just
notes the parallel pattern.

---

## 3. `BlurredProTeaser` — the primitive

```dart
BlurredProTeaser(
  ctaText: 'Unlock with Pro',          // placeholder copy; final = operator-owned (§7)
  onCommit: () => ensurePro(context),  // optional; null → CTA is a pure label
  blurSigma: 8.0,                      // tunable per surface (default 8.0)
  child: theLiveProContent,            // built once; IDENTICAL for free & Pro
)
```

- **Pro (`isPro == true`)** → returns `child` verbatim. Zero
  overhead, no blur/CTA/scrim, full interactivity.
- **Free** → keeps `child` live in the tree (still rebuilds when
  its inputs change) but rasterises it through `ImageFiltered`
  (**not** `BackdropFilter`), paints an `IgnorePointer` scrim (so
  the child's scroll/pan/pinch/slider gestures are never eaten),
  and overlays a CTA. With `onCommit` the small centred CTA pill is
  the **only** tap-absorber; without it the pill is `IgnorePointer`
  (pure label) and the surface gates commits at its own handlers.
- Reactive: a purchase flips `EntitlementNotifier` → every teaser
  rebuilds to the clear child, no restart (`context.watch`).
- **Perf design:** `RepaintBoundary` raster isolation, `TileMode
  .decal`, per-surface tunable `blurSigma`. Real low-end-device
  validation is a pre-ship gate (§6.1).
- **Accessibility:** the CTA renders as a **single coherent
  semantics node** (`container` + `excludeSemantics`) — screen
  readers announce one phrase ("Unlock with Pro", button when
  tappable), not competing icon/text fragments. Codified sub-rule.

Contract is exhaustively pinned by
`test/blurred_pro_teaser_test.dart` (11 cases, version-agnostic).

---

## 4. Per-surface wiring map (verified)

| Surface | File | Wrapped (blurred) | Stays clear | Commit gate |
|---|---|---|---|---|
| Reticle picker list | `reticle_picker.dart` | populated `ListView` | empty/loading/error, field glyph | `_commitSelection`→`ensurePro` (row tap / "None" / Find-by-Scope) |
| Full-screen reticle preview | `reticle_full_screen_view.dart` | FOV render | **§30 interoperability caption** (legal — always clear), dismiss | CTA pill → `ensurePro` |
| Range Day target preview | `range_day_detail_screen.dart` `_targetVisualBox` | populated `TargetPlot` | empty-state | `_showTargetPreviewDialog` enlarge → `ensurePro` |
| Inline scope-view preview | `_combinedReticleTargetPreview` | populated `ClipRRect` scene | empty-state | CTA pill → `ensurePro` (expand = separate `_openScopeView`) |
| Range Day target plot | `_targetPlotCard` | 3× `TargetPlot` (stream-error / data / no-stream) | card chrome, tap-mode + view-mode toggles, stats | CTA pill → `ensurePro`; shot-logging stays free-functional (blurred dots) |
| Visual-tier picker | `range_day_detail_screen.dart` AppBar PopupMenu | (tier-driven render is gated via the wrapped scene) | the picker itself (free cycling — **ruling b**) | none — blur is the render-layer gate |
| Scope View FOV | `scope_view_screen.dart` `_scopeFovCard` | the eyepiece `Center(ClipOval(...))` | AppBar, badges/chips, tap-to-cycle-unit, `_controlsCard` | CTA pill → `ensurePro` |
| Scope View adjustments | `scope_view_screen.dart` `_adjustmentsTable` | the whole `Card` (dial-in numbers) | — | CTA pill → `ensurePro` |
| Scope View entry | `range_day_detail_screen.dart` `_openScopeView` | (screen opens for all; content gated inside) | — | **No entry paywall (D5 Option β)** — was hard-paywalled pre-A2; removed |
| `_animatedMoverCard` | `scope_view_screen.dart` | (animates the already-blurred FOV) | switch + slider stay live | none — Gap-1 cosmetic 'Pro' badge **removed**; blur is the gate |

### 4.1 Scoping principle — blur Pro content, not UI chrome

Out of scope (documented, pinned by `teaser_blur_wiring_test.dart`):
generic shared glyphs that are **not** per-item renders
(`reticle_thumbnail.dart`, the reticle-picker field `+`/dot glyph);
empty / loading / error states; navigation/header chrome.
**Legal/compliance UI (the §30 interoperability caption, license
attributions) ALWAYS renders clear regardless of Pro state** — it
carries compliance value, it is not Pro content to tease.

### 4.2 No-commit-chokepoint surfaces

ScopeViewScreen and the visual-tier picker have **no
save/commit/apply/lock-in action** (live read-only calculator /
preference cycle). Per §0.5 verification there is nothing to route
through `ensurePro`; the **render-layer blur is the gate**. This is
the same principle as the tier-picker option-(b) resolution.

---

## 5. Test discipline

| Layer | Status | Where |
|---|---|---|
| Primitive contract (the mechanism all surfaces delegate to) | ✅ shipped | `test/blurred_pro_teaser_test.dart` (11) |
| Structural wiring invariants (5 load-bearing claims) | ✅ shipped | `test/teaser_blur_wiring_test.dart` (10) |
| Full per-surface free/Pro **widget** matrix | ⏳ **deferred — pre-ship gate (§6.2)** | post-D11 |

**Test economics rule (V6.12 feed):** harness-version-coupled
tests are deferred to post-harness-stabilization-merge;
harness-agnostic structural assertions ship with the implementation.
Generalizable to any future test work that depends on an
about-to-change subsystem.

---

## 6. Pre-public-ship validation gates (deferred-but-tracked)

Both gates below are **required before any public ship**. Both have
concrete acceptance criteria. Neither is optional.

### 6.1 Device perf validation (operator-specified, verbatim)

```
PRE-SHIP DEVICE PERF VALIDATION — REQUIRED

Test device class:
- Low-end Android (3-4 year old budget device, ≤3GB RAM)
- Older iPhone (iPhone 8/SE generation acceptable)

Test scenarios:
- Range Day → free user → scope view preview visible
- Sustained zoom slider drag (5+ seconds continuous)
- Sustained elevation slider drag (5+ seconds continuous)
- Rapid visual-tier cycling (Stylized → Scenic → Photographic → Stylized, 5+ rounds)
- Combined: tier cycle mid-slider-drag

Acceptance criteria:
- No perceptible lag between slider position and blurred preview update
- Sustained ~30fps minimum during slider drag (60fps on flagship devices)
- No UI freezes or unresponsiveness in non-blurred areas of the screen
- No app crashes, OOM errors, or thermal throttling

If perf insufficient (any acceptance criterion fails):
- Surface as halt-and-validate finding via the standard halt-report channel
- Resolution options: (1) debounce slider-driven re-renders to 30fps during drag;
  (2) static-blur snapshot during active drag with full re-render on drag-end;
  (3) reduced blurSigma during drag, full sigma on drag-end;
  (4) shader-based blur implementation alternative
- Do not abandon the teaser-blur Option 2 pattern without operator review
```

Why deferred: `flutter test` is widget-test, not on-device GPU
profiling; no device in the implementation environment. The
`BlurredProTeaser` mitigations (RepaintBoundary, `TileMode.decal`,
tunable `blurSigma`) are sound architectural choices but the
ultimate validation legitimately needs real-device data. Honestly
deferring beats fabricating an unmeasurable "it's fine."

### 6.2 Post-D11 per-surface widget matrix (operator-specified, verbatim)

```
POST-D11-MERGE PER-SURFACE WIDGET MATRIX — REQUIRED PRE-PUBLIC-SHIP

Trigger: completion of D11 Option-B merge unifying the shipping 2456473
        entitlement harness (Diagnostics Free/Pro toggle) into the worktree

Scope: ~50 per-surface free/Pro widget tests, one matrix per gated VFP surface
       (reticle picker, full-screen reticle preview, sample images,
       _targetPlotCard, _scopeViewQuickCard, zoom slider, elevation slider,
       visual-tier PopupMenu, _animatedMoverCard, ScopeViewScreen entry,
       per surface within ScopeViewScreen)

Per-surface assertions:
  Free user:
    - Blur layer present (verify BlurredProTeaser wrapper in widget tree)
    - CTA overlay visible
    - Sliders / dropdowns / tier-pickers remain interactive
    - Preview responds to control changes in real-time (verify driven re-renders)
    - Commit actions trigger paywall (verify ensurePro fires on tap-to-select /
      tap-to-expand / save / lock-in actions)
    - Legal/compliance UI elements (e.g., §30 caption) remain clear
  Pro user:
    - No blur layer
    - No CTA overlay
    - Full normal interactivity end-to-end
    - Commit actions execute the actual action, not paywall

Halt-and-validate triggers (any of):
  - A surface fails to apply blur where expected
  - A commit action bypasses ensurePro
  - A control that should remain interactive becomes disabled or eaten by scrim
  - The reactive free→Pro flip fails (purchase event doesn't unblur immediately)

Estimated effort: ~50 cases × ~5 min/case = ~4 hours of focused test writing
                  + ~1 hour for harness-specific helper utilities
                  + ~1 hour for any halt-and-validate findings + resolution

Definition of done: All matrix cases green against the shipping harness;
                    any halt-and-validate findings surfaced and resolved
                    before public ship.
```

---

## 7. Copy ownership

All CTA strings shipped today are **placeholders** (e.g. "Unlock N
reticles · Pro", "See the full reticle · Pro", "Pro renders the
full target scene", "Pro shows the live view", "Pro renders the
live scope view", "Pro shows your dial-in adjustments"). Final CTA
copy + any marketing alignment is **operator-owned** and surfaced
as a candidate-string list for review (Group B D9) — same posture
as the `marketing/CLAUDE.md` candidate-string review.

---

## 8. Adjacent findings (recorded)

- **Gap 2 — `scope_training_models.dart` dead code.** CLAUDE.md
  (§ Monetization, "Scope View training mode" row) documents a Pro
  surface (`AimMode.requiresPro` / `TrainingOverlays.requiresPro`)
  that **no screen imports or wires**. Not VFP Phase 3 Group B
  work. Deferred: a later pass must either wire it into a real
  gated panel OR correct the CLAUDE.md row to match reality. Tracked
  here so it cannot fall through pre-launch sequencing.
- **ProGate consistency** — see §2 (resolution pending post-D11
  matrix findings).

---

## 9. V6.12 codification feed (Pro-gating slice, cumulative)

- A2 posture + Plan Authority Hierarchy (plan VFP-surface
  monetization decision supersedes pre-A2 CLAUDE.md; CLAUDE.md
  realigned).
- Teaser-blur Option 2 = canonical VFP Pro-gating UX;
  `BlurredProTeaser` = canonical primitive; entry-level teaser-blur
  (Option β) not hard-paywall for VFP-surface entry points.
- Entry-level vs surface-level granularity sub-rule: β-2
  (per-surface) preferred where tractable; β-1 (whole-screen)
  acceptable where per-surface is excessive.
- Tier-picker: cycling is free interaction; render gated via blur
  ("nothing to enforce at the picker").
- Legal/compliance UI carve-out: disclaimers/attributions always
  clear regardless of Pro state.
- A11y sub-rule: gated-content CTAs render as single coherent
  semantic nodes (`container` + `excludeSemantics`).
- Test economics rule (§5) + post-D11 matrix acceptance criteria
  (§6.2) + device perf checklist (§6.1) as pre-public-ship gates.
- ProGate-vs-teaser-blur consistency item (resolution pending).
