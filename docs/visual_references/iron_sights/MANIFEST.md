# Iron Sights Visual References — MANIFEST

This directory contains canonical sighting-picture reference visuals for the iron-sights catalog rows shipping in VFP Phase 2 (Group B authoring, Group E reference set). Each entry below documents:

- **Source:** where the file originated
- **License:** the legal basis for inclusion in this repository
- **Use:** which catalog row(s) or sight configuration(s) the reference supports

These reference visuals serve as the QA-validation oracle for the VFP Phase 21 `IronSightsPainter` schematic rendering output. They are **not** load-bearing inputs for the painter itself — the painter renders from each catalog row's `subtensions` dict and `elements` blob per V6.11 §B.9 math — but they constitute the visual ground truth against which painter output is verified during Phase 21 implementation and review.

---

## TC 3-22.9 Series (US Army Rifle / Carbine Marksmanship)

### TC_322_9_Figure_3_6.png — AR-15 A2 carrying handle iron sight

- **Source:** TC 3-22.9 (Rifle and Carbine), Change 3, 20 November 2019
- **Figure:** 3-6 "Carrying handle with iron sight example"
- **Page:** 3-9
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Reference visual for AR-15 A2 / M16A4 service rifle catalog rows (front: post, rear: aperture with dual-aperture selector for normal-engagement vs close-quarters)

### TC_322_9_Figure_3_7.png — M4 carbine back-up iron sight (BUIS)

- **Source:** TC 3-22.9 (Rifle and Carbine), Change 3, 20 November 2019
- **Figure:** 3-7 "Back up iron sight"
- **Page:** 3-10 / 3-11
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Reference visual for M4 carbine BUIS catalog row (front: post, rear: aperture, flip-up rail-mounted; distinct from the carrying-handle integrated sight)

### TC_322_9_Figure_7_3.png — Front sight post / reticle aim focus

- **Source:** TC 3-22.9 (Rifle and Carbine), Change 3, 20 November 2019
- **Figure:** 7-3 "Front sight post/reticle aim focus"
- **Page:** 7-4
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Universal sight-picture focus reference (rifle/carbine). Illustrates the in-focus-front-sight visual physiology (front sharp, rear and target softer) that the `IronSightsPainter` should preserve when rendering any post + aperture configuration.

---

## TC 3-23.35 Series (US Army Pistol Marksmanship)

### TC_323_35_Figure_3_1.png — Pistol front blade + rear notch

- **Source:** TC 3-23.35 (Pistol Marksmanship)
- **Figure:** 3-1 "Front and rear sight"
- **Page:** 3-1 / 3-2
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Reference visual for 1911 GI and M9 service pistol catalog rows (front: blade, rear: notch, plain blade-and-notch sight system)

### TC_323_35_Figure_3_2.png — Three-dot pistol sight system

- **Source:** TC 3-23.35 (Pistol Marksmanship)
- **Figure:** 3-2 "Three-dot sight system"
- **Page:** 3-2 / 3-3
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Reference visual for Glock factory pistol catalog row and any other three-dot service pistol configuration (blade + notch with tritium / paint dot accents). Per the figure: align by "even height and light between the front sight post and rear notch"; the dots are positional cues, not the alignment reference.

### TC_323_35_Figure_7_3_p1.png — Proper sight alignment (page 1 of 2)

- **Source:** TC 3-23.35 (Pistol Marksmanship)
- **Figure:** 7-3 "Proper sight alignment" (page 1)
- **Page:** 7-5
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Universal pistol sight-alignment reference. Shows the "even space" + "level top" alignment principle that applies across all blade + notch pistol configurations.

### TC_323_35_Figure_7_3_p2.png — Proper sight alignment (page 2 of 2)

- **Source:** TC 3-23.35 (Pistol Marksmanship)
- **Figure:** 7-3 "Proper sight alignment" (page 2)
- **Page:** 7-6
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Continuation of Figure 7-3 alignment reference. Useful as the universal sight-picture QA oracle across pistol catalog entries.

