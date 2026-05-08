#!/usr/bin/env python3
"""Scrape Hornady 4DOF Cd-vs-Mach drag tables from the live API.

Hornady's 4DOF web calculator is a Blazor WebAssembly app served at
``https://www.hornady.com/4dof`` that proxies into an iframe at
``hornadyfourdofiframeprod.azurewebsites.net``. The iframe in turn
talks to a publicly-readable Azure Mobile App backend at
``hornadyapiprod.azurewebsites.net`` which exposes the full bullet
database — including the per-bullet ``machNumber`` / ``zeroYawDrag``
arrays that Hornady measured on Doppler radar.

The endpoint requires only a ``ZUMO-API-VERSION: 2.0.0`` header (the
standard Azure Mobile App identifier) and is OData-flavoured, so we
paginate with ``$skip`` + ``$inlinecount=allpages``.

Schema (one row per bullet):
    id, name, shortName, weight (grains),
    boreDiameter (inches, the BORE not the bullet),
    referenceDiameter (METERS, the actual bullet body diameter),
    is4Dof (bool — only ``True`` rows have populated drag arrays),
    machNumber  -> JSON-string array of ~30 Mach values,
    zeroYawDrag -> JSON-string array of ~30 Cd values, paired by index.
    Plus Magnus / pitching / yaw moments we ignore — only zero-yaw
    drag (the dominant decelerating force in flight) feeds the
    LoadOut solver's `CustomDragCurve`.

This produces a JSON file matching the existing CDM file shape used
by `seed_loader.dart`. Each entry includes manufacturer attribution
per Hornady's likely TOS.

Usage::

    python3 tool/scrape_hornady_4dof.py \\
        --output assets/seed_data/drag_curves/curves.json

Re-running the script is idempotent — Hornady's data only updates
when they post a new measurement. The API returns the same rows in
the same order across runs.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_HOST = "https://hornadyapiprod.azurewebsites.net"
API_HEADERS = {
    "ZUMO-API-VERSION": "2.0.0",
    "User-Agent": "LoadOut-DragCurveScraper/1.0 (+https://github.com/loadout)",
    "Accept": "application/json",
}
PAGE_SIZE = 50  # the server caps at 50 per request

# CompanyId -> manufacturer name. Discovered by looking at the ``name``
# field, which always starts with the brand. We pin the mapping so a
# missing company link still resolves correctly.
COMPANY_MAP = {
    "acb29c93-49e2-415e-a3c1-f50d95a1de16": "Hornady",
    "08e581fc-": "Berger",  # B... prefix
    "fdd4daa8-": "Sierra",  # S suffix
    "e438a888-": "Nosler",  # N suffix / RDF line
    "f6ff9c13-": "Warner Tool",  # FLATLINE / W suffix
    "cc29c9a9-": "Lapua",  # SCENAR
    "d10f05ba-": "Berger",  # MB Match Burner
    "5027a2cd-": "Cutting Edge",  # MG prefix
    "001b695a-": "Custom",
    "a2150a32-": "Custom",
}


def http_get_json(url: str, *, timeout: float = 20.0) -> dict | list:
    """GET ``url`` with the Hornady headers and return parsed JSON."""
    req = urllib.request.Request(url, headers=API_HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def fetch_categories() -> dict[str, str]:
    """Return ``categoryId -> displayName`` for every bullet category.

    We use this to label curves with "ELD Match", "ELD-X", "A-TIP", etc.
    rather than the cryptic shortName (`6.5ELDM140H`).
    """
    cats: dict[str, str] = {}
    skip = 0
    while True:
        url = f"{API_HOST}/api/Category?$skip={skip}&$inlinecount=allpages"
        d = http_get_json(url)
        rows = d.get("results", []) if isinstance(d, dict) else []
        if not rows:
            break
        new = 0
        for r in rows:
            if r["id"] not in cats:
                cats[r["id"]] = r["name"]
                new += 1
        if new == 0:
            break
        skip += PAGE_SIZE
        if skip > 1000:
            break
        time.sleep(0.1)
    return cats


def fetch_all_bullets() -> list[dict]:
    """Walk the paged ``/api/Bullet`` endpoint and return every row."""
    out: list[dict] = []
    seen_ids: set[str] = set()
    skip = 0
    total = None
    while True:
        url = f"{API_HOST}/api/Bullet?$skip={skip}&$inlinecount=allpages"
        try:
            d = http_get_json(url)
        except urllib.error.HTTPError as e:
            sys.stderr.write(f"  HTTP {e.code} at skip={skip}: {e}\n")
            break
        rows = d.get("results", []) if isinstance(d, dict) else []
        if total is None and isinstance(d, dict):
            total = d.get("count")
            if total:
                sys.stderr.write(f"  Server reports {total} total bullets\n")
        if not rows:
            break
        added = 0
        for r in rows:
            if r["id"] not in seen_ids:
                seen_ids.add(r["id"])
                out.append(r)
                added += 1
        if added == 0:
            break
        skip += PAGE_SIZE
        sys.stderr.write(f"  fetched skip={skip} ({len(out)} rows so far)\n")
        if skip > 1500:
            sys.stderr.write("  safety break at skip=1500\n")
            break
        time.sleep(0.15)
    return out


_BRAND_PREFIXES: list[tuple[str, str]] = [
    # Match longest prefix first.
    ("WARNER TOOL", "Warner Tool"),
    ("CUTTING EDGE", "Cutting Edge"),
    ("FORT SCOTT", "Fort Scott"),
    ("HORNADY", "Hornady"),
    ("BERGER", "Berger"),
    ("SIERRA", "Sierra"),
    ("NOSLER", "Nosler"),
    ("LAPUA", "Lapua"),
    ("BARNES", "Barnes"),
    ("HAMMER", "Hammer"),
    ("MCGUIRE", "McGuire"),
    ("FEDERAL", "Federal"),
    ("HOTTENSTEIN", "Hottenstein"),
    ("ARROWHEAD", "Arrowhead"),
    ("CHEYTAC", "CheyTac"),
    ("TUBB", "Tubb"),
    ("DTAC", "DTAC"),
    ("NORMA", "Norma"),
    ("PVA", "PVA"),
    ("MK211", "Raufoss"),
]
# Brand keywords that may appear later in the ``name`` (e.g.
# rimfire ammo where the first word is the cartridge: "22 LR 40 GR
# CCI MINI MAG"). Order matters — match the most specific brand first.
_BRAND_KEYWORDS: list[tuple[str, str]] = [
    ("CCI", "CCI"),
    ("ELEY", "Eley"),
    ("REMINGTON", "Remington"),
    ("AGUILA", "Aguila"),
    ("WINCHESTER", "Winchester"),
    ("FEDERAL", "Federal"),
    ("LAPUA", "Lapua"),
    ("NORMA", "Norma"),
    ("RWS", "RWS"),
    ("SK ", "SK"),
]


def manufacturer_for(bullet: dict) -> str:
    """Resolve the bullet manufacturer name.

    The 4DOF API ``name`` field usually starts with the brand
    ("HORNADY 6.5 MM 140 GR ELD MATCH", "BERGER 6 MM 109 GR
    TARGET HYBRID MRT"). For rimfire / niche entries that aren't
    a consumer SKU, the brand often appears later in the name
    ("22 LR 40 GR CCI MINI MAG"). Fall back to the
    ``companyId`` lookup if neither pattern matches.
    """
    name = (bullet.get("name") or "").strip().upper()
    if not name:
        return COMPANY_MAP.get(bullet.get("companyId", ""), "Unknown")
    for prefix, label in _BRAND_PREFIXES:
        if name.startswith(prefix):
            return label
    for keyword, label in _BRAND_KEYWORDS:
        if keyword in name:
            return label
    # Codenamed turner bullets (X331…X349, AB97, AC50, etc.) are
    # typically PRS-community handmade jacket-and-core projects.
    # Group them under "Custom".
    head = name.split()[0]
    if head.startswith(("X3", "X4", "AB", "AC", "MG", "L4", "BH", "RMR", "AAR")):
        return "Custom"
    if head.isdigit() or head[:1].isdigit():
        return "Custom"
    return head.title() if head.isupper() else head


def line_for(bullet: dict, categories: dict[str, str]) -> str:
    """Resolve the bullet line / family name.

    Hornady categorises bullets ("ELD Match", "ELD-X", "A-TIP",
    "CX", ...). We use that as the line. If the categoryId isn't
    in the lookup table we fall back to the shortName.
    """
    cat = categories.get(bullet.get("categoryId", ""), "").strip()
    if cat:
        # Tidy: "BTHP Match" → "BTHP", keep single-word names.
        return cat.replace("ELD Match", "ELD-Match")
    sn = (bullet.get("shortName") or "").strip()
    return sn or "Unknown"


def diameter_in(bullet: dict) -> float | None:
    """Bullet body diameter in inches.

    The 4DOF API stores ``referenceDiameter`` in METERS for the
    actual bullet body. ``boreDiameter`` is the BORE diameter,
    consistently 0.001–0.008" smaller than the bullet (.256" bore
    for a .264" 6.5mm bullet, .300" bore for a .308" .30 bullet,
    etc.). The solver wants the bullet diameter, so prefer
    ``referenceDiameter``.
    """
    rd = bullet.get("referenceDiameter")
    if rd and rd > 0:
        return round(rd / 0.0254, 4)
    bd = bullet.get("boreDiameter")
    if bd:
        # Fall back to bore + 0.008" — close enough for the
        # 0.0015" loose-match in factory_load_repository.
        return round(bd + 0.008, 4)
    return None


def to_cdm_entry(bullet: dict, categories: dict[str, str]) -> dict | None:
    """Convert one Hornady bullet record to a curves.json entry."""
    if not bullet.get("is4Dof"):
        return None
    # Skip soft-deleted rows. Hornady's DB has historical / pre-rework
    # records (e.g. test profiles like "Aaron's super duper custom drag
    # profile of awesomeness") that linger as ``deleted=True`` and
    # would otherwise pollute the curve catalog.
    if bullet.get("deleted"):
        return None
    # Skip private rows. Public bullet curves have ``allowAllUsers=True``;
    # anything else is a per-user / per-group custom profile.
    if not bullet.get("allowAllUsers", False):
        return None
    # Skip explicitly-marked test profiles (Hornady's QA fixtures
    # like ``HORNADY TEST ALPHA`` and ``HORNADY 6.5 TEST 123`` are
    # public+is4Dof but obviously not real bullets).
    name_upper = (bullet.get("name") or "").upper()
    short_upper = (bullet.get("shortName") or "").upper()
    if " TEST " in f" {name_upper} " or " TEST " in f" {short_upper} ":
        return None
    if name_upper.startswith("PROTO") or name_upper.startswith("HORNADY TEST"):
        return None
    raw_mach = bullet.get("machNumber")
    raw_cd = bullet.get("zeroYawDrag")
    if not raw_mach or not raw_cd:
        return None
    try:
        mach_arr = json.loads(raw_mach)
        cd_arr = json.loads(raw_cd)
    except (TypeError, json.JSONDecodeError):
        return None
    if not mach_arr or not cd_arr or len(mach_arr) != len(cd_arr):
        return None

    weight = bullet.get("weight")
    if weight is None or weight <= 0:
        return None
    diam = diameter_in(bullet)
    if diam is None:
        return None
    mfg = manufacturer_for(bullet)
    line = line_for(bullet, categories)

    # Build the (mach, cd) datapoints. Ensure strictly positive, finite,
    # and sorted ascending by Mach (the LoadOut seed loader rejects
    # otherwise; PCHIP also wants ascending order).
    pairs = []
    for m, c in zip(mach_arr, cd_arr):
        try:
            mf = float(m)
            cf = float(c)
        except (TypeError, ValueError):
            continue
        if mf < 0 or cf <= 0:
            continue
        if not (mf == mf and cf == cf):  # NaN check
            continue
        pairs.append((round(mf, 4), round(cf, 6)))
    pairs.sort(key=lambda p: p[0])
    if len(pairs) < 5:
        return None

    short_name = (bullet.get("shortName") or "").strip()
    name_full = (bullet.get("name") or "").strip()
    weight_str = (
        f"{int(weight)}" if float(weight).is_integer() else f"{weight:.1f}"
    )
    # Diameter label for the picker UI: "6.5mm" for 0.264, ".30" for 0.308,
    # etc. Best-effort — we look up the most-common cartridge convention.
    cal_label = _diameter_to_caliber_label(diam)

    # Display name pattern matches the existing template / DragCurveRow
    # display label format: "<Manufacturer> <Caliber> <Weight>gr <Line>".
    # The "Hornady 4DOF" attribution lives in the `source` column instead.
    # That keeps a Berger Hybrid bullet whose curve was measured on
    # Hornady's Doppler labelled "Berger" rather than "Hornady".
    display_name = f"{mfg} {cal_label} {weight_str}gr {line}"
    # Sluggable id: lowercase, alphanum + underscore.
    sku_part = bullet.get("sku") or short_name or bullet["id"][:8]
    slug_id = (
        f"hornady_4dof_{cal_label.replace('.','').replace(' ','').lower()}"
        f"_{int(weight) if float(weight).is_integer() else weight_str.replace('.','p')}"
        f"_{line.replace(' ','').replace('-','').lower()}"
        f"_{sku_part.lower().replace(' ','').replace('/','_')}"
    )
    # Drop any non-alphanumeric/underscore chars from the slug.
    slug_id = "".join(c if c.isalnum() or c == "_" else "_" for c in slug_id)
    while "__" in slug_id:
        slug_id = slug_id.replace("__", "_")
    slug_id = slug_id.strip("_")

    bullet_ref = name_full if name_full else f"{mfg} {line} {weight_str}gr"
    return {
        "id": slug_id,
        "name": display_name,
        "displayName": display_name,
        "bulletReference": bullet_ref,
        "manufacturer": mfg,
        "line": line,
        "weight_gr": float(weight),
        "diameter_in": diam,
        "source": "Hornady 4DOF — measured Cd vs Mach (Doppler radar)",
        "notes": (
            "Real Hornady 4DOF drag curve. Drag table courtesy of Hornady."
        ),
        "datapoints": [{"mach": m, "cd": c} for (m, c) in pairs],
    }


def _diameter_to_caliber_label(diam: float) -> str:
    """Map a bullet diameter (inches) to a colloquial caliber label.

    Used purely for display (the solver doesn't read this). The bands
    follow common reloading-community usage so a 0.264" bullet shows
    "6.5mm", a 0.308" bullet shows ".30", etc.
    """
    bands = [
        (0.172, 0.174, ".17"),
        (0.204, 0.206, ".20"),
        (0.220, 0.225, ".224"),
        (0.235, 0.245, "6mm"),
        (0.246, 0.258, ".25"),  # .25 cal is 0.257"
        (0.262, 0.266, "6.5mm"),  # 6.5mm is 0.264"
        (0.275, 0.279, ".277"),  # .270 Win / .277 Fury / 6.8 SPC
        (0.283, 0.285, "7mm"),  # 7mm is 0.284"
        (0.298, 0.310, ".30"),
        (0.327, 0.340, ".338"),
        (0.357, 0.358, ".357"),
        (0.366, 0.376, ".375"),
        (0.402, 0.412, ".416"),
        (0.428, 0.460, ".45"),
        (0.495, 0.515, ".50"),
    ]
    for lo, hi, label in bands:
        if lo <= diam <= hi:
            return label
    # Fallback: print the inches.
    return f"{diam:.3f}”"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("assets/seed_data/drag_curves/curves.json"),
        help="Path to write the JSON output to.",
    )
    parser.add_argument(
        "--cache",
        type=Path,
        default=None,
        help="Cache the raw API response here (debugging).",
    )
    args = parser.parse_args(argv)

    sys.stderr.write("Fetching categories…\n")
    cats = fetch_categories()
    sys.stderr.write(f"  got {len(cats)} categories\n")

    sys.stderr.write("Fetching bullets (paged)…\n")
    bullets = fetch_all_bullets()
    sys.stderr.write(f"  got {len(bullets)} bullets total\n")

    if args.cache:
        args.cache.parent.mkdir(parents=True, exist_ok=True)
        args.cache.write_text(json.dumps(bullets, indent=2))
        sys.stderr.write(f"  cached raw bullets to {args.cache}\n")

    entries: list[dict] = []
    for b in bullets:
        e = to_cdm_entry(b, cats)
        if e is not None:
            entries.append(e)
    sys.stderr.write(f"  produced {len(entries)} 4DOF curves with valid drag tables\n")

    # Sort by manufacturer / diameter / weight for deterministic output.
    entries.sort(
        key=lambda e: (
            e["manufacturer"].lower(),
            e["diameter_in"],
            e["weight_gr"],
            e["line"].lower(),
            e["id"],
        )
    )

    # Deduplicate by id — the API has a few duplicate-by-shortName rows
    # (different SKUs of the same physical bullet).
    seen_ids: set[str] = set()
    deduped: list[dict] = []
    for e in entries:
        if e["id"] in seen_ids:
            continue
        seen_ids.add(e["id"])
        deduped.append(e)
    if len(deduped) != len(entries):
        sys.stderr.write(
            f"  deduplicated {len(entries) - len(deduped)} duplicate ids\n"
        )

    # Top-level shape mirrors curves.json so the seed loader can read
    # this file with the same parser.
    out_obj = {
        "_comment": (
            "Real Hornady 4DOF measured Cd-vs-Mach tables. Scraped from "
            "https://hornadyapiprod.azurewebsites.net/api/Bullet via "
            "tool/scrape_hornady_4dof.py. Re-run the script to refresh "
            "when Hornady updates their database. Drag curves are the "
            "property of Hornady Manufacturing."
        ),
        "_source": "https://4dof.hornady.com / hornadyapiprod.azurewebsites.net",
        "_scraped_via": "tool/scrape_hornady_4dof.py",
        "curves": deduped,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(out_obj, indent=2) + "\n")
    sys.stderr.write(f"Wrote {len(deduped)} curves to {args.output}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
