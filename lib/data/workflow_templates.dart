// FILE: lib/data/workflow_templates.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Holds the static "discipline workflow" templates surfaced from the
// onboarding deck and the Quick Add recipe screen. A workflow template
// bundles a few opinionated defaults that would otherwise have to be
// configured by hand across three different screens (Quick Add, Range
// Day session setup, ballistics solver):
//
//   * A starter recipe (links by id into [kRecipeTemplates] in
//     `lib/data/recipe_templates.dart`).
//   * A target type ('steel-plate' | 'paper' | 'silhouette').
//   * A typical engagement distance, in yards.
//   * A typical zero range, in yards.
//   * A drag model preset ('g7' | 'g1' | 'cdm').
//
// The point isn't to lock the user in — every value is editable on the
// resulting recipe / session / solver — it's to give a brand-new user a
// single tap that says "I shoot PRS" and get a working starting point
// for every screen they're about to encounter.
//
// Workflow templates are NOT a database table. They ship as `const` data
// with the binary for the same reasons recipe templates do: small set,
// curated, no user editing, updates ride along with app releases.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut is positioned for the pen-and-paper reloader cohort, but the
// app surface is general-purpose: PRS, F-Class, bench rest, hunting, 3-Gun,
// plinking, and silhouette all share the same recipe / firearm / range-day
// schema. Without an opinionated entry point, a new PRS shooter sees the
// same blank Range Day Setup as a new bench-rest shooter and has to figure
// out which fields matter from scratch.
//
// `WorkflowTemplate` collapses that decision into one tap. The onboarding
// deck pushes a "Pick your discipline" slide that pre-configures the
// first recipe + range-day session. The Quick Add screen surfaces a
// "Browse by discipline" entry point on the same template-picker card.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/onboarding/onboarding_screen.dart — discipline-picker slide.
// - lib/screens/recipes/quick_add_recipe_screen.dart — "Browse by
//   discipline" affordance on the template-picker card.

import 'package:flutter/material.dart';

import 'recipe_templates.dart';