---

## TM 9-1005-223-10 (M14 Rifle Operator's Manual)

### TM-9-1005-223-10_field_manual.pdf — M14 rifle technical reference

- **Source:** TM 9-1005-223-10 (Operator's Manual, Rifle, 7.62-MM, M14 / M14A1, Bipod, Rifle, M2), Headquarters Department of the Army, 21 March 1972
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Spec authority and reference documentation for M1/M14-class service rifle catalog rows (post + dual aperture, historical lineage of US service-rifle iron sights). The M14 sight design is the direct predecessor to the AR-15 A2's carrying-handle sight. Full document retained in this directory for traceability; specific sight-picture figures (Chapter 2 operating instructions) may be cited in catalog row `notes` fields as the implementation phase requires.

---

## Manufacturer Technical Documentation (Lever-Action Sight Configurations)

The following manufacturer-published owner's manuals serve as spec authority for the lever-action bead + buckhorn and related lever-gun iron-sight catalog rows. They document the sight systems, adjustment procedures, and spec values used to populate the catalog rows.

### henry_h001.pdf — Henry H001 Lever-Action Owner's Manual

- **Source:** Henry Repeating Arms, H001 Lever Action Rifle Owner's Manual (.22 S/L/LR, .22 Mag, .17 HMR variants)
- **License:** Manufacturer technical documentation; used under nominative fair-use doctrine for product identification and descriptive use of published sight system specifications. Consistent with the catalog's existing IP posture for 47 scopes across 26 brands (factual product identification).
- **Use:** Spec authority for .22 lever-action sight configurations. Documents H001's rear sight options (fully adjustable, peep sight, fiber optic) and front sight options (brass bead, hooded blade, fiber optic). Supports multiple lever-action catalog row variants.

### henry_h006_big_boy.pdf — Henry H006 Big Boy Owner's Manual

- **Source:** Henry Repeating Arms, H006 Big Boy Lever Action Rifle Owner's Manual (.357 Mag, .41 Mag, .44 Mag/Spl, .45 Colt, .327 Fed Mag variants)
- **License:** Manufacturer technical documentation; nominative fair-use product identification.
- **Use:** Primary spec authority for `lever_action_semi_buckhorn` catalog row (rear: fully adjustable buckhorn with diamond insert; front: brass bead). H006 sight specs are the canonical lever-action sight system for centerfire-caliber lever guns.

### winchester_1894_manual.pdf — Winchester Model 1894 Manual

- **Source:** Winchester Repeating Arms, Model 1894 Owner's Manual
- **License:** Manufacturer technical documentation; nominative fair-use product identification.
- **Use:** Corroborating second source for `lever_action_semi_buckhorn` catalog row. The Winchester Model 94 is the original archetype of the bead + buckhorn lever-action sight system; spec values cross-checked against H006 for consistency.

### marlinfirearms_owners_manual.pdf — Marlin Lever-Action Owner's Manual

- **Source:** Marlin Firearms (now Ruger), Lever Action Rifle Owner's Manual
- **License:** Manufacturer technical documentation; nominative fair-use product identification.
- **Use:** Spec authority for Marlin-pattern lever-action sight variants (elevator-adjustable and screw-adjustable open rear sights, brass bead fronts). Marlin 336 / 1894 / 1895 sight specs.

### TC_322_9_Table_F_1.pdf — TC 3-22.9 Appendix F Table F-1

- **Source:** TC 3-22.9 (Rifle and Carbine), Appendix F, Table F-1 "Offset mounting"
- **License:** US Government work, public domain (17 USC § 105)
- **Use:** Supporting documentation cross-referencing BUIS / CCO / iron-sight configurations across M16A2, M16A4, M4, and M4 MWS service rifles. Useful for catalog row traceability when documenting which sight configurations are issued on which weapon variants.

---

## Illustrative Diagrams (User-Supplied)

The following images are illustrative sight-picture diagrams supplied separately from the military and manufacturer technical documents above. Each entry has a placeholder for source attribution and license to be filled in upon next update of this manifest.

### buckhorn_sight.png — Buckhorn rear-sight silhouette with hold-over positions

- **Source:** [TODO — fill in: Wikipedia/Wikimedia Commons URL, manufacturer site, original drawing, etc.]
- **License:** [TODO — depends on source: CC-BY-SA / public domain / fair use / CC0]
- **Use:** Reference visual for `lever_action_semi_buckhorn` catalog row. Shows the buckhorn rear-sight silhouette (curved horns flanking a center notch) with three hold-over positions illustrating range-dependent point-of-aim placement (Far / Mid range / Near).

### globe_sight.png — Globe front-sight aperture with centered target

- **Source:** [TODO — fill in source URL or origin]
- **License:** [TODO — depends on source]
- **Use:** Reference visual for `target_globe_diopter` catalog row. Shows the globe front-sight aperture (ring) framing a centered target bullseye, illustrating proper globe-sight alignment for smallbore / target rifle configurations.

### peephorn_sight.png — Lyman tang peep sight (product photograph)

- **Source:** [TODO — fill in source URL, e.g., lymanproducts.com product page, retailer page, Wikipedia, etc.]
- **License:** [TODO — typically nominative fair use for product identification if from Lyman / retailer; CC license if from Wikimedia]
- **Use:** Reference visual for `marbles_pattern_tang_peep` catalog row and any tang-peep iron-sight configuration. Shows Lyman tang peep sight mounted on a lever-action rifle (functionally equivalent to Marbles tang peep — same product class, different manufacturer). The filename "peephorn" is a holdover from an earlier reference image that was replaced for IP reasons; the image content shows a Lyman tang peep, not a Renner "Peephorn™".

---

## How To Use This Directory

### For VFP Phase 21 `IronSightsPainter` implementation

These references are the visual oracle against which painter output is verified. Workflow:

1. Painter renders sight picture for a catalog row from its `subtensions` dict and `elements` blob per V6.11 §B.9 math
2. Reviewer compares the rendered output against the relevant reference visual above
3. Geometric correctness verified by §B.9 math; aesthetic / style correctness verified by reference-visual alignment

Reference visuals do **not** need to match painter output pixel-for-pixel — the painter renders schematically, while many references are photographs or training diagrams. The verification check is "does the painter capture the same essential geometric relationship the reference visual depicts."

### For catalog row authoring (Phase 2 Group B, future additions)

When authoring or updating an iron-sights catalog row, cross-reference the relevant manufacturer technical PDF in this directory for sight-system specs and adjustment-procedure documentation. Cite the source PDF in the catalog row's `notes` field per the source-attribution discipline established in Phase 1 / Phase 2.

### For source-attribution updates

The three illustrative diagrams (`buckhorn_sight.png`, `globe_sight.png`, `peephorn_sight.png`) have placeholder source / license entries above. Update these entries when the source / license information becomes available, preserving the same MANIFEST.md entry structure (Source / License / Use fields).

---

## Phase Authority

Reference set assembled per VFP Phase 2 Group E. Group E exit criterion: canonical sighting-picture reference visuals supplied for the iron-sights catalog rows covering the §B.9 7-row worked-example set plus representative lever-action and target-rifle configurations. Reference set serves as QA-validation oracle for VFP Phase 21 `IronSightsPainter` and downstream phases.

**Phase 2 Group E disposition:** COMPLETE pending source-attribution placeholder fill-in for `buckhorn_sight.png`, `globe_sight.png`, and `peephorn_sight.png`. Group E does not gate Phase 3 or any other phase; reference visuals are QA oracle, not load-bearing inputs to the painter.
