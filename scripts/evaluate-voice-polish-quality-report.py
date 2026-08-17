#!/usr/bin/env python3
"""对正式 Voice Polish 跑测报告执行可重复的硬性验收。"""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path


def normalized(text: str) -> str:
    return "".join(
        character
        for character in unicodedata.normalize("NFKC", text)
        if not character.isspace()
    )


def paragraph_count(text: str) -> int:
    return len([part for part in re.split(r"\n\s*\n", text.strip()) if part.strip()])


def list_item_count(text: str) -> int:
    pattern = re.compile(r"(?m)^\s*(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）]|[-*•])\s*")
    return len(pattern.findall(text))


def flatten_dataset(document: dict) -> list[dict]:
    base_by_id = {item["id"]: item for item in document["cases"]}
    rows = []
    for item in document["cases"]:
        rows.append({**item, "base_case_id": item["id"], "input_kind": "base"})
    for item in document["stress_variants"]:
        base = base_by_id[item["base_case_id"]]
        rows.append({
            **item,
            "reference_output": base["reference_output"],
            "must_preserve": base["must_preserve"],
            "must_remove": base["must_remove"],
            "must_not_invent": base["must_not_invent"],
            "input_kind": "stress_variant",
        })
    return rows


def add_failure(failures: list[str], test_id: str, message: str) -> None:
    failures.append(f"{test_id}: {message}")


def compact_optional_checks(checks: dict) -> dict:
    """Swift Codable 会把缺省可选项写成 null，语义上与数据集省略字段相同。"""
    return {key: value for key, value in checks.items() if value is not None}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))
    report = json.loads(args.report.read_text(encoding="utf-8"))
    expected = flatten_dataset(dataset)
    actual = report.get("cases", [])
    failures: list[str] = []

    if report.get("status") != "complete":
        failures.append(f"报告状态不是 complete：{report.get('status')}")
    if report.get("quality_mode") != "automatic":
        failures.append(f"跑测未使用唯一 automatic 模式：{report.get('quality_mode')}")
    if report.get("dataset_schema_version") != dataset.get("schema_version"):
        failures.append("报告与测试集 schema_version 不一致")
    if report.get("requested_input_count") != len(expected):
        failures.append("requested_input_count 与测试集不一致")
    if report.get("completed_input_count") != len(expected):
        failures.append("completed_input_count 与测试集不一致")
    if len(actual) != len(expected):
        failures.append(f"报告只有 {len(actual)} 条结果，应为 {len(expected)} 条")

    actual_by_id = {item.get("test_input_id"): item for item in actual}
    if len(actual_by_id) != len(actual):
        failures.append("报告包含空 ID 或重复 ID")

    for fixture in expected:
        test_id = fixture["id"]
        result = actual_by_id.get(test_id)
        if result is None:
            add_failure(failures, test_id, "缺少跑测结果")
            continue
        if result.get("base_case_id") != fixture["base_case_id"]:
            add_failure(failures, test_id, "base_case_id 不一致")
        if result.get("input_kind") != fixture["input_kind"]:
            add_failure(failures, test_id, "input_kind 不一致")
        if result.get("length_bucket") != fixture["length_bucket"]:
            add_failure(failures, test_id, "length_bucket 不一致")
        if result.get("context_type") != fixture["context_type"]:
            add_failure(failures, test_id, "context_type 不一致")
        if result.get("quality_dimensions") != fixture["quality_dimensions"]:
            add_failure(failures, test_id, "quality_dimensions 不一致")
        if result.get("requires_transformation") != fixture["requires_transformation"]:
            add_failure(failures, test_id, "requires_transformation 不一致")
        if result.get("segment_count") != len(fixture["segment_texts"]):
            add_failure(failures, test_id, "segment_count 不一致")
        if compact_optional_checks(result.get("automatic_checks", {})) != compact_optional_checks(
            fixture["automatic_checks"]
        ):
            add_failure(failures, test_id, "报告中的自动检查定义与冻结测试集不一致")

        output = result.get("model_output", "")
        canonical = result.get("canonical_input", "")
        if not output.strip():
            add_failure(failures, test_id, "模型输出为空")
            continue
        if result.get("fallback_used"):
            add_failure(failures, test_id, "触发原文回退")
        if result.get("failure_reason") is not None:
            add_failure(failures, test_id, f"存在失败原因 {result['failure_reason']}")
        if result.get("validation_codes"):
            add_failure(failures, test_id, f"存在校验错误 {result['validation_codes']}")
        if fixture["requires_transformation"] and normalized(output) == normalized(canonical):
            add_failure(failures, test_id, "需要整理但成稿与输入等价")

        checks = fixture["automatic_checks"]
        for token in checks["required_substrings"]:
            if token not in output:
                add_failure(failures, test_id, f"缺少必含文本 {token!r}")
        for token in checks["forbidden_substrings"]:
            if token in output:
                add_failure(failures, test_id, f"保留了禁含文本 {token!r}")
        for token in checks["forbidden_context_substrings"]:
            if token in output:
                add_failure(failures, test_id, f"泄漏上下文文本 {token!r}")
        minimum_paragraphs = checks.get("minimum_paragraph_count")
        if minimum_paragraphs and paragraph_count(output) < minimum_paragraphs:
            add_failure(failures, test_id, f"段落数少于 {minimum_paragraphs}")
        minimum_items = checks.get("minimum_list_item_count")
        if minimum_items and list_item_count(output) < minimum_items:
            add_failure(failures, test_id, f"列表项少于 {minimum_items}")

    expected_ids = {item["id"] for item in expected}
    unexpected_ids = set(actual_by_id) - expected_ids
    if unexpected_ids:
        failures.append(f"报告包含测试集之外的 ID：{sorted(unexpected_ids)}")

    if failures:
        print(f"FAIL：{len(failures)} 项硬性检查未通过")
        for failure in failures[:100]:
            print(f"- {failure}")
        if len(failures) > 100:
            print(f"- 其余 {len(failures) - 100} 项已省略")
        raise SystemExit(1)

    buckets = Counter(item["length_bucket"] for item in expected)
    contexts = Counter(item["context_type"] for item in expected)
    print(f"PASS：{len(expected)} 次输入全部通过硬性检查，未发生回退、空输出或必要改写缺失。")
    print(f"长度覆盖：{dict(sorted(buckets.items()))}")
    print(f"上下文覆盖：{dict(sorted(contexts.items()))}")
    print("提示：自然度、个人口吻与是否敢直接发送仍须由独立 Agent 复核，机器检查不能代替。")


if __name__ == "__main__":
    main()
