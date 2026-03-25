#!/usr/bin/env python3
import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path


def infer_type(term: str, explicit_type: str) -> str:
    cleaned = explicit_type.strip().lower()
    if cleaned:
        return cleaned
    if " " in term:
        return "phrase"
    return "unigram"


def load_rows(csv_path: Path) -> list[dict]:
    with csv_path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = [row for row in reader if row.get("term")]
    return rows


def build_trigger_payload(rows: list[dict], source_csv: Path, repo_root: Path) -> dict:
    deduped: dict[str, dict] = {}

    for row in rows:
        raw_term = row.get("term", "").strip()
        if not raw_term:
            continue

        term = " ".join(raw_term.split())
        lower_term = term.lower()

        try:
            score = float(row.get("score", "0"))
        except ValueError:
            score = 0.0

        trigger = {
            "term": lower_term,
            "type": infer_type(lower_term, row.get("type", "")),
            "score": score,
            "count_total": 1,
            "count_by_folder": {"general": 1},
        }

        existing = deduped.get(lower_term)
        if existing is None or trigger["score"] > existing["score"]:
            deduped[lower_term] = trigger

    triggers = sorted(
        deduped.values(),
        key=lambda item: (-item["score"], item["term"]),
    )

    try:
        source_csv_ref = str(source_csv.relative_to(repo_root))
    except ValueError:
        source_csv_ref = source_csv.name

    return {
        "metadata": {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "source_csv": source_csv_ref,
            "count": len(triggers),
            "description": "Public-safe generic trigger lexicon for Librarian.",
        },
        "triggers": triggers,
    }


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    default_input = root / "Resources" / "triggers" / "triggers-base.csv"
    default_output = root / "Resources" / "triggers" / "triggers-generated.json"

    parser = argparse.ArgumentParser(description="Build Librarian trigger JSON from CSV.")
    parser.add_argument("--input", default=str(default_input), help="Path to trigger CSV.")
    parser.add_argument("--output", default=str(default_output), help="Path to generated JSON.")
    args = parser.parse_args()

    input_path = Path(args.input).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    if not input_path.exists():
        raise SystemExit(f"Input CSV not found: {input_path}")

    rows = load_rows(input_path)
    payload = build_trigger_payload(rows, input_path, root)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {len(payload['triggers'])} triggers to {output_path}")


if __name__ == "__main__":
    main()
