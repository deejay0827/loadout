# Shipping a reference-catalog update without a store release

This document is the operations guide for getting a fix into the LoadOut
reference catalog (cartridges, powders, bullets, primers, brass,
firearms, parts) **without** waiting on App Store / Play Store review.
It is the deployment counterpart to the architecture write-up in
`lib/services/seed_updater.dart`.

If you only want to know how to add or correct a JSON entry, see
`assets/seed_data/README.md`. This guide picks up after that — once the
JSON file looks the way you want it, this is how you make it live.

---

## TL;DR

```text
edit assets/seed_data/<file>.json
bump assets/seed_data/manifest.json[<key>].version
upload <file>.json + manifest.json to Firebase Storage
done — users see the fix the next time they open the app
```

---

## How the system fits together

There are two copies of every seed JSON file:

| Location | Role |
| -------- | ---- |
| `assets/seed_data/<file>.json` | **Source of truth.** Bundled into every install. Edit here. |
| `gs://loadout-precision-reloading.firebasestorage.app/seed_data/<file>.json` | **Hot-fix copy.** Optional. Read by `SeedUpdater` on cold start. |

The bucket is also expected to contain `manifest.json` describing the
current version of each file. The bundled manifest at
`assets/seed_data/manifest.json` mirrors the same shape. On launch:

1. `SeedLoader.seedIfNeeded()` runs first and seeds whatever JSON it has
   (downloaded if available, bundled otherwise).
2. `SeedUpdater(db).checkForUpdates()` fires in the background. It
   pulls the bucket's `manifest.json`, compares each `version` against
   what the device has cached in `SharedPreferences` (default `1`), and
   downloads any file whose remote version is strictly higher.
3. If a download succeeds and the JSON validates, `SeedUpdater` writes it
   to `<applicationDocumentsDirectory>/seed_data/<filename>` and sets
   `seed_needs_reseed_<key> = true` in `SharedPreferences`.
4. On the **next** launch, `SeedLoader.seedIfNeeded()` notices the flag,
   reads the file from the documents directory, and re-seeds the
   matching Drift table. The re-seed is wrapped in a transaction.

A user therefore sees the new data on launch N+1 after the first launch
that downloaded it. We deliberately don't re-seed in the same launch
that downloaded the file — re-seeding is a synchronous transaction that
should run at startup, not in the background while the app is in use.

---

## Pre-flight checklist (one-time)

Before the very first deploy you need to:

1. **Enable Firebase Storage** in the Firebase Console for the
   `loadout-precision-reloading` project. Pick the same region as the
   rest of the project. Note the default bucket name; it should look
   like `loadout-precision-reloading.firebasestorage.app`.
2. **Deploy the storage rules** so unauthenticated installs can read
   `seed_data/*`:
   ```sh
   firebase deploy --only storage
   ```
   `storage.rules` and `firebase.json` are already wired up in this repo.
3. **Upload the initial set of JSON files** so the bucket exists and is
   discoverable:
   ```sh
   gsutil -m cp assets/seed_data/*.json \
     gs://loadout-precision-reloading.firebasestorage.app/seed_data/
   ```
   (`-m` parallelizes the upload across all 8 files plus the manifest.)
   You can also drag-drop the folder via the Firebase Console.

After this, the bucket should match `assets/seed_data/` exactly, and
running the app should produce no version drift on first launch.

---

## Routine deployment workflow

The day-to-day flow for shipping a fix:

### 1. Edit the JSON locally

Edit the appropriate file under `assets/seed_data/`. Follow the
conventions in `assets/seed_data/README.md` — same shapes, same field
names. Re-run the app on a simulator and verify the change shows up
(you may need to delete the simulator app to force a fresh seed; see
that README for tricks).

### 2. Bump the version in `assets/seed_data/manifest.json`

Open `assets/seed_data/manifest.json`. Find the entry for the file you
edited and increase its `version` by 1. Update `generated_at` to the
current UTC timestamp.

For example, after editing `cartridges.json`:

```diff
   "files": {
-    "cartridges":    {"version": 1, "filename": "cartridges.json"},
+    "cartridges":    {"version": 2, "filename": "cartridges.json"},
     "powders":       {"version": 1, "filename": "powders.json"},
```

