#!/usr/bin/env python3
"""校验 Muse 语音润色 V2 多维测试集的结构、覆盖和自动检查定义。"""

from __future__ import annotations

import csv
import json
from collections import Counter
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_PATH = PROJECT_ROOT / "docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Set.json"
RUN_PATH = PROJECT_ROOT / "docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Run-Template.csv"

REQUIRED_BLIND_CATEGORIES = {
    "proper_noun", "self_correction", "aside", "disordered",
    "list", "numbers", "mixed_language", "ai_prompt",
}
REQUIRED_BASE_FIELDS = {
    "id", "scenario_group", "writing_scene", "title", "difficulty",
    "challenge_tags", "blind_categories", "spoken_input", "reference_output",
    "must_preserve", "must_remove", "must_not_invent", "format_expectation",
    "tone_expectation", "acceptable_variations", "evaluation_focus",
}
REQUIRED_MULTIDIMENSION_FIELDS = {
    "length_bucket", "context_type", "quality_dimensions",
    "requires_transformation", "segment_texts", "automatic_checks",
}
REQUIRED_AUTOMATIC_CHECK_FIELDS = {
    "required_substrings", "forbidden_substrings", "forbidden_context_substrings",
}
LENGTH_BUCKETS = (
    ("micro_1_15", 1, 15),
    ("short_16_80", 16, 80),
    ("medium_81_300", 81, 300),
    ("long_301_1000", 301, 1000),
    ("very_long_1001_3000", 1001, 3000),
    ("ultra_long_3001_8000", 3001, 8000),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_unique(values: list[str], label: str) -> None:
    require(len(values) == len(set(values)), f"{label}存在重复")


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def expected_length_bucket(text: str) -> str:
    size = len(text)
    for bucket, minimum, maximum in LENGTH_BUCKETS:
        if minimum <= size <= maximum:
            return bucket
    raise ValueError(f"输入长度 {size} 不在 1～8000 字范围内")


def require_string_list(item: dict, key: str, label: str) -> list[str]:
    value = item.get(key)
    require(isinstance(value, list), f"{label} 的 {key} 必须是数组")
    require(all(isinstance(entry, str) and entry.strip() for entry in value), f"{label} 的 {key} 含空值")
    require_unique(value, f"{label} 的 {key}")
    return value


def validate_multidimension_item(
    item: dict,
    *,
    label: str,
    length_definitions: dict,
    context_definitions: dict,
    quality_definitions: dict,
) -> None:
    missing = REQUIRED_MULTIDIMENSION_FIELDS - item.keys()
    require(not missing, f"{label} 缺少多维字段：{sorted(missing)}")
    spoken = item["spoken_input"]
    require(isinstance(spoken, str) and spoken.strip(), f"{label} 的 spoken_input 不能为空")
    expected_bucket = expected_length_bucket(spoken)
    require(item["length_bucket"] == expected_bucket, f"{label} 的 length_bucket 应为 {expected_bucket}")
    require(item["length_bucket"] in length_definitions, f"{label} 使用未定义长度桶")
    require(item["context_type"] in context_definitions, f"{label} 使用未定义上下文类型")

    dimensions = require_string_list(item, "quality_dimensions", label)
    require(dimensions, f"{label} 必须声明质量维度")
    unknown_dimensions = set(dimensions) - set(quality_definitions)
    require(not unknown_dimensions, f"{label} 使用未定义质量维度：{sorted(unknown_dimensions)}")
    for required in ("final_intent", "fact_preservation", "no_invention", "direct_send"):
        require(required in dimensions, f"{label} 缺少基础质量维度 {required}")
    require(isinstance(item["requires_transformation"], bool), f"{label} 的 requires_transformation 必须是布尔值")

    segments = require_string_list(item, "segment_texts", label)
    require(segments, f"{label} 至少需要一个 segment")
    require("".join(segments) == spoken, f"{label} 的 segment_texts 拼接后与 spoken_input 不一致")
    if "multi_segment" in dimensions:
        require(len(segments) > 1, f"{label} 标记 multi_segment 但只有一个 segment")
        require_unique(segments, f"{label} 的多段正文")
    if "cross_segment_correction" in dimensions:
        require(len(segments) >= 2, f"{label} 的跨段纠错至少需要两个 segment")

    checks = item["automatic_checks"]
    require(isinstance(checks, dict), f"{label} 的 automatic_checks 必须是对象")
    missing_checks = REQUIRED_AUTOMATIC_CHECK_FIELDS - checks.keys()
    require(not missing_checks, f"{label} 缺少自动检查：{sorted(missing_checks)}")
    required = require_string_list(checks, "required_substrings", f"{label} 自动检查")
    forbidden = require_string_list(checks, "forbidden_substrings", f"{label} 自动检查")
    forbidden_context = require_string_list(checks, "forbidden_context_substrings", f"{label} 自动检查")
    require(set(required).isdisjoint(forbidden), f"{label} 的必含与禁含文本冲突")
    require(set(required).isdisjoint(forbidden_context), f"{label} 的必含与上下文禁含文本冲突")
    if "minimum_paragraph_count" in checks:
        require(checks["minimum_paragraph_count"] > 0, f"{label} 的最少段落数必须大于 0")
    if "minimum_list_item_count" in checks:
        require(checks["minimum_list_item_count"] > 0, f"{label} 的最少列表项必须大于 0")

    context_type = item["context_type"]
    fixture = item.get("context_fixture")
    if context_type == "none":
        require(fixture is None, f"{label} 的无上下文样本不应携带 context_fixture")
        return

    require(isinstance(fixture, dict), f"{label} 缺少 context_fixture")
    require(fixture.get("type") == context_type, f"{label} 的 context_fixture.type 不一致")
    require(fixture.get("level") in {"metadataOnly", "selectedText", "nearbyText"}, f"{label} 的上下文级别无效")
    require(fixture.get("safety") in {"safe", "secure", "unknown"}, f"{label} 的上下文安全级别无效")
    require(isinstance(fixture.get("recent_muse_inputs"), list), f"{label} 的 recent_muse_inputs 必须是数组")
    if context_type == "secure_blocked":
        require(fixture["safety"] == "secure", f"{label} 必须使用 secure 安全级别")
        require(forbidden_context, f"{label} 必须声明安全字段泄漏检查")
    elif context_type == "unknown_blocked":
        require(fixture["safety"] == "unknown", f"{label} 必须使用 unknown 安全级别")
        require(forbidden_context, f"{label} 必须声明未知字段泄漏检查")
    else:
        require(fixture["safety"] == "safe", f"{label} 的授权上下文必须标记为 safe")


def main() -> None:
    with DATA_PATH.open(encoding="utf-8") as handle:
        document = json.load(handle)

    cases = document["cases"]
    variants = document["stress_variants"]
    all_items = cases + variants
    factor_definitions = document["input_factor_definitions"]
    factor_acceptance_rules = document["factor_acceptance_rules"]
    factor_requirements = document["factor_coverage_requirements"]
    stutter_form_definitions = document["stutter_form_definitions"]
    stutter_form_requirements = document["stutter_form_coverage_requirements"]
    length_definitions = document["length_bucket_definitions"]
    context_definitions = document["context_type_definitions"]
    quality_definitions = document["quality_dimension_definitions"]

    require(document["schema_version"] == 4, "schema_version 必须为 4")
    require(document["north_star_metric"] == "direct_send", "北极星指标必须为 direct_send")
    require(document["case_count"] == len(cases), "case_count 与实际基准样本数不一致")
    require(document["stress_variant_count"] == len(variants), "stress_variant_count 与实际专项变体数不一致")
    require(document["total_input_count"] == len(all_items), "total_input_count 与实际输入总数不一致")
    require(len(all_items) >= 100, "多维测试集至少需要 100 次输入")
    require(set(length_definitions) == {item[0] for item in LENGTH_BUCKETS}, "长度桶定义不完整")
    require(set(document["length_bucket_coverage_requirements"]) == set(length_definitions), "长度桶门槛与定义不一致")
    require(set(document["context_type_coverage_requirements"]) == set(context_definitions), "上下文门槛与定义不一致")
    require(set(document["quality_dimension_coverage_requirements"]) <= set(quality_definitions), "质量维度门槛包含未定义项")

    case_ids = [item["id"] for item in cases]
    variant_ids = [item["id"] for item in variants]
    require_unique(case_ids, "基准样本 ID")
    require_unique(variant_ids, "专项变体 ID")
    require(set(case_ids).isdisjoint(variant_ids), "基准样本与专项变体 ID 冲突")
    require_unique([item["title"] for item in cases], "基准样本标题")
    require_unique([item["spoken_input"] for item in cases], "基准输入")
    require_unique([item["reference_output"] for item in cases], "参考成稿")
    require_unique([item["spoken_input"] for item in variants], "专项变体输入")

    blind_categories: set[str] = set()
    for item in cases:
        missing = REQUIRED_BASE_FIELDS - item.keys()
        require(not missing, f"样本 {item.get('id', '<unknown>')} 缺少字段：{sorted(missing)}")
        require(item["reference_output"].strip(), f"样本 {item['id']} 的 reference_output 不能为空")
        require_string_list(item, "must_preserve", f"样本 {item['id']}")
        require(item["must_preserve"], f"样本 {item['id']} 必须定义 must_preserve")
        require_string_list(item, "must_remove", f"样本 {item['id']}")
        require_string_list(item, "must_not_invent", f"样本 {item['id']}")
        require(item["must_not_invent"], f"样本 {item['id']} 必须定义 must_not_invent")
        require_string_list(item, "evaluation_focus", f"样本 {item['id']}")
        require(item["evaluation_focus"], f"样本 {item['id']} 必须定义 evaluation_focus")
        require_string_list(item, "blind_categories", f"样本 {item['id']}")
        blind_categories.update(item["blind_categories"])
        validate_multidimension_item(
            item,
            label=f"样本 {item['id']}",
            length_definitions=length_definitions,
            context_definitions=context_definitions,
            quality_definitions=quality_definitions,
        )
    require(REQUIRED_BLIND_CATEGORIES <= blind_categories, f"缺少盲测难点类别：{sorted(REQUIRED_BLIND_CATEGORIES - blind_categories)}")

    case_id_set = set(case_ids)
    factor_counts: Counter[str] = Counter()
    stutter_form_counts: Counter[str] = Counter()
    for item in variants:
        variant_id = item["id"]
        require(item["base_case_id"] in case_id_set, f"变体 {variant_id} 指向不存在的基准样本")
        factors = require_string_list(item, "input_factors", f"变体 {variant_id}")
        require(factors, f"变体 {variant_id} 必须包含 input_factors")
        for factor in factors:
            require(factor in factor_definitions, f"变体 {variant_id} 使用未定义因素 {factor}")
            factor_counts[factor] += 1
        if "stutter_repetition" in factors:
            stutter_form = item.get("stutter_form")
            require(stutter_form in stutter_form_definitions, f"口吃变体 {variant_id} 缺少有效 stutter_form")
            stutter_form_counts[stutter_form] += 1
        else:
            require("stutter_form" not in item, f"非口吃变体 {variant_id} 不得定义 stutter_form")
        validate_multidimension_item(
            item,
            label=f"变体 {variant_id}",
            length_definitions=length_definitions,
            context_definitions=context_definitions,
            quality_definitions=quality_definitions,
        )

    require(set(factor_requirements) == set(factor_definitions) == set(factor_acceptance_rules), "因素定义、验收规则与最低覆盖门槛必须一一对应")
    for factor, minimum in factor_requirements.items():
        require(factor_counts[factor] >= minimum, f"因素 {factor} 只有 {factor_counts[factor]} 条，低于最低门槛 {minimum}")
    require(set(stutter_form_requirements) == set(stutter_form_definitions), "口吃形态定义与最低覆盖门槛必须一一对应")
    for stutter_form, minimum in stutter_form_requirements.items():
        require(stutter_form_counts[stutter_form] >= minimum, f"口吃形态 {stutter_form} 只有 {stutter_form_counts[stutter_form]} 条，低于最低门槛 {minimum}")

    length_counts = Counter(item["length_bucket"] for item in all_items)
    context_counts = Counter(item["context_type"] for item in all_items)
    dimension_counts = Counter(dimension for item in all_items for dimension in item["quality_dimensions"])
    for bucket, minimum in document["length_bucket_coverage_requirements"].items():
        require(length_counts[bucket] >= minimum, f"长度桶 {bucket} 只有 {length_counts[bucket]} 条，低于门槛 {minimum}")
    for context_type, minimum in document["context_type_coverage_requirements"].items():
        require(context_counts[context_type] >= minimum, f"上下文类型 {context_type} 只有 {context_counts[context_type]} 条，低于门槛 {minimum}")
    for dimension, minimum in document["quality_dimension_coverage_requirements"].items():
        require(dimension_counts[dimension] >= minimum, f"质量维度 {dimension} 只有 {dimension_counts[dimension]} 条，低于门槛 {minimum}")

    long_items = [item for item in cases if "long_content_completion" in item["quality_dimensions"]]
    require(len(long_items) == 10, "长文本专项必须恰好包含 10 条基准样本")
    require(all(len(item["segment_texts"]) >= 6 for item in long_items), "长文本专项每条至少需要 6 个真实 segment")
    for item in long_items:
        for artifact in ("前前", "完成完成", "前之前"):
            require(
                artifact not in item["reference_output"],
                f"长文本参考成稿 {item['id']} 含机械拼接残片 {artifact}",
            )
    context_items = [item for item in cases if item["context_type"] != "none"]
    require(len(context_items) == 12, "上下文专项必须恰好包含 12 条基准样本")
    micro_items = [item for item in cases if item["id"].startswith("micro-")]
    require(len(micro_items) == 8, "极短文本专项必须恰好包含 8 条基准样本")
    require(any(not item["requires_transformation"] for item in micro_items), "极短文本必须覆盖无需改写的合格原文")
    require(any(item["requires_transformation"] for item in micro_items), "极短文本必须覆盖必须改写的脏输入")

    rows = load_csv(RUN_PATH)
    expected_rows = [(item["id"], item["id"], "base", item) for item in cases]
    expected_rows += [(item["id"], item["base_case_id"], "stress_variant", item) for item in variants]
    require(len(rows) == len(expected_rows), "试跑 CSV 行数与测试集不一致")
    for row, (test_id, base_id, kind, item) in zip(rows, expected_rows):
        require(row["test_input_id"] == test_id, f"试跑 CSV 的 ID/顺序错误：{test_id}")
        require(row["base_case_id"] == base_id, f"试跑 CSV 的 base_case_id 错误：{test_id}")
        require(row["input_kind"] == kind, f"试跑 CSV 的 input_kind 错误：{test_id}")
        require(row["length_bucket"] == item["length_bucket"], f"试跑 CSV 的长度桶错误：{test_id}")
        require(row["context_type"] == item["context_type"], f"试跑 CSV 的上下文类型错误：{test_id}")
        require(row["quality_dimensions"].split("+") == item["quality_dimensions"], f"试跑 CSV 的质量维度错误：{test_id}")
        require(row["requires_transformation"] == str(item["requires_transformation"]).lower(), f"试跑 CSV 的改写要求错误：{test_id}")

    print(
        f"PASS：{len(cases)} 条基准 + {len(variants)} 条变体 = {len(all_items)} 次输入；"
        f"长度覆盖 {dict(length_counts)}；上下文专项 {len(context_items)} 条；长文本专项 {len(long_items)} 条。"
    )
    print(f"质量维度：{dict(sorted(dimension_counts.items()))}")
    print(f"脏输入因素：{dict(sorted(factor_counts.items()))}")


if __name__ == "__main__":
    main()
