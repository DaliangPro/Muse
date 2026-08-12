#!/usr/bin/env python3
"""校验 Muse 语音润色产品质量测试集的结构、覆盖和记录模板。"""

from __future__ import annotations

import csv
import json
from collections import Counter
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_PATH = PROJECT_ROOT / "docs/2026-08-12-Muse-Voice-Polish-Quality-Test-Set.json"
BASE_RUN_PATH = PROJECT_ROOT / "docs/2026-08-12-Muse-Voice-Polish-Quality-Test-Run-Template.csv"
STRESS_RUN_PATH = PROJECT_ROOT / "docs/2026-08-12-Muse-Voice-Polish-Stress-Variant-Run-Template.csv"

REQUIRED_BLIND_CATEGORIES = {
    "proper_noun",
    "self_correction",
    "aside",
    "disordered",
    "list",
    "numbers",
    "mixed_language",
    "ai_prompt",
}
REQUIRED_CASE_FIELDS = {
    "id",
    "scenario_group",
    "writing_scene",
    "title",
    "difficulty",
    "challenge_tags",
    "blind_categories",
    "spoken_input",
    "reference_output",
    "must_preserve",
    "must_remove",
    "must_not_invent",
    "format_expectation",
    "tone_expectation",
    "acceptable_variations",
    "evaluation_focus",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_unique(values: list[str], label: str) -> None:
    require(len(values) == len(set(values)), f"{label}存在重复")


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def main() -> None:
    with DATA_PATH.open(encoding="utf-8") as handle:
        document = json.load(handle)

    cases = document["cases"]
    variants = document["stress_variants"]
    factor_definitions = document["input_factor_definitions"]
    factor_acceptance_rules = document["factor_acceptance_rules"]
    factor_requirements = document["factor_coverage_requirements"]
    stutter_form_definitions = document["stutter_form_definitions"]
    stutter_form_requirements = document["stutter_form_coverage_requirements"]

    require(document["schema_version"] == 3, "schema_version 必须为 3")
    require(document["case_count"] == len(cases), "case_count 与实际基准样本数不一致")
    require(
        document["stress_variant_count"] == len(variants),
        "stress_variant_count 与实际专项变体数不一致",
    )
    require(
        document["total_input_count"] == len(cases) + len(variants),
        "total_input_count 与基准样本及专项变体总数不一致",
    )

    case_ids = [item["id"] for item in cases]
    variant_ids = [item["id"] for item in variants]
    require_unique(case_ids, "基准样本 ID")
    require_unique(variant_ids, "专项变体 ID")
    require(set(case_ids).isdisjoint(variant_ids), "基准样本与专项变体 ID 冲突")
    require_unique([item["title"] for item in cases], "基准样本标题")
    require_unique([item["spoken_input"] for item in cases], "基准输入")
    require_unique([item["reference_output"] for item in cases], "参考成稿")
    require_unique([item["spoken_input"] for item in variants], "专项变体输入")

    case_id_set = set(case_ids)
    scenario_counts = Counter(item["scenario_group"] for item in cases)
    require(len(scenario_counts) == document["scenario_count"], "场景数量不符合声明")
    require(all(count == 5 for count in scenario_counts.values()), "每个场景必须恰好有 5 条基准样本")

    blind_categories: set[str] = set()
    for item in cases:
        missing = REQUIRED_CASE_FIELDS - item.keys()
        require(not missing, f"样本 {item.get('id', '<unknown>')} 缺少字段：{sorted(missing)}")
        require(item["spoken_input"].strip(), f"样本 {item['id']} 的 spoken_input 不能为空")
        require(item["reference_output"].strip(), f"样本 {item['id']} 的 reference_output 不能为空")
        require(item["must_preserve"], f"样本 {item['id']} 必须定义 must_preserve")
        require(item["must_not_invent"], f"样本 {item['id']} 必须定义 must_not_invent")
        require(item["evaluation_focus"], f"样本 {item['id']} 必须定义 evaluation_focus")
        blind_categories.update(item["blind_categories"])

    require(
        REQUIRED_BLIND_CATEGORIES <= blind_categories,
        f"缺少盲测难点类别：{sorted(REQUIRED_BLIND_CATEGORIES - blind_categories)}",
    )

    factor_counts: Counter[str] = Counter()
    stutter_form_counts: Counter[str] = Counter()
    variant_by_id: dict[str, dict] = {}
    for item in variants:
        variant_id = item["id"]
        require(item["base_case_id"] in case_id_set, f"变体 {variant_id} 指向不存在的基准样本")
        require(item["spoken_input"].strip(), f"变体 {variant_id} 的 spoken_input 不能为空")
        require(item["input_factors"], f"变体 {variant_id} 必须包含 input_factors")
        require_unique(item["input_factors"], f"变体 {variant_id} 的 input_factors")
        for factor in item["input_factors"]:
            require(factor in factor_definitions, f"变体 {variant_id} 使用了未定义因素 {factor}")
            factor_counts[factor] += 1
        if "stutter_repetition" in item["input_factors"]:
            stutter_form = item.get("stutter_form")
            require(stutter_form in stutter_form_definitions, f"口吃变体 {variant_id} 缺少有效 stutter_form")
            stutter_form_counts[stutter_form] += 1
        else:
            require("stutter_form" not in item, f"非口吃变体 {variant_id} 不得定义 stutter_form")
        variant_by_id[variant_id] = item

    require(
        set(factor_requirements) == set(factor_definitions) == set(factor_acceptance_rules),
        "因素定义、验收规则与最低覆盖门槛必须一一对应",
    )
    for factor, minimum in factor_requirements.items():
        require(
            factor_counts[factor] >= minimum,
            f"因素 {factor} 只有 {factor_counts[factor]} 条，低于最低门槛 {minimum}",
        )
    require(
        set(stutter_form_requirements) == set(stutter_form_definitions),
        "口吃形态定义与最低覆盖门槛必须一一对应",
    )
    for stutter_form, minimum in stutter_form_requirements.items():
        require(
            stutter_form_counts[stutter_form] >= minimum,
            f"口吃形态 {stutter_form} 只有 {stutter_form_counts[stutter_form]} 条，低于最低门槛 {minimum}",
        )

    base_rows = load_csv(BASE_RUN_PATH)
    stress_rows = load_csv(STRESS_RUN_PATH)
    require([row["sample_id"] for row in base_rows] == case_ids, "基准试跑 CSV 与 JSON ID/顺序不一致")
    require(
        [row["test_input_id"] for row in stress_rows] == variant_ids,
        "专项试跑 CSV 与 JSON ID/顺序不一致",
    )
    for row in stress_rows:
        variant = variant_by_id[row["test_input_id"]]
        require(row["base_case_id"] == variant["base_case_id"], f"变体 {variant['id']} 的 base_case_id 不一致")
        require(
            row["input_factors"].split("+") == variant["input_factors"],
            f"变体 {variant['id']} 的 input_factors 与 CSV 不一致",
        )

    print(
        f"PASS：{len(cases)} 条场景基准 + {len(variants)} 条脏输入变体 = "
        f"{len(cases) + len(variants)} 次输入；{len(factor_counts)} 类输入因素全部达到门槛；"
        f"口吃覆盖 {factor_counts['stutter_repetition']} 条、{len(stutter_form_counts)} 种形态。"
    )
    for factor in sorted(factor_counts):
        print(f"- {factor}: {factor_counts[factor]}")


if __name__ == "__main__":
    main()