The bundled `manifest.json` and the bucket's `manifest.json` should
always agree about every file's version — bumping both is the only way
to keep them in sync.

### 3. Upload the changed files to the bucket

Upload BOTH the changed JSON file AND the updated manifest. Order
matters slightly — upload the data file first, the manifest last. That
way, even if the manifest upload races with a user's launch, the data
file is already present:

```sh
# Replace cartridges with whatever you edited; always upload manifest last.
gsutil cp assets/seed_data/cartridges.json \
  gs://loadout-precision-reloading.firebasestorage.app/seed_data/cartridges.json

gsutil cp assets/seed_data/manifest.json \
  gs://loadout-precision-reloading.firebasestorage.app/seed_data/manifest.json
```

(Console alternative: navigate to `seed_data/` in Storage, click the file
to overwrite, choose the new local copy.)

### 4. Commit the source changes

`git add` the edited `assets/seed_data/<file>.json` AND
`assets/seed_data/manifest.json`, then commit with a message describing
the fix. The bundled JSON in new installs has to match what's in the
bucket; if you skip this step, every fresh install will see the old
data and then immediately be told "v2 is available, downloading…",
which is a worse experience than just shipping the fix in the bundle.

### 5. Verify

On a simulator with a clean install:

1. Open the app once. The bundled v1 data seeds. In the background,
   `SeedUpdater` notices remote version 2, downloads, and flags a
   re-seed.
2. Force-quit and reopen. `SeedLoader.seedIfNeeded()` re-seeds the
   table from the documents-directory copy. The fix should now be
   visible.
3. Reopen a third time to confirm it's stable (no perpetual re-seed
   loop).

---

## What happens on each device

| Scenario | Outcome |
| -------- | ------- |
| Brand-new install with network | Bundled JSON seeds first launch. `SeedUpdater` downloads any newer version of any file in the background. Next launch picks it up. |
| Brand-new install offline | Bundled JSON seeds. Background fetch silently fails. Next time the app runs with network, the fetch retries. |
| Existing install, version unchanged | `SeedUpdater` compares cached version to remote version, sees they match, does nothing. |
| Existing install, version bumped | `SeedUpdater` downloads, validates, writes to docs dir, flags re-seed. On next launch, the table is re-populated from the new file. |
| Remote version less than local (rollback) | Anti-downgrade kicks in. We do nothing. The user keeps the newer-than-bundled local copy. |
| Remote 404 | Logged. Local copy untouched. Bundled fallback is always present. |
| Remote JSON is malformed | Validation rejects it. Local copy untouched. Logged. |

---

## Operational guardrails

- **Never edit a JSON file directly in the bucket.** Always edit
  `assets/seed_data/<file>.json` locally, commit, and re-upload. The
  repo is the source of truth, and a bundled-vs-bucket drift will
  cause every fresh install to immediately download a "fix" that may
  not actually be one.
- **Always bump the manifest version when you change a file.** Without
  the bump, no client will pick up the new file. This is the easiest
  way to silently ship a fix that nobody sees.
- **Don't decrement a version.** Devices ignore decrements
  (anti-downgrade). If you need to roll back, **bump** to a new
  version that contains the rolled-back content.
- **Don't ship anything user-specific via this channel.** This is the
  shared reference catalog. It is the same JSON for every install. The
  privacy guarantee in `PRIVACY_POLICY.md` only holds because we don't
  upload anything from the device — keep that direction one-way.
- **Keep file size sane.** `SeedUpdater` caps any single download at
  8 MB, which is far above today's largest file. If you ever need to
  raise that, also raise the cap in `lib/services/seed_updater.dart`.

---

## File map

- `lib/services/seed_updater.dart` — the runtime that pulls updates.
- `lib/database/seed_loader.dart` — re-seeds the Drift tables from the
  cached / bundled JSON.
- `assets/seed_data/manifest.json` — bundled version manifest.
- `assets/seed_data/*.json` — bundled catalog files.
- `storage.rules` — bucket access policy.
- `firebase.json` — Firebase CLI config (now includes `storage`).
