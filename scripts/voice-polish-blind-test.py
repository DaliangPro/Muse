#!/usr/bin/env python3
"""Muse Voice Polish 与 Typeless 同音频人工盲测准备与计分工具。"""

import argparse
import json
import random
from datetime import datetime, timezone
import math
from pathlib import Path

MINIMUM_SAMPLE_COUNT = 100
ALLOWED_RATINGS = {"left", "right", "tie", "both_unusable"}
RATING_DIMENSIONS = (
    "overall",
    "writing_quality",
    "terminology",
    "fact_preservation",
    "sendability",
)
REQUIRED_MUSE_METRICS = {
    "latency_ms",
    "route",
    "call_count",
    "repair_used",
    "fallback_used",
    "confirmed_alias_total",
    "confirmed_alias_correct",
    "critical_fact_total",
    "critical_fact_preserved",
    "whitelist_hallucination_count",
}


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
    if len(samples) < MINIMUM_SAMPLE_COUNT:
        raise ValueError(f"同音频人工盲测至少需要 {MINIMUM_SAMPLE_COUNT} 条样本")
    rng = random.Random(args.seed)
    public_samples = []
    key_samples = []
    seen = set()
    for sample in samples:
        sample_id = str(sample["id"])
        if sample_id in seen:
            raise ValueError(f"重复样本 ID: {sample_id}")
        seen.add(sample_id)
        muse_on_left = bool(rng.getrandbits(1))
        muse = str(sample.get("muse_output", sample.get("new_output", "")))
        typeless = str(sample.get("typeless_output", sample.get("legacy_output", "")))
        if not muse or not typeless:
            raise ValueError(f"样本 {sample_id} 缺少 muse_output 或 typeless_output")
        public_samples.append({
            "id": sample_id,
            "audio_ref": str(sample.get("audio_ref", "")),
            "category": str(sample.get("category", "")),
            "reference_transcript": str(sample.get("reference_transcript", sample.get("input", ""))),
            "left": muse if muse_on_left else typeless,
            "right": typeless if muse_on_left else muse,
            "ratings": {dimension: None for dimension in RATING_DIMENSIONS},
        })
        key_samples.append({
            "id": sample_id,
            "muse_side": "left" if muse_on_left else "right",
            "muse_metrics": sample.get("muse_metrics"),
            "typeless_latency_ms": sample.get("typeless_latency_ms"),
        })

    metadata = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "seed": args.seed,
        "baseline_commit": args.baseline_commit,
        "sample_count": len(samples),
        "rating_options": ["left", "right", "tie", "both_unusable"],
        "rating_dimensions": list(RATING_DIMENSIONS),
        "comparison": "Muse Voice Polish vs Typeless（同一音频、匿名随机左右）",
    }
    write_json(Path(args.output), {"metadata": metadata, "samples": public_samples})
    write_json(Path(args.key), {"metadata": metadata, "samples": key_samples})


def score(args):
    evaluation = load_json(Path(args.evaluation))
    key = load_json(Path(args.key))
    key_by_id = {item["id"]: item for item in key["samples"]}
    counts_by_dimension = {
        dimension: {"muse_win": 0, "typeless_win": 0, "tie": 0, "both_unusable": 0}
        for dimension in RATING_DIMENSIONS
    }
    missing = []
    for sample in evaluation["samples"]:
        sample_id = sample["id"]
        ratings = sample.get("ratings") or {}
        muse_side = (key_by_id.get(sample_id) or {}).get("muse_side")
        for dimension in RATING_DIMENSIONS:
            rating = ratings.get(dimension)
            if rating not in ALLOWED_RATINGS or muse_side not in {"left", "right"}:
                missing.append(f"{sample_id}:{dimension}")
                continue
            if rating == "tie":
                counts_by_dimension[dimension]["tie"] += 1
            elif rating == "both_unusable":
                counts_by_dimension[dimension]["both_unusable"] += 1
            elif rating == muse_side:
                counts_by_dimension[dimension]["muse_win"] += 1
            else:
                counts_by_dimension[dimension]["typeless_win"] += 1
    if missing:
        raise ValueError("以下样本尚未填写有效评分: " + ", ".join(missing))

    dimension_reports = {}
    for dimension, counts in counts_by_dimension.items():
        total = sum(counts.values())
        dimension_reports[dimension] = {
            "counts": counts,
            "muse_win_or_tie_rate": ratio(counts["muse_win"] + counts["tie"], total),
            "muse_loss_rate": ratio(counts["typeless_win"], total),
            "both_unusable_rate": ratio(counts["both_unusable"], total),
        }

    metrics = engineering_metrics(key["samples"])
    total = sum(counts_by_dimension["overall"].values())
    overall = dimension_reports["overall"]
    manual_gate = (
        total >= MINIMUM_SAMPLE_COUNT
        and overall["muse_win_or_tie_rate"] >= 0.85
        and overall["muse_loss_rate"] <= 0.15
        and overall["both_unusable_rate"] <= 0.01
    )
    engineering_gate = metrics["complete"] and all((
        metrics["confirmed_alias_correction_rate"] == 1.0,
        metrics["whitelist_hallucination_count"] == 0,
        metrics["critical_fact_retention_rate"] == 1.0,
        metrics["single_call_rate"] >= 0.85,
        metrics["repair_rate"] <= 0.02,
        metrics["fallback_rate"] <= 0.01,
        metrics["latency_targets_passed"],
    ))
    report = {
        "schema_version": 2,
        "scored_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": key["metadata"]["baseline_commit"],
        "sample_count": total,
        "dimensions": dimension_reports,
        "engineering_metrics": metrics,
        "targets": {
            "minimum_samples": MINIMUM_SAMPLE_COUNT,
            "muse_win_or_tie_rate": 0.85,
            "maximum_muse_loss_rate": 0.15,
            "maximum_both_unusable_rate": 0.01,
        },
        "manual_gate_passed": manual_gate,
        "engineering_gate_passed": engineering_gate,
        "product_ready": manual_gate and engineering_gate,
    }
    write_json(Path(args.output), report)


