# VFP Phase 3 Group B — Execution Dossier (teaser-blur Option 2)

**Date:** 2026-05-19. **Method:** §0.5 six-level grep-verify;
halt-and-surface every spec-vs-code/spec-internal tension; operator
rules each fork. Canonical mechanism/UX/validation reference:
`docs/PRO_GATING.md`. This dossier = the execution record + §0.5
findings + dispositions + cumulative V6.12 feed.

## 1. §0.5 findings & operator dispositions

| # | Finding (surfaced, not guessed) | Disposition |
|---|---|---|
| GB-1 | Plan §1.6 (entire VFP surface Pro) directly conflicted with the pre-A2 CLAUDE.md free-core posture + the canonical Pro-gate table + verified code (Scope View gated; reticle picker / target plot / previews / tier-flip FREE). | Operator chose **A2** (implement §1.6). New **Plan Authority Hierarchy** rule: plan's VFP-surface monetization decision supersedes pre-A2 CLAUDE.md; CLAUDE.md realigned. |
| GB-2 | Hard-paywall vs teaser UX. | Operator chose **teaser-blur Option 2** (live blurred preview, interactive controls, `ensurePro` on commit only). `BlurredProTeaser` primitive built. |
| GB-3 | Tier-picker spec-internal tension: "cycle free" vs "tap-to-commit-a-tier → ensurePro" with no distinct save action. | Operator ruling **(b)**: `setStyle` only, no `ensurePro` on cycling; blur is the render-layer gate ("nothing to enforce at the picker"). |
| GB-4 | Live-blur-during-slider-drag perf un-measurable in CI (widget-test, no device). | Operator: **deferred-to-device** pre-ship gate with verbatim acceptance criteria (PRO_GATING.md §6.1). Mitigations baked into the primitive. |
| GB-5 | Scope View hard-gated at entry (`_openScopeView` `ensurePro`) ⇒ free users could never reach `_animatedMoverCard`; D5 spec assumed they could. | Operator chose **Option β**: refactor entry → teaser-blur; **β-2 per-surface** (confirmed tractable). |
| GB-6 | ScopeViewScreen has no save/commit/apply action ⇒ no commit-chokepoint possible. | §0.5-verified; **render-layer blur is the gate** (same principle as GB-3). Recorded. |
| GB-7 | D7 ~50-70 per-surface widget matrix is harness-version-coupled (worktree old `EntitlementNotifier` vs main's `2456473` rework) ⇒ fragile pre-D11-merge. | Operator chose **(A) split**: structural invariants ship now (version-agnostic); full widget matrix = post-D11 pre-ship gate (PRO_GATING.md §6.2). |
| GB-8 | Audit Gap 1: cosmetic `'Pro'` chip on `_animatedMoverCard` advertised a non-existent gate. | Closed: chip **removed**; real gate = the `_scopeFovCard` teaser-blur the mover animates (switch/slider stay live). |
| GB-9 | Audit Gap 2: `scope_training_models.dart` is dead code; CLAUDE.md documents a Pro surface that no screen wires. | **Deferred** (not Group B). Tracked in PRO_GATING.md §8 so it can't fall through pre-launch. |
| GB-10 | Scoping: generic glyphs (`reticle_thumbnail`, picker field `+`/dot), empty/error states, **§30 caption** are not Pro content. | Out of scope; §30 caption ALWAYS clear (legal carve-out). Pinned by `teaser_blur_wiring_test.dart`. |

## 2. Deliverable status

| D | Item | Status |
|---|---|---|
| D1 | `BlurredProTeaser` primitive | ✅ analyze-clean; a11y single-node CTA |
| D2 | reticle picker (list blur + `_commitSelection` chokepoint) | ✅ analyze-clean |
| D3 | full-screen reticle preview (FOV blur; §30 caption clear; header rewritten) | ✅ analyze-clean |
| D4 | range_day_detail (5 wraps; tier-picker (b); shot-logging stays free) | ✅ analyze-clean |
| — | INTERIM commit D1–D4 → origin/main `446fc1d` (operator test build) | ✅ merged-tree compiles w/ `2456473` |
| D5 | Scope View Option β (entry-gate removed; β-2 FOV+adjustments wrapped; Gap-1 badge removed) | ✅ analyze-clean |
| D6 | Gap-2 + ProGate-consistency findings | ✅ folded into PRO_GATING.md §8/§2 (no throwaway file) |
| D7 | primitive contract test (11) + structural invariants (10) = **21 green** | ✅ analyze-clean; widget matrix → post-D11 (§6.2) |
| D8 | CLAUDE.md revisions | 🟠 **DRAFT — surfaced for operator review** (operator owns CLAUDE.md; applied post-approval) |
| D9 | CTA + marketing candidate strings | 🟠 **surfaced for operator review** (operator owns copy; placeholders ship marked) |
| D10 | `docs/PRO_GATING.md` | ✅ written (canonical reference) |
| D11 | dossier + verify + commit + Option-B merge | ✅ this dossier; verify+merge in the Group-B halt cycle |

## 3. Cumulative V6.12 codification feed (Group B slice)

Carries forward + adds: Plan Authority Hierarchy; teaser-blur
Option 2 as canonical VFP UX; `BlurredProTeaser` canonical
primitive; entry-level teaser-blur (Option β) default for
VFP-surface entry points; β-1 vs β-2 granularity sub-rule (β-2
preferred); tier-picker (b) "nothing to enforce at the picker";
legal/compliance UI carve-out (always clear); a11y single-coherent-
semantic-node CTA sub-rule; test-economics rule (harness-coupled
deferred / structural ships with impl); device-perf + post-D11
matrix as pre-public-ship gates; ProGate-vs-teaser-blur consistency
(pending post-D11 findings); Gap-2 deferred-wiring tracked.

Operator controls the V6.12 cut; this feed is cumulative input, not
a trigger.

## 4. Standing carries (unchanged — Phase-11-gated)

D-9d, D-1, D-2, D-5 still gate VFP Phase 11. Not touched by Group B.
