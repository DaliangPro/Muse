#!/usr/bin/env python3
"""校验语音润色架构受控实验的输入隔离、Provider 审计和盲评包。"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


FORBIDDEN_MODEL_INPUT_KEYS = {
    "semantic_contract",
    "reference_output",
    "automatic_checks",
    "major_error_if",
    "must_preserve",
    "must_resolve",
    "must_not_add",
    "acceptable_variations",
}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL：{message}")


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        fail(f"缺少普通 JSON 文件：{path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"无法解析 {path}：{error}")
    if not isinstance(value, dict):
        fail(f"{path} 顶层必须是对象")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file() or path.is_symlink():
        fail(f"缺少普通 JSONL 文件：{path}")
    rows = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"{path}:{line_number} 无法解析：{error}")
        if not isinstance(value, dict):
            fail(f"{path}:{line_number} 必须是对象")
        rows.append(value)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    arguments = parser.parse_args()
    run_dir = arguments.run_dir.resolve()
    run = load_json(run_dir / "experiment-run.json")
    # model-inputs 顶层是数组，单独解析。
    model_inputs_path = run_dir / "model-inputs.json"
    if not model_inputs_path.is_file() or model_inputs_path.is_symlink():
        fail("缺少普通 model-inputs.json")
    try:
        model_inputs_value = json.loads(model_inputs_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"model-inputs.json 无法解析：{error}")
    if not isinstance(model_inputs_value, list):
        fail("model-inputs.json 顶层必须是数组")
    model_inputs = model_inputs_value

    blind = load_json(run_dir / "blind-review-packet.json")
    sealed = load_json(run_dir / "sealed-model-map.json")
    audit = load_jsonl(run_dir / "provider-audit.jsonl")

    schema_version = run.get("schema_version")
    if schema_version not in {1, 2, 3, 4, 5, 6, 7, 8, 9, 10} or run.get("status") != "complete":
        fail("实验报告未完整完成")
    if blind.get("schema_version") != schema_version or sealed.get("schema_version") != schema_version:
        fail("实验报告、盲评包与密封映射 schema 不一致")
    dataset_path = Path(str(run.get("dataset_path", "")))
    if not dataset_path.is_absolute() or not dataset_path.is_file() or dataset_path.is_symlink():
        fail("实验报告未绑定可读的绝对数据集路径")
    if run.get("dataset_sha256") != sha256_bytes(dataset_path.read_bytes()):
        fail("实验数据集 SHA-256 不一致")
    dataset = load_json(dataset_path)
    dataset_by_id = {row["test_input_id"]: row for row in dataset.get("inputs", [])}

    models = run.get("models")
    case_ids = run.get("case_ids")
    results = run.get("results")
    if not isinstance(models, list) or len(models) < 2 or len(set(models)) != len(models):
        fail("实验未包含至少两个不同模型")
    reviewer_strategy = run.get("reviewer_strategy")
    if schema_version >= 4 and reviewer_strategy not in {
        "same_model",
        "cross_model_swap",
    }:
        fail("实验缺少合法 reviewer_strategy")
    if schema_version >= 4 and reviewer_strategy == "cross_model_swap" and len(models) != 2:
        fail("cross_model_swap 必须且只能使用两个模型")
    if not isinstance(case_ids, list) or not case_ids or len(set(case_ids)) != len(case_ids):
        fail("实验样本 ID 为空或重复")
    if any(case_id not in dataset_by_id for case_id in case_ids):
        fail("实验引用了核心集以外的样本")
    if not isinstance(results, list) or len(results) != len(models) * len(case_ids):
        fail("实验结果数量与模型×样本不一致")

    result_by_key: dict[tuple[str, str], dict[str, Any]] = {}
    total_calls = 0
    for result in results:
        if not isinstance(result, dict):
            fail("实验结果必须是对象")
        key = (result.get("test_input_id"), result.get("model"))
        if key in result_by_key or key[0] not in case_ids or key[1] not in models:
            fail("实验结果身份重复或越界")
        result_by_key[key] = result
        if schema_version >= 4:
            reviewer_model = result.get("reviewer_model")
            if reviewer_model not in models:
                fail(f"{key} reviewer_model 不合法")
            expected_reviewer = (
                models[1 - models.index(key[1])]
                if reviewer_strategy == "cross_model_swap"
                else key[1]
            )
            if reviewer_model != expected_reviewer:
                fail(f"{key} reviewer_model 与 reviewer_strategy 不一致")
        call_count = result.get("call_count")
        if not isinstance(call_count, int) or call_count < 1:
            fail(f"{key} call_count 不合法")
        total_calls += call_count
        outcome = result.get("outcome")
        output = result.get("output_text")
        if outcome == "polished":
            if result.get("stage") != "complete" or not isinstance(output, str) or not output.strip():
                fail(f"{key} polished 结果不完整")
        elif outcome == "unavailable":
            if output != "" or not isinstance(result.get("error"), str):
                fail(f"{key} unavailable 结果未显式保持失败边界")
        else:
            fail(f"{key} outcome 不合法")

        spans = result.get("source_spans")
        if not isinstance(spans, list) or not spans:
            fail(f"{key} 缺少 source spans")
        source = dataset_by_id[key[0]]["spoken_input"]
        rebuilt = "".join(span.get("text", "") for span in spans if isinstance(span, dict))
        if rebuilt != source:
            fail(f"{key} source spans 无法无损拼回")
        expected_start = 0
        for span in spans:
            text = span.get("text")
            start = span.get("start")
            end = span.get("end")
            if (
                not isinstance(start, int)
                or not isinstance(end, int)
                or start != expected_start
                or end < start
                or source[start:end] != text
            ):
                fail(f"{key} source span 字符范围不连续或无法回溯")
            expected_start = end
            if span.get("sha256") != sha256_bytes(str(text).encode("utf-8")):
                fail(f"{key} source span SHA-256 不一致")
        if expected_start != len(source):
            fail(f"{key} source span 未覆盖全文")
        if schema_version >= 2:
            logic_cues = result.get("required_logic_cues")
            if not isinstance(logic_cues, list):
                fail(f"{key} typed ledger 缺少 required_logic_cues")
            known_cue_ids: set[str] = set()
            known_span_ids = {span["id"] for span in spans}
            for cue in logic_cues:
                if not isinstance(cue, dict):
                    fail(f"{key} logic cue 必须是对象")
                cue_id = cue.get("id")
                start = cue.get("start")
                end = cue.get("end")
                text = cue.get("text")
                source_span_ids = cue.get("source_span_ids")
                if (
                    not isinstance(cue_id, str)
                    or not cue_id
                    or cue_id in known_cue_ids
                    or not isinstance(start, int)
                    or not isinstance(end, int)
                    or not isinstance(text, str)
                    or source[start:end] != text
                    or cue.get("sha256") != sha256_bytes(text.encode("utf-8"))
                    or not isinstance(source_span_ids, list)
                    or not source_span_ids
                    or any(span_id not in known_span_ids for span_id in source_span_ids)
                ):
                    fail(f"{key} logic cue 无法回溯原文")
                known_cue_ids.add(cue_id)
            local_ledgers = result.get("local_ledgers")
            if not isinstance(local_ledgers, list):
                fail(f"{key} typed ledger 缺少 local_ledgers")
            for item in local_ledgers:
                ledger = item.get("ledger") if isinstance(item, dict) else None
                if not isinstance(ledger, dict) or not isinstance(
                    ledger.get("conditionals"), list
                ):
                    fail(f"{key} typed ledger 缺少 conditionals")
                if schema_version >= 3:
                    units = ledger.get("units")
                    if not isinstance(units, list) or not units:
                        fail(f"{key} typed ledger 缺少 units")
                    allowed_delivery_roles = {
                        "recipient_content",
                        "style_directive",
                        "editor_directive",
                        "excluded_content",
                    }
                    if any(
                        not isinstance(unit, dict)
                        or unit.get("delivery_role") not in allowed_delivery_roles
                        for unit in units
                    ):
                        fail(f"{key} typed ledger 缺少合法 delivery_role")
                    if schema_version >= 9 and any(
                        not isinstance(unit.get("surface_tokens"), list)
                        or (
                            unit.get("delivery_role") == "recipient_content"
                            and bool(unit.get("surface_tokens"))
                        )
                        or (
                            unit.get("delivery_role")
                            in {
                                "style_directive",
                                "editor_directive",
                                "excluded_content",
                            }
                            and not unit.get("surface_tokens")
                        )
                        for unit in units
                    ):
                        fail(f"{key} typed ledger 缺少合法 unit surface_tokens")
                if schema_version >= 4:
                    corrections = ledger.get("corrections")
                    if not isinstance(corrections, list) or any(
                        not isinstance(correction, dict)
                        or correction.get("rendering_policy")
                        not in {"final_only", "announce_change"}
                        for correction in corrections
                    ):
                        fail(f"{key} typed ledger 缺少合法 correction rendering_policy")
                if schema_version >= 5:
                    audience = ledger.get("audience")
                    if not isinstance(audience, list) or any(
                        not isinstance(item, dict)
                        or not isinstance(item.get("surface_tokens"), list)
                        or not item["surface_tokens"]
                        for item in audience
                    ):
                        fail(f"{key} typed ledger 缺少合法 audience surface_tokens")
                    if schema_version >= 10 and any(
                        item.get("delivery_mode")
                        not in {"explicit_reference", "direct_address"}
                        for item in audience
                    ):
                        fail(f"{key} typed ledger 缺少合法 audience delivery_mode")
                if schema_version >= 7 and not isinstance(
                    ledger.get("technical_token_mappings"), list
                ):
                    fail(f"{key} typed ledger 缺少 technical_token_mappings")
                if schema_version >= 8 and not isinstance(
                    ledger.get("dictated_symbol_mappings"), list
                ):
                    fail(f"{key} typed ledger 缺少 dictated_symbol_mappings")
            global_plan = result.get("global_plan")
            if global_plan is not None and (
                not isinstance(global_plan, dict)
                or not isinstance(global_plan.get("global_conditionals"), list)
            ):
                fail(f"{key} typed ledger 缺少 global_conditionals")
            if isinstance(global_plan, dict):
                covered_cue_ids = [
                    cue_id
                    for rule in global_plan["global_conditionals"]
                    if isinstance(rule, dict)
                    for cue_id in rule.get("cue_ids", [])
                ]
                if (
                    set(covered_cue_ids) != known_cue_ids
                    or len(covered_cue_ids) != len(set(covered_cue_ids))
                ):
                    fail(f"{key} global_conditionals 未一一覆盖 logic cues")
                if schema_version >= 4:
                    global_corrections = global_plan.get("global_corrections")
                    if not isinstance(global_corrections, list) or any(
                        not isinstance(correction, dict)
                        or correction.get("rendering_policy")
                        not in {"final_only", "announce_change"}
                        for correction in global_corrections
                    ):
                        fail(
                            f"{key} global_corrections 缺少合法 rendering_policy"
                        )
                if schema_version >= 5:
                    global_audience = global_plan.get("global_audience")
                    if not isinstance(global_audience, list) or any(
                        not isinstance(item, dict)
                        or not isinstance(item.get("surface_tokens"), list)
                        or not item["surface_tokens"]
                        for item in global_audience
                    ):
                        fail(f"{key} global_audience 缺少 surface_tokens")
                    if schema_version >= 10 and any(
                        item.get("delivery_mode")
                        not in {"explicit_reference", "direct_address"}
                        for item in global_audience
                    ):
                        fail(f"{key} global_audience 缺少合法 delivery_mode")
                if schema_version >= 7 and not isinstance(
                    global_plan.get("global_technical_token_mappings"), list
                ):
                    fail(f"{key} global plan 缺少技术标识映射")
                if schema_version >= 8 and not isinstance(
                    global_plan.get("global_dictated_symbol_mappings"), list
                ):
                    fail(f"{key} global plan 缺少口述符号映射")

    if len(audit) != total_calls or len(model_inputs) != total_calls:
        fail(
            f"Provider 回执/{len(audit)}、模型输入/{len(model_inputs)} 与调用数/{total_calls} 不一致"
        )
    for index, receipt in enumerate(audit, 1):
        if receipt.get("request_ordinal") != index:
            fail("Provider 回执序号不连续")
        if receipt.get("configured_model") not in models or receipt.get("case_id") not in case_ids:
            fail("Provider 回执引用了未知模型或样本")
        result = result_by_key.get(
            (receipt.get("case_id"), receipt.get("configured_model"))
        )
        if receipt.get("http_status") == 200 and receipt.get("error") is None:
            if (
                receipt.get("finish_reason") == "length"
                or not receipt.get("provider_response_id")
                or not receipt.get("request_body_sha256")
                or not receipt.get("response_text_sha256")
            ):
                fail(f"Provider 回执 {index} 不是可验证的完整成功响应")
        elif (
            result is None
            or result.get("outcome") != "unavailable"
            or not result.get("error")
            or not receipt.get("error")
            or not receipt.get("request_body_sha256")
            or receipt.get("response_text_sha256") is not None
        ):
            fail(f"Provider 回执 {index} 的失败证据与 unavailable 结果不一致")

    serialized_model_inputs = json.dumps(model_inputs, ensure_ascii=False, sort_keys=True)
    leaked_keys = sorted(
        key for key in FORBIDDEN_MODEL_INPUT_KEYS if key in serialized_model_inputs
    )
    if leaked_keys:
        fail(f"模型输入泄漏评分契约：{leaked_keys}")
    if "apiKey" in serialized_model_inputs or "Authorization" in serialized_model_inputs:
        fail("模型输入证据中出现凭证字段")

    if blind.get("run_nonce") != run.get("run_nonce") or sealed.get("run_nonce") != run.get("run_nonce"):
        fail("盲评包或密封映射与实验 nonce 不一致")
    blind_cases = blind.get("cases")
    sealed_map = sealed.get("case_candidate_model_map")
    if not isinstance(blind_cases, list) or len(blind_cases) != len(case_ids):
        fail("盲评包样本数不正确")
    if not isinstance(sealed_map, dict):
        fail("密封模型映射缺失")
    serialized_blind = json.dumps(blind, ensure_ascii=False, sort_keys=True)
    if any(model in serialized_blind for model in models):
        fail("盲评包泄漏了模型名称")
    for blind_case in blind_cases:
        case_id = blind_case.get("test_input_id")
        mapping = sealed_map.get(case_id)
        candidates = blind_case.get("candidates")
        if not isinstance(mapping, dict) or not isinstance(candidates, list):
            fail(f"{case_id} 盲评候选或密封映射缺失")
        if set(mapping.values()) != set(models) or len(candidates) != len(models):
            fail(f"{case_id} 盲评候选与模型不一致")
        for candidate in candidates:
            label = candidate.get("candidate_label")
            model = mapping.get(label)
            result = result_by_key.get((case_id, model))
            if result is None:
                fail(f"{case_id}/{label} 无法映射回实验结果")
            if (
                candidate.get("outcome") != result.get("outcome")
                or candidate.get("output_text") != result.get("output_text")
            ):
                fail(f"{case_id}/{label} 盲评内容与实验结果不一致")

    print(
        f"PASS：受控实验校验通过，{len(case_ids)} 条样本 / "
        f"{len(models)} 个模型 / {total_calls} 次真实 Provider 调用"
    )


if __name__ == "__main__":
    main()
