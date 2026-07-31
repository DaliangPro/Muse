#!/usr/bin/env python3
"""Voice Polish V2 人工盲测准备与计分工具。"""

import argparse
import json
import random
from datetime import datetime, timezone
from pathlib import Path

BASELINE_COMMIT = "b81bce5"
ALLOWED_RATINGS = {"left", "right", "tie", "both_unusable"}


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(path)


def prepare(args):
    source = load_json(Path(args.input))
    samples = source["samples"] if isinstance(source, dict) else source
    if len(samples) < 30:
        raise ValueError("人工盲测至少需要 30 条样本")
    rng = random.Random(args.seed)
    public_samples = []
    key_samples = []
    seen = set()
    for sample in samples:
        sample_id = str(sample["id"])
        if sample_id in seen:
            raise ValueError(f"重复样本 ID: {sample_id}")
        seen.add(sample_id)
        new_on_left = bool(rng.getrandbits(1))
        legacy = str(sample["legacy_output"])
        new = str(sample["new_output"])
        public_samples.append({
            "id": sample_id,
            "input": str(sample.get("input", "")),
            "left": new if new_on_left else legacy,
            "right": legacy if new_on_left else new,
            "rating": None,
        })
        key_samples.append({"id": sample_id, "new_side": "left" if new_on_left else "right"})

    metadata = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "seed": args.seed,
        "baseline_commit": args.baseline_commit,
        "sample_count": len(samples),
        "rating_options": ["left", "right", "tie", "both_unusable"],
    }
    write_json(Path(args.output), {"metadata": metadata, "samples": public_samples})
    write_json(Path(args.key), {"metadata": metadata, "samples": key_samples})


def score(args):
    evaluation = load_json(Path(args.evaluation))
    key = load_json(Path(args.key))
    new_side_by_id = {item["id"]: item["new_side"] for item in key["samples"]}
    counts = {"new_win": 0, "legacy_win": 0, "tie": 0, "both_unusable": 0}
    missing = []
    for sample in evaluation["samples"]:
        sample_id = sample["id"]
        rating = sample.get("rating")
        if rating not in ALLOWED_RATINGS:
            missing.append(sample_id)
            continue
        if rating == "tie":
            counts["tie"] += 1
        elif rating == "both_unusable":
            counts["both_unusable"] += 1
        elif rating == new_side_by_id.get(sample_id):
            counts["new_win"] += 1
        else:
            counts["legacy_win"] += 1
    if missing:
        raise ValueError("以下样本尚未填写有效评分: " + ", ".join(missing))
    total = sum(counts.values())
    new_win_or_tie_rate = (counts["new_win"] + counts["tie"]) / total if total else 0
    report = {
        "schema_version": 1,
        "scored_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": key["metadata"]["baseline_commit"],
        "sample_count": total,
        "counts": counts,
        "new_win_or_tie_rate": new_win_or_tie_rate,
        "target": 0.85,
        "product_ready": total >= 30 and new_win_or_tie_rate >= 0.85,
    }
    write_json(Path(args.output), report)


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--input", required=True)
    prepare_parser.add_argument("--output", required=True)
    prepare_parser.add_argument("--key", required=True)
    prepare_parser.add_argument("--seed", type=int, default=20260731)
    prepare_parser.add_argument("--baseline-commit", default=BASELINE_COMMIT)
    prepare_parser.set_defaults(function=prepare)

    score_parser = commands.add_parser("score")
    score_parser.add_argument("--evaluation", required=True)
    score_parser.add_argument("--key", required=True)
    score_parser.add_argument("--output", required=True)
    score_parser.set_defaults(function=score)
    return root


if __name__ == "__main__":
    arguments = parser().parse_args()
    arguments.function(arguments)