def ratio(numerator, denominator):
    return numerator / denominator if denominator else 0


def percentile(values, probability):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * probability) - 1))
    return ordered[index]


def engineering_metrics(key_samples):
    complete = True
    muse_metrics = []
    typeless_latencies = []
    for sample in key_samples:
        item = sample.get("muse_metrics")
        if not isinstance(item, dict) or not REQUIRED_MUSE_METRICS.issubset(item):
            complete = False
            continue
        if not isinstance(sample.get("typeless_latency_ms"), (int, float)):
            complete = False
        else:
            typeless_latencies.append(sample["typeless_latency_ms"])
        muse_metrics.append(item)

    alias_total = sum(item["confirmed_alias_total"] for item in muse_metrics)
    alias_correct = sum(item["confirmed_alias_correct"] for item in muse_metrics)
    fact_total = sum(item["critical_fact_total"] for item in muse_metrics)
    fact_preserved = sum(item["critical_fact_preserved"] for item in muse_metrics)
    if alias_total <= 0 or fact_total <= 0 or len(muse_metrics) != len(key_samples):
        complete = False

    latency_by_route = {}
    latency_targets_passed = complete
    latency_targets = {
        "fast": {"p50": 1_500, "p95": 3_000},
        "structured": {"p50": 2_500, "p95": 5_000},
        "deep": {"p50": 5_000, "p95": 8_000},
    }
    for route, targets in latency_targets.items():
        values = [item["latency_ms"] for item in muse_metrics if item["route"] == route]
        p50 = percentile(values, 0.50)
        p95 = percentile(values, 0.95)
        passed = p50 is None or (p50 <= targets["p50"] and p95 <= targets["p95"])
        latency_targets_passed = latency_targets_passed and passed
        latency_by_route[route] = {
            "sample_count": len(values),
            "p50_ms": p50,
            "p95_ms": p95,
            "target_p50_ms": targets["p50"],
            "target_p95_ms": targets["p95"],
            "passed": passed,
        }

    count = len(muse_metrics)
    return {
        "complete": complete,
        "confirmed_alias_correction_rate": ratio(alias_correct, alias_total),
        "whitelist_hallucination_count": sum(
            item["whitelist_hallucination_count"] for item in muse_metrics
        ),
        "critical_fact_retention_rate": ratio(fact_preserved, fact_total),
        "single_call_rate": ratio(sum(item["call_count"] == 1 for item in muse_metrics), count),
        "repair_rate": ratio(sum(bool(item["repair_used"]) for item in muse_metrics), count),
        "fallback_rate": ratio(sum(bool(item["fallback_used"]) for item in muse_metrics), count),
        "latency_by_route": latency_by_route,
        "latency_targets_passed": latency_targets_passed,
        "typeless_latency_p50_ms": percentile(typeless_latencies, 0.50),
        "typeless_latency_p95_ms": percentile(typeless_latencies, 0.95),
    }


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--input", required=True)
    prepare_parser.add_argument("--output", required=True)
    prepare_parser.add_argument("--key", required=True)
    prepare_parser.add_argument("--seed", type=int, default=20260731)
    prepare_parser.add_argument("--baseline-commit", required=True)
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
