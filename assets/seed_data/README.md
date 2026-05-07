# `assets/seed_data/` — the LoadOut reference catalog

This folder is the **bundled reference catalog** for the LoadOut reloading app.
Everything in here is plain JSON. None of it is user data — it is a curated,
read-only library of cartridges, components, and firearms that the app needs
in order to populate dropdowns, autocompletes, and lookup screens before the
user has typed anything.

> If you came here looking to fix a typo in a powder name or add a new
> cartridge, the per-file schema reference is [section B](#b-per-file-schema-reference)
> and the recipe for adding entries is [section C](#c-how-to-add-a-new-entry).

---

## A. Overview

### What is this folder, in one sentence?

It is the source-of-truth JSON that ships inside the app binary and is copied
into the device's local SQLite database the first time the app starts. The app
then reads the SQLite copy at runtime — never the JSON directly.

### How the data flows from JSON to the running app

If you are new to Flutter, the chain looks like this:

1. **At build time.** The `flutter:` section of `pubspec.yaml` lists
   `assets/seed_data/` as an asset path. When you run `flutter build` (or
   `flutter run`), the Flutter toolchain copies every file in this folder
   into the iOS `.app` bundle and the Android `.apk`/`.aab`. The files are
   read-only on the device; you cannot mutate them at runtime.
2. **At runtime.** On launch, `lib/main.dart` opens the on-device SQLite
   database (via the `drift` package) and then calls
   `SeedLoader.seedIfNeeded()` from `lib/database/seed_loader.dart`.
3. **Reading the JSON.** `SeedLoader` calls
   `rootBundle.loadString('assets/seed_data/<file>.json')` for each file,
   which returns the raw JSON text from the app bundle. `json.decode(...)`
   parses that text into Dart maps and lists.
4. **Writing to SQLite.** Each `_seedX()` method walks the parsed structure
   and emits batched `drift` inserts (one transaction wraps the whole
   thing) into the matching reference table:
   `Cartridges`, `Manufacturers`, `Powders`, `Bullets`, `Primers`,
   `BrassProducts`, `FirearmsRef`, `FirearmParts`. The schema for those
   tables lives in `lib/database/database.dart`.
5. **Reading from SQLite.** Every dropdown and lookup screen in the app
   reads from those tables via `lib/repositories/component_repository.dart`,
   `firearm_repository.dart`, etc. **The JSON files are never read again
   after seeding.**

### When does seeding run?

`seedIfNeeded()` checks three flags up front and bails out if all are false:

| Flag                    | True when                                                                                                     | Action                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `firstRun`              | The `Cartridges` table is empty (brand-new install).                                                          | Seed everything.                      |
| `cartridgesNeedReseed`  | "9mm Luger" exists but its `bodyDiameterIn` is `null` — i.e. the v2 SAAMI fields were added but never filled. | Wipe `Cartridges`, re-seed cartridges. |
| `primersMissing`        | The `Primers` table is empty — the v3 migration deliberately clears it so the new `productLine` column gets populated. | Re-seed primers.                       |

Each flag is a getter on `AppDatabase` (see `lib/database/database.dart`,
`needsSeed`, `cartridgesNeedReseed`, `primersAreEmpty`). The dispatch logic
is what lets us evolve seed shapes without nuking the user's loads.

### Who reads the seeded data after first launch?

- **Component dropdowns** in the recipe form (`lib/screens/recipes/`): powder,
  bullet, primer, brass.
- **Firearm form** (`lib/screens/firearms/`): manufacturer / model / action /
  caliber pickers built from `FirearmsRef`.
- **SAAMI screen** (`lib/screens/saami/`): cartridge picker plus the spec
  card showing case dimensions, twist rate, max average pressure, etc.
- **Ballistics calculator** (`lib/screens/ballistics/`): bullet picker
  populated from `Bullets` (uses `bcG1` / `bcG7` for trajectory math).
- **Glossary** (`lib/screens/glossary/`) and **load-development** flows
  consume cartridge data indirectly through the repositories.

### Why seed JSON into SQLite at all? Why not just read the JSON?

Two reasons:

1. **Real SQL queries.** Cascading dropdowns ("show me primers from
   manufacturer X with size Y") are easy in SQL and awkward in raw JSON.
2. **Local-first means no network.** The marketing promise is that LoadOut
   never sends your reloading data anywhere. Bundling the catalog and seeding
   it on first launch means the app is fully usable offline from the moment
   it opens — no API call, no sign-in required, no data download.

A user-added powder, bullet, primer, brass, or cartridge goes into the
separate `CustomComponents` table — never into these JSON files.

---

## B. Per-file schema reference

There are seven files. Five of them are shaped
`{ "manufacturers": [{ name, country, products: [...] }, ...] }`. Two are
exceptions:

- `cartridges.json` is a **flat array** (no manufacturer wrapper).
- `brass.json` puts product fields directly on the manufacturer (each
  manufacturer is itself one `BrassProducts` row, not a list of products).

All numeric fields use a unit suffix in the field name:

- `*In` — inches
- `*Gr` — grains (1 grain = 1/7000 lb)
- `*Deg` — degrees
- `*Psi` — pounds per square inch
- `*Fps` — feet per second (not used in seed data, but used elsewhere)

Use `null` (not the string `"null"`) for missing values. Use camelCase for
keys throughout — never snake_case.

---

### `cartridges.json` — the cartridge / shotshell catalog

| | |
| --- | --- |
| Top-level shape  | Flat JSON array `[ { ... }, { ... }, ... ]` |
| Drift table      | `Cartridges` (`lib/database/database.dart`)   |
| Approximate size | ~200+ rows spanning rifle, pistol, rimfire, and shotgun |
| Seed function    | `_seedCartridges()` in `lib/database/seed_loader.dart` |

Each row is a Map with the following fields. Most are nullable; only `name`
and `type` are always required.

| Field                 | Type                                | Units / values                                                          | Notes |
| --------------------- | ----------------------------------- | ----------------------------------------------------------------------- | ----- |
| `name`                | string (required, unique)           |                                                                          | Display name. The unique key on the `Cartridges` table. |
| `aliases`             | array of strings                    |                                                                          | Alternate names ("9x19mm Parabellum", "9mm NATO"). Stored JSON-encoded in the `aliasesJson` text column. |
| `type`                | string (required)                   | `"pistol"` / `"rifle"` / `"shotgun"`                                    | High-level category. Note: rimfire cartridges (`.22 LR`, `.17 HMR`) are typed as `"rifle"`. |
| `bulletDiameterIn`    | number, nullable                    | inches                                                                  | Land-to-land bullet diameter. |
| `caseLengthIn`        | number, nullable                    | inches                                                                  | Trim length (cartridges only). |
| `maxCoalIn`           | number, nullable                    | inches                                                                  | Max cartridge overall length per SAAMI. |
| `gauge`               | number, nullable                    | gauge number (12, 20, etc.)                                             | **Shotgun rows only.** `.410 Bore` uses 67.62 (its bore-diameter equivalent). |
| `shellLengthIn`       | number, nullable                    | inches                                                                  | **Shotgun rows only.** Length of fired hull (2.75", 3", 3.5", etc.). |
| `parentCase`          | string, nullable                    |                                                                          | Cartridge this was derived from (e.g. `.357 SIG` ← `.40 S&W`). `null` for original designs. |
| `yearIntroduced`      | integer, nullable                   |                                                                          | Year of public release. |
| `bodyDiameterIn`      | number, nullable                    | inches                                                                  | Case body diameter at .200" forward of the rim (the "0.200" reference plane). Added in schema v2. |
| `shoulderDiameterIn`  | number, nullable                    | inches                                                                  | Diameter of the shoulder, measured at the body-shoulder junction. `null` for straight-walled cases. |
| `shoulderAngleDeg`    | number, nullable                    | degrees, **SAAMI half-angle convention**                                | Wall-to-axis angle. **Important:** SAAMI publishes the half-angle (the angle between the case wall and the bore axis). CIP publishes the full included angle (δ). If you copy from a CIP datasheet, **divide by 2** before pasting here. `null` for straight-walled cases. |
| `neckDiameterIn`      | number, nullable                    | inches                                                                  | External diameter at the case mouth. |
| `neckLengthIn`        | number, nullable                    | inches                                                                  | Length of the neck section. `null` for straight-walled cases. |
| `baseToShoulderIn`    | number, nullable                    | inches                                                                  | Distance from case base to start of shoulder. |
| `baseToNeckIn`        | number, nullable                    | inches                                                                  | Distance from case base to start of neck (datum-line). |
| `rimDiameterIn`       | number, nullable                    | inches                                                                  | Outside diameter of the rim. |
| `rimThicknessIn`      | number, nullable                    | inches                                                                  | Axial thickness of the rim. |
| `primerType`          | string, nullable                    | `"small-pistol"` / `"large-pistol"` / `"small-rifle"` / `"large-rifle"` / `"berdan"` / `"rimfire"` | Required priming size for the cartridge. `null` allowed for non-standard. |
| `twistRate`           | string, nullable                    | e.g. `"1:8"`, `"1:9.45"`                                                | SAAMI-recommended barrel twist (one turn per N inches). |
| `maxAvgPressurePsi`   | integer, nullable                   | PSI                                                                     | Max average pressure (MAP) per the relevant SAAMI document. |
| `boreDiameterIn`      | number, nullable                    | inches                                                                  | Bore (land-to-land) diameter. |
| `grooveDiameterIn`    | number, nullable                    | inches                                                                  | Groove (land bottom to land bottom) diameter. |
| `caseSubtype`         | string, nullable                    | `"rimless-bottleneck"` / `"rimless-straight"` / `"rimmed-bottleneck"` / `"rimmed-straight"` / `"belted-bottleneck"` / `"belted-straight"` / `"rebated-bottleneck"` / `"rebated-straight"` | Geometric classification used by the SAAMI screen. |
| `saamiDoc`            | string, nullable                    | `"Z299.1"` (rimfire) / `"Z299.2"` (shotgun) / `"Z299.3"` (pistol/revolver) / `"Z299.4"` (centerfire rifle) / `null` | The SAAMI standard the entry was sourced from. `null` for cartridges with no SAAMI document (CIP-only, wildcat, or proprietary). |

Shotgun rows (`type: "shotgun"`) carry two extra fields, `shellMaterial` and
`chokeStandards`, that **are not currently mapped to Drift columns** — the
seed loader silently ignores them. They live in the JSON for completeness so
the file can grow into a richer shotgun schema later.

#### Examples

A bottlenecked rifle cartridge with full SAAMI dimensions:

```json
{
  "name": ".223 Remington",
  "aliases": [".223 Rem", "5.56x45mm"],
  "type": "rifle",
  "bulletDiameterIn": 0.224,
  "caseLengthIn": 1.76,
  "maxCoalIn": 2.26,
  "parentCase": null,
  "yearIntroduced": 1964,
  "bodyDiameterIn": 0.376,
  "shoulderDiameterIn": 0.354,
  "shoulderAngleDeg": 23,
  "neckDiameterIn": 0.253,
  "neckLengthIn": 0.203,
  "baseToShoulderIn": 1.467,
  "baseToNeckIn": 1.557,
  "rimDiameterIn": 0.378,
  "rimThicknessIn": 0.045,
  "primerType": "small-rifle",
  "twistRate": "1:8",
  "maxAvgPressurePsi": 55000,
  "boreDiameterIn": 0.219,
  "grooveDiameterIn": 0.224,
  "caseSubtype": "rimless-bottleneck",
  "saamiDoc": "Z299.4"
}
```

A shotgun shell (note the `gauge` + `shellLengthIn` instead of bullet/case
dimensions, and the extra `shellMaterial` / `chokeStandards` fields that
don't map to Drift):

```json
{
  "name": "12 Gauge 2-3/4\"",
  "aliases": ["12ga 2.75"],
  "type": "shotgun",
  "gauge": 12,
  "shellLengthIn": 2.75,
  "yearIntroduced": null,
  "shellMaterial": "plastic-hull-brass-base",
  "maxAvgPressurePsi": 11500,
  "boreDiameterIn": 0.725,
  "chokeStandards": ["cylinder", "skeet", "improved-cylinder", "modified", "full"],
  "saamiDoc": "Z299.2"
}
```

---

### `powders.json` — the smokeless powder catalog

| | |
| --- | --- |
| Top-level shape  | `{ "manufacturers": [ { name, country, products: [ ... ] } ] }` |
| Drift tables     | `Manufacturers` (kind = `"powder"`) and `Powders` |
| Seed function    | `_seedPowders()` |

Each manufacturer has these fields:

| Field      | Type    | Notes |
| ---------- | ------- | ----- |
| `name`     | string  | e.g. `"Hodgdon"`, `"Vihtavuori"`. The `(name, kind)` pair is unique. |
| `country`  | string, nullable | Country of origin. |
| `products` | array of products |  |

Each product becomes a `Powders` row:

| Field      | Type    | Values / units                                       | Notes |
| ---------- | ------- | ---------------------------------------------------- | ----- |
| `name`     | string  |                                                       | Powder name as printed on the label (e.g. `"Varget"`, `"H4350"`). |
| `type`     | string  | `"rifle"` / `"pistol"` / `"shotgun"` / `"multi"`     | Primary use case. `"multi"` covers powders that span categories. |
| `form`     | string, nullable | `"extruded"` / `"spherical"` / `"flake"`         | Grain geometry. |
| `burnRate` | string, nullable | `"fast"` / `"medium-fast"` / `"medium"` / `"medium-slow"` / `"slow"` / `"extra-slow"` | Relative burn rate. |
| `notes`    | string, nullable |                                                       | Free-form description (typical applications, position-sensitivity, etc.). |

#### Example

```json
{
  "name": "Hodgdon",
  "country": "USA",
  "products": [
    {
      "name": "Varget",
      "type": "rifle",
      "form": "extruded",
      "burnRate": "medium",
      "notes": "Highly popular for .308, .223, 6.5 Creedmoor"
    }
  ]
}
```

---

### `bullets.json` — the bullet (projectile) catalog

| | |
| --- | --- |
| Top-level shape  | `{ "manufacturers": [ { name, country, products: [ ... ] } ] }` |
| Drift tables     | `Manufacturers` (kind = `"bullet"`) and `Bullets` |
| Seed function    | `_seedBullets()` |

The manufacturer wrapper is the same as `powders.json`. Each product becomes
a `Bullets` row:

| Field         | Type             | Units / values                                           | Notes |
| ------------- | ---------------- | -------------------------------------------------------- | ----- |
| `line`        | string (required)|                                                           | Product line name (e.g. `"ELD-Match"`, `"V-MAX"`, `"MatchKing"`). |
| `diameterIn`  | number (required)| inches                                                    | Bullet diameter. |
| `weightGr`    | number (required)| grains                                                    | Bullet weight. |
| `design`      | string, nullable | `"polymer-tip"` / `"open-tip-match"` / `"FMJ"` / `"soft-point"` / `"boat-tail-soft-point"` / `"hollow-point"` etc. | Tip / nose shape. |
| `jacket`      | string, nullable | `"jacketed"` / `"monolithic-copper"` / `"plated"` etc.   | Jacket construction. |
| `application` | string, nullable | `"match"` / `"hunting"` / `"varmint"` / `"target"`       | Intended use. |
| `bcG1`        | number, nullable | unitless                                                  | Ballistic coefficient using the G1 drag model. |
| `bcG7`        | number, nullable | unitless                                                  | Ballistic coefficient using the G7 drag model (better for VLD/boat-tail match bullets). |
| `notes`       | string, nullable |                                                           | Free-form. |

#### Example

```json
{
  "line": "ELD-Match",
  "diameterIn": 0.264,
  "weightGr": 140,
  "design": "polymer-tip",
  "jacket": "jacketed",
  "application": "match",
  "bcG1": 0.610,
  "bcG7": 0.326,
  "notes": null
}
```

---

### `primers.json` — the primer catalog (with cascading-dropdown metadata)

| | |
| --- | --- |
| Top-level shape  | `{ "manufacturers": [ { name, country, products: [ ... ] } ] }` |
| Drift tables     | `Manufacturers` (kind = `"primer"`) and `Primers` |
| Seed function    | `_seedPrimers()` |

Each product becomes a `Primers` row:

| Field         | Type             | Values                                                   | Notes |
| ------------- | ---------------- | -------------------------------------------------------- | ----- |
| `name`        | string (required)|                                                           | Model number / code as printed on the box (e.g. `"GM205M"`, `"WLR"`, `"9.5M"`). |
| `size`        | string (required)| `"small-pistol"` / `"large-pistol"` / `"small-rifle"` / `"large-rifle"` / `"shotshell-209"` | Priming size. Drives the cascading filter from `cartridge.primerType` to the primer dropdown. |
| `magnum`      | bool             | defaults to `false`                                       | True for magnum-strength primers. |
| `grade`       | string, nullable | `"standard"` / `"match"` / `"benchrest"`                  | Quality grade. |
| `productLine` | string, nullable |                                                           | **Added in seed-data v3.** Manufacturer's marketing name for the family (e.g. `"Premium Gold Medal Small Rifle Match"`). Shown in the dropdown alongside the model code so non-experts can recognize what they're picking. Nullable to allow user-added primers to omit it. |
| `notes`       | string, nullable |                                                           | Free-form description. |

#### Example

```json
{
  "name": "GM205M",
  "size": "small-rifle",
  "magnum": false,
  "grade": "match",
  "productLine": "Premium Gold Medal Small Rifle Match",
  "notes": "Gold Medal Match small rifle primer with consistent ignition."
}
```

---

### `brass.json` — the brass-case catalog

| | |
| --- | --- |
| Top-level shape  | `{ "manufacturers": [ { name, country, tier, calibers, notes } ] }` |
| Drift tables     | `Manufacturers` (kind = `"brass"`) and `BrassProducts` |
| Seed function    | `_seedBrass()` |

**Important shape difference:** unlike `powders.json` / `bullets.json` /
`primers.json` / `firearms.json` / `firearm_parts.json`, brass entries do
**not** have a `products: [...]` array. Each manufacturer entry directly is
the product. This is because we treat each brass maker as offering one
"product" — their lineup of supported calibers — rather than tracking
individual SKUs per caliber.

Each manufacturer becomes one `BrassProducts` row plus one `Manufacturers`
row:

| Field      | Type             | Values                                                    | Notes |
| ---------- | ---------------- | --------------------------------------------------------- | ----- |
| `name`     | string           |                                                            | Manufacturer name (e.g. `"Lapua"`, `"ADG / Atlas Development Group"`). |
| `country`  | string, nullable |                                                            | Country of manufacture. |
| `tier`     | string, nullable | `"premium"` / `"match"` / `"standard"` / `"budget"` / `"refurbished"` | Quality tier — drives sort order and badging in the brass picker. |
| `calibers` | array of strings |                                                            | Calibers this maker offers. Stored JSON-encoded in `calibersJson`. |
| `notes`    | string, nullable |                                                            | Free-form (typical use cases, neck consistency reputation, etc.). |

#### Example

```json
{
  "name": "Lapua",
  "country": "Finland",
  "tier": "premium",
  "calibers": [".223 Rem", "6mm Creedmoor", "6.5 Creedmoor", ".308 Win"],
  "notes": "Reference-grade brass for precision shooting."
}
```

---

### `firearms.json` — the firearm reference catalog

| | |
| --- | --- |
| Top-level shape  | `{ "manufacturers": [ { name, country, category, products: [ ... ] } ] }` |
| Drift tables     | `Manufacturers` (kind = `"firearm"`) and `FirearmsRef` |
| Seed function    | `_seedFirearms()` |

Manufacturer fields:

| Field      | Type             | Values                                                       | Notes |
| ---------- | ---------------- | ------------------------------------------------------------ | ----- |
| `name`     | string           |                                                              | Manufacturer name. |
| `country`  | string, nullable |                                                              | Country of manufacture. |
| `category` | string, nullable | `"pistol"` / `"rifle"` / `"shotgun"` / `"multi"`             | High-level filter (currently informational only — not stored on the Drift row). |
| `products` | array of products |                                                              | |

Each product becomes a `FirearmsRef` row:

| Field      | Type             | Values                                                          | Notes |
| ---------- | ---------------- | --------------------------------------------------------------- | ----- |
| `model`    | string (required)|                                                                  | Model designation (e.g. `"G19 Gen 5"`, `"M&P15"`, `"700 ADL"`). |
| `type`     | string (required)| `"pistol"` / `"rifle"` / `"shotgun"`                            | High-level type. |
| `action`   | string, nullable | `"semi-auto"` / `"bolt-action"` / `"revolver"` / `"break-action"` / `"lever-action"` / `"pump-action"` etc. | Action type. |
| `calibers` | array of strings |                                                                  | Chamberings this model supports. Stored JSON-encoded in `calibersJson`. |
| `notes`    | string, nullable |                                                                  | Marketing-style description. |

#### Example

```json
{
  "name": "Glock",
  "country": "Austria",
  "category": "pistol",
  "products": [
    {
      "model": "G19 Gen 5",
      "type": "pistol",
      "action": "semi-auto",
      "calibers": ["9mm Luger"],
      "notes": "Compact carry/duty pistol, 15+1 capacity."
    }
  ]
}
```

---

### `firearm_parts.json` — the aftermarket parts catalog

| | |
| --- | --- |
| Top-level shape  | `{ "manufacturers": [ { name, country, categories, products: [ ... ] } ] }` |
| Drift tables     | `Manufacturers` (kind = `"parts"`) and `FirearmParts` |
| Seed function    | `_seedFirearmParts()` |

Manufacturer fields:

| Field        | Type             | Notes |
| ------------ | ---------------- | ----- |
| `name`       | string           | Manufacturer name (e.g. `"TriggerTech"`, `"Geissele Automatics"`). |
| `country`    | string, nullable | Country of manufacture. |
| `categories` | array of strings | Categories this maker covers (e.g. `["trigger", "rail", "scope-mount"]`). Currently informational only — not stored on the Drift row. |
| `products`   | array of products |  |

Each product becomes a `FirearmParts` row:

| Field            | Type             | Notes |
| ---------------- | ---------------- | ----- |
| `name`           | string (required)| Product name (e.g. `"Diamond Trigger - Remington 700"`). |
| `category`       | string (required)| `"trigger"` / `"rail"` / `"chassis"` / `"charging-handle"` / `"scope-mount"` / `"magazine"` etc. |
| `compatibleWith` | array of strings | Platforms / actions this part fits (e.g. `["Remington 700 footprint"]`, `["AR-15", "AR-10"]`). Stored JSON-encoded in `compatibleWithJson`. |
| `notes`          | string, nullable | Free-form description. |

#### Example

```json
{
  "name": "Diamond Trigger - Remington 700",
  "category": "trigger",
  "compatibleWith": ["Remington 700 footprint"],
  "notes": "Adjustable 1.5-4 lb pull, frictionless release."
}
```

---

## C. How to add a new entry

The general loop is: **edit JSON → relaunch the app** (and possibly wipe the
simulator's app data, depending on what you changed). You do not need to
regenerate Drift code — `database.dart` already declares the columns these
files map to. You only run `dart run build_runner build` if you change
`database.dart` itself.

### Add a new cartridge to `cartridges.json`

1. Append a new object to the top-level array. Mirror the shape of an
   existing entry of the same `type`.
2. Pick a unique `name`. The `Cartridges.name` column has a `UNIQUE`
   constraint — duplicates will throw on insert.
3. Set `saamiDoc` to the standard you sourced from (`Z299.4` for centerfire
   rifle, `Z299.3` for pistol/revolver, `Z299.2` for shotgun, `Z299.1` for
   rimfire) or `null` for CIP-only / wildcat / proprietary cartridges.
4. **If you also extended an existing cartridge with new dimensional data
   (the v2 fields):** the in-app `cartridgesNeedReseed` getter only spot-checks
   `9mm Luger`. If your edit doesn't touch `9mm Luger`, the app will not
   re-seed automatically. Wipe the simulator/device app data (or
   uninstall + reinstall) to force `firstRun` to be true.

### Add a new manufacturer

For `powders.json`, `bullets.json`, `primers.json`, `firearms.json`,
`firearm_parts.json`:

1. Append a new object to `manufacturers: [...]`.
2. Set `name` (must be unique within this `kind` — the
   `Manufacturers` table has a unique index on `(name, kind)`).
3. Add at least one entry to `products: [...]`.

For `brass.json`, append directly to `manufacturers: [...]` — there is no
`products` wrapper.

### Add a new primer with cascading-dropdown metadata

Always include the `productLine` field. The cascading dropdown shows it
alongside the model code, so omitting it leaves a blank line in the UI:

```json
{
  "name": "GM205M",
  "size": "small-rifle",
  "magnum": false,
  "grade": "match",
  "productLine": "Premium Gold Medal Small Rifle Match",
  "notes": "..."
}
```

### Update existing data

Editing an existing JSON entry **does not** automatically refresh what's in
SQLite on installs that have already seeded. The seed loader only runs when
one of the three flags (`firstRun` / `cartridgesNeedReseed` /
`primersMissing`) is true.

To pick up your edit during development:

- **Easiest:** delete and reinstall the app on the simulator/device so
  `firstRun` becomes true. On iOS Simulator: long-press app icon → Remove
  App. On Android: `adb uninstall com.johnsondigital.loadout`.
- **Alternative for cartridges:** ensure `9mm Luger` would have a `null`
  `bodyDiameterIn` after migration (this will rarely apply during normal
  development).
- **For shipping a real update to existing users:** add a new
  re-seed-detection getter on `AppDatabase` (mirroring
  `cartridgesNeedReseed` / `primersAreEmpty`), wire it into
  `SeedLoader.seedIfNeeded()`, and likely bump `schemaVersion` with a
  migration that wipes the affected reference table. See the v3 → v4
  primer rotation in `lib/database/database.dart` for the precedent.

---

## D. Conventions

- **Inches** for any linear dimension. Field name ends in `In`.
- **Grains** for projectile weight. Field name ends in `Gr`.
- **Degrees** for shoulder angles. Field name ends in `Deg`.
- **PSI** for pressure. Field name ends in `Psi`.
- **Shoulder angle is the SAAMI half-angle (wall-to-axis convention).** If
  you are copying from a CIP datasheet, divide the published δ (full
  included angle) by 2 before pasting it here.
- **camelCase keys** (e.g. `bulletDiameterIn`), never `snake_case` and never
  `kebab-case` for keys.
- **`null`** is the only null marker. Never write the string `"null"`.
- **Arrays of strings** (aliases, calibers, compatibleWith) are
  JSON-encoded into a `text` column at seed time. Decode with
  `json.decode(...) as List<dynamic>` at the repository boundary.

---

## E. Validation

There is no JSON schema file in this repo. The shape is enforced by:

1. The Dart cast operations in `lib/database/seed_loader.dart` (e.g.
   `m['name'] as String`, `(m['bulletDiameterIn'] as num?)?.toDouble()`).
   Mismatches throw at runtime on first launch.
2. The `UNIQUE` and `NOT NULL` constraints on the Drift tables in
   `lib/database/database.dart`. Violations surface as `SqliteException`
   on insert.

To check that your edits don't break the build:

```sh
flutter pub get
flutter analyze
```

`flutter analyze` will not parse the JSON for you — it only catches Dart
errors. To validate the JSON itself, run the app in a simulator with a
freshly installed (i.e. unseeded) state and watch for exceptions during
startup.