/// One discipline preset surfaced from onboarding and Quick Add. Every
/// field is optional except [id], [name], [description], and [icon] — a
/// template that doesn't link to a recipe template (e.g. plinking) just
/// pre-configures the range-day side of things.
class WorkflowTemplate {
  const WorkflowTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.recipeTemplateId,
    this.targetCategory,
    this.defaultDistanceYd,
    this.defaultZeroYd,
    this.defaultDragModel,
  });

  /// Stable identifier. Used as the dropdown / radio value; never shown
  /// to the user.
  final String id;

  /// Display name shown on the discipline card ("PRS Long Range").
  final String name;

  /// One-line subtitle giving the typical caliber + distance range so a
  /// new user can self-identify ("500–1,000 yd steel plates · 6mm/6.5mm
  /// Creedmoor typical").
  final String description;

  /// Hero glyph used in the picker tile.
  final IconData icon;

  /// Recipe template id that this discipline starts from. Must match a
  /// `RecipeTemplate.id` in `kRecipeTemplates`. Null when no curated
  /// starting recipe exists for this discipline (e.g. plinking, where
  /// the user typically already has factory ammo on hand).
  final String? recipeTemplateId;

  /// Target type the range-day setup should default to. Free-form for
  /// now — the range-day screen can map known values to its target
  /// dropdown and ignore unknown ones.
  ///
  /// Conventional values:
  ///   * 'steel-plate' — gongs, KYL racks, IPSC steel.
  ///   * 'paper' — bench-rest dot drills, F-Class targets.
  ///   * 'silhouette' — metallic silhouette targets.
  final String? targetCategory;

  /// Typical engagement distance for this discipline, in yards. Pre-fills
  /// the range-day distance field.
  final int? defaultDistanceYd;

  /// Typical zero range for this discipline, in yards. Pre-fills the
  /// ballistics-solver zero range. 100 yd is the universal default for
  /// rifle disciplines; some short-range pistol disciplines use 25 yd.
  final int? defaultZeroYd;

  /// Drag-model preset for the ballistics solver. Conventional values:
  ///   * 'g7' — secant-ogive match bullets (most modern long-range).
  ///   * 'g1' — flat-base or hunting-profile bullets.
  ///   * 'cdm' — custom drag model (manufacturer-supplied curve, when
  ///     the user is going to import one).
  final String? defaultDragModel;

  /// Convenience: resolve the linked recipe template, if any. Returns
  /// null when [recipeTemplateId] is null or doesn't match a known
  /// template (defensive — recipe ids might be re-keyed in the future).
  RecipeTemplate? get recipeTemplate {
    final id = recipeTemplateId;
    if (id == null) return null;
    for (final t in kRecipeTemplates) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// The shipping discipline set. Order is curated — broadest cohorts first.
const List<WorkflowTemplate> kWorkflowTemplates = <WorkflowTemplate>[
  WorkflowTemplate(
    id: 'prs',
    name: 'PRS Long Range',
    description: '500–1,000 yd steel plates · 6mm / 6.5mm Creedmoor typical',
    icon: Icons.gps_fixed,
    recipeTemplateId: '6_5_creedmoor_h4350_140eldm',
    targetCategory: 'steel-plate',
    defaultDistanceYd: 800,
    defaultZeroYd: 100,
    defaultDragModel: 'g7',
  ),
  WorkflowTemplate(
    id: 'fclass',
    name: 'F-Class / Long Range Paper',
    description: '600–1,000 yd paper · .308 / 6.5 Creedmoor / .284',
    icon: Icons.center_focus_strong,
    recipeTemplateId: '308_win_varget_168smk',
    targetCategory: 'paper',
    defaultDistanceYd: 600,
    defaultZeroYd: 100,
    defaultDragModel: 'g7',
  ),
  WorkflowTemplate(
    id: 'benchrest',
    name: 'Bench Rest',
    description: '100–300 yd paper · accuracy-first short-range',
    icon: Icons.straighten,
    recipeTemplateId: '308_win_varget_168smk',
    targetCategory: 'paper',
    defaultDistanceYd: 100,
    defaultZeroYd: 100,
    defaultDragModel: 'g7',
  ),
  WorkflowTemplate(
    id: '3gun',
    name: '3-Gun',
    description: 'Mixed paper + steel · .223 / .300 BLK / 9mm typical',
    icon: Icons.flash_on,
    recipeTemplateId: '223_rem_h335_55fmj',
    targetCategory: 'steel-plate',
    defaultDistanceYd: 200,
    defaultZeroYd: 50,
    defaultDragModel: 'g1',
  ),
  WorkflowTemplate(
    id: 'hunting',
    name: 'Hunting',
    description: '100–500 yd · controlled-expansion bullets',
    icon: Icons.terrain,
    recipeTemplateId: '308_win_varget_168smk',
    targetCategory: 'paper',
    defaultDistanceYd: 200,
    defaultZeroYd: 200,
    defaultDragModel: 'g1',
  ),
  WorkflowTemplate(
    id: 'plinking',
    name: 'Plinking / Practice',
    description: 'Casual range time · any caliber, paper or steel',
    icon: Icons.sports_score,
    recipeTemplateId: '9mm_titegroup_124fmj',
    targetCategory: 'steel-plate',
    defaultDistanceYd: 25,
    defaultZeroYd: 25,
    defaultDragModel: 'g1',
  ),
  WorkflowTemplate(
    id: 'silhouette',
    name: 'Silhouette',
    description: '50–500 m metallic silhouettes · animal targets',
    icon: Icons.pets,
    recipeTemplateId: '223_rem_h335_55fmj',
    targetCategory: 'silhouette',
    defaultDistanceYd: 200,
    defaultZeroYd: 100,
    defaultDragModel: 'g1',
  ),
];
