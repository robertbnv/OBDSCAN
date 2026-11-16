"""Builds the compact fault-code assets bundled with the app.

Source: OBDex generic DTC dataset (CC0-1.0), https://github.com/foerbsnavi/OBDex
Download https://foerbsnavi.github.io/OBDex/generic.min.json and run:

    python -I tool/build_dtc_assets.py third_party/obdex/generic.min.json assets/dtc

Outputs:
  titles.json          {"P0420": ["english title", "german title"], ...}  (loaded at start-up)
  detail_<family>.json one file per code family (P0, P2, P3, U0, U3, B0, C0), loaded on demand:
      {"P0420": {"d": description, "c": [[cause, likelihood], ...], "s": [symptom, ...],
                 "r": [difficulty, diy_possible, cost_min_eur, cost_max_eur, hours_min, hours_max],
                 "f": [mil, emissions_relevant, drive_cycle_required, limp_mode_possible],
                 "x": [related codes]}}
"""
import json
import os
import re
import sys

CODE_RE = re.compile(r"^[PCBU][0-3][0-9A-F]{3}$")
LIKELIHOOD_ORDER = {"high": 0, "medium": 1, "low": 2}


def text(value, lang="en"):
    if isinstance(value, dict):
        value = value.get(lang) or value.get("en") or ""
    return value.strip() if isinstance(value, str) else ""


def pair(value):
    if isinstance(value, (list, tuple)) and len(value) == 2:
        return value[0], value[1]
    return None, None


def main(src, out_dir):
    with open(src, encoding="utf-8") as fh:
        entries = json.load(fh)

    titles = {}
    details = {}
    skipped = 0
    for entry in entries:
        code = str(entry.get("code", "")).upper()
        if not CODE_RE.match(code):
            skipped += 1
            continue
        title_en = text(entry.get("title"), "en")
        if not title_en:
            skipped += 1
            continue
        titles[code] = [title_en, text(entry.get("title"), "de")]

        causes = sorted(
            (c for c in entry.get("common_causes") or [] if text(c.get("label"))),
            key=lambda c: LIKELIHOOD_ORDER.get(c.get("likelihood"), 3),
        )
        repair = entry.get("repair") or {}
        cost_min, cost_max = pair(repair.get("estimated_cost_eur"))
        hours_min, hours_max = pair(repair.get("estimated_hours"))
        flags = entry.get("flags") or {}
        details.setdefault(code[:2], {})[code] = {
            "d": text(entry.get("description")),
            "c": [[text(c.get("label")), c.get("likelihood") or ""] for c in causes],
            "s": [text(s) for s in entry.get("symptoms") or [] if text(s)],
            "r": [repair.get("difficulty"), repair.get("diy_possible"), cost_min, cost_max, hours_min, hours_max],
            "f": [
                bool(flags.get("mil")),
                bool(flags.get("emissions_relevant")),
                bool(flags.get("drive_cycle_required")),
                bool(flags.get("limp_mode_possible")),
            ],
            "x": [c for c in entry.get("related_codes") or [] if isinstance(c, str) and CODE_RE.match(c)],
        }

    os.makedirs(out_dir, exist_ok=True)

    def dump(name, payload):
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        print(f"{name}: {os.path.getsize(path) / 1024:.0f} KiB, {len(payload)} codes")

    dump("titles.json", titles)
    for family, payload in sorted(details.items()):
        dump(f"detail_{family}.json", payload)
    print(f"total codes: {len(titles)}, skipped: {skipped}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: build_dtc_assets.py <generic.min.json> <output dir>")
    main(sys.argv[1], sys.argv[2])
