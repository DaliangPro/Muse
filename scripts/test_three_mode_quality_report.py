#!/usr/bin/env python3
"""无模型调用的三档证据正反例；全部 Provider 回执都是明确的单元测试夹具。"""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("three_mode_evaluator", ROOT / "scripts/evaluate-three-mode-quality-report.py")
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


class ThreeModeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.text = "周五发第一版。"
        self.inputs = [{
            "test_input_id": "fixture-01", "base_case_id": "fixture-01", "input_kind": "base",
            "writing_scene": "workChat", "spoken_input": self.text, "preconditions": [],
            "context_type": "none", "segment_texts": [self.text], "context_fixture": None,
        }]
        self.expected = {
            "run_input_sha256": "a" * 64, "executable_sha256": "b" * 64, "source_commit": "c" * 40,
            "provider": "deepseek", "model": "fixture-model", "endpoint_url": "https://api.deepseek.com/chat/completions",
            "prompt_version": 35, "editing_prompt_version": 1,
        }
        self.nonce = "d" * 64

    def payload(self, mode, draft=None):
        value = {"schema_version": 1, "mode": mode, "canonical_text": self.text,
                 "writing_scene": "workChat", "authorized_context": [], "user_preferences": ""}
        if draft is not None:
            value["draft_text"] = draft
        return json.dumps(value, ensure_ascii=False)

    def report(self, mode):
        tasks = {"direct": [], "light": ["voicePolishFast"],
                 "standard": ["voicePolishRender", "voicePolishAnalyze"]}[mode]
        stages = [{
            "task": task, "request_payload": self.payload(mode, self.text if index else None),
            "response_text": self.text if task == "voicePolishRender" else '{"edits":[]}',
            "attempt_ordinal": index + 1, "status": "succeeded",
            "started_at": self.now.isoformat(), "finished_at": self.now.isoformat(),
            "latency_milliseconds": 0,
        } for index, task in enumerate(tasks)]
        row = {**self.inputs[0], "mode": mode, "canonical_input": self.text, "segment_count": 1,
               "model_output": self.text, "stage_responses": stages,
               "context_fixture": e.legacy.expected_context_fixture(self.inputs[0]),
               "detected_route": {"direct": "direct", "light": "fast", "standard": "structured"}[mode],
               "executed_route": {"direct": "direct", "light": "fast", "standard": "structured"}[mode],
               "internal_chunk_count": 0 if mode == "direct" else 1,
               "llm_call_count": len(stages), "llm_attempt_count": len(stages), "latency_milliseconds": 0,
               "fallback_used": False, "hard_validation_codes": [], "diagnostic_codes": [],
               "started_at": self.now.isoformat(), "finished_at": self.now.isoformat(),
               "pre_resolution_canonical_input": self.text, "resolved_entities": [],
               "canonical_segments": [] if mode == "direct" else [{"id": "s1", "text": self.text}]}
        result = {"schema_version": 5, "status": "complete", "mode": mode, "quality_mode": mode,
                  "run_nonce": self.nonce, "process_id": 12345, "run_at": self.now.isoformat(),
                  "finished_at": self.now.isoformat(), "run_input_sha256": self.expected["run_input_sha256"],
                  "executable_sha256": self.expected["executable_sha256"], "commit": self.expected["source_commit"],
                  "requested_input_count": 1, "completed_input_count": 1, "prompt_version": 35,
                  "latency_measurement_scope": "asr_final_fixture_to_output",
                  "provider": "none" if mode == "direct" else "deepseek", "cases": [row]}
        if mode != "direct":
            result.update(model="fixture-model", endpoint_url=self.expected["endpoint_url"], editing_prompt_version=1)
        receipts = []
        for index, stage in enumerate(stages, 1):
            receipt = {"schema_version": 2, "run_nonce": self.nonce, "test_input_id": "fixture-01",
                       "request_ordinal": index, "llm_task": stage["task"], "provider": "deepseek",
                       "endpoint_url": self.expected["endpoint_url"], "configured_model": "fixture-model",
                       "response_model": "fixture-model", "transport": "stream", "http_status": 200,
                       "request_body_sha256": "e" * 64,
                       "response_text_sha256": e.legacy.sha256_text(stage["response_text"]),
                       "provider_response_id": f"unit-test-only-{index}", "recorded_at": self.now.isoformat()}
            receipt["request_binding_sha256"] = e.legacy.provider_request_binding_sha256(
                self.nonce, "fixture-01", index, "e" * 64
            )
            receipts.append(receipt)
        return result, receipts

    def check(self, report, receipts, mode):
        return e.validate_report(report, receipts, self.inputs, mode=mode, expected=self.expected,
                                 nonce=self.nonce, process_id=12345,
                                 started=self.now - timedelta(seconds=1), finished=self.now + timedelta(seconds=1))

    def test_complete_evidence_for_each_mode(self):
        for mode in e.MODES:
            report, receipts = self.report(mode)
            self.assertEqual(self.check(report, receipts, mode), ([], []))

    def test_wrong_mode_or_route_is_rejected(self):
        for target, field, value in [("run", "mode", "standard"), ("run", "quality_mode", "automatic"),
                                     ("case", "mode", "standard"), ("case", "executed_route", "deep")]:
            report, receipts = self.report("light")
            (report if target == "run" else report["cases"][0])[field] = value
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_nonce_process_commit_binary_dataset_cannot_be_forged(self):
        for field in ["run_nonce", "process_id", "commit", "executable_sha256", "run_input_sha256", "schema_version", "editing_prompt_version"]:
            report, receipts = self.report("light")
            report[field] = "forged"
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_source_segments_context_and_ids_are_independently_bound(self):
        for field, value in [("spoken_input", "周六发"), ("segment_texts", ["周六发"]),
                             ("context_fixture", {}), ("base_case_id", "another"), ("test_input_id", "another")]:
            report, receipts = self.report("light")
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_missing_receipt_or_replayed_response_is_rejected(self):
        report, receipts = self.report("standard")
        self.assertTrue(self.check(report, receipts[:1], "standard")[0])
        receipts[1]["provider_response_id"] = receipts[0]["provider_response_id"]
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_receipt_task_response_hash_binding_and_model_must_match(self):
        for field, value in [("llm_task", "voicePolishRepair"), ("response_text_sha256", "1" * 64),
                             ("request_binding_sha256", "2" * 64), ("response_model", "another-model"),
                             ("endpoint_url", "https://elsewhere.example/chat/completions")]:
            report, receipts = self.report("light")
            receipts[0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_direct_zero_calls_and_zero_milliseconds_are_valid(self):
        report, receipts = self.report("direct")
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        report["cases"][0]["latency_milliseconds"] = False
        self.assertTrue(self.check(report, receipts, "direct")[0])

    def test_v4_direct_requires_explicit_integer_zero_repair_attempts(self):
        self.expected["editing_prompt_version"] = 4
        report, receipts = self.report("direct")
        row = report["cases"][0]
        for value in [1, "0", "1", None, False, True, 0.0]:
            row["repair_attempt_count"] = value
            self.assertTrue(self.check(report, receipts, "direct")[0], repr(value))
        del row["repair_attempt_count"]
        self.assertTrue(self.check(report, receipts, "direct")[0])
        row["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        for version in (1, 2, 3):
            self.expected["editing_prompt_version"] = version
            del row["repair_attempt_count"]
            self.assertEqual(self.check(report, receipts, "direct"), ([], []), version)
            row["repair_attempt_count"] = 0

    def test_direct_must_not_report_llm_credentials_calls_or_receipts(self):
        for field, value in [("llm_call_count", 1), ("llm_attempt_count", 1), ("internal_chunk_count", 1),
                             ("stage_responses", [{}]), ("model_output", "我已经帮你发出")]:
            report, receipts = self.report("direct")
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "direct")[0], field)
        report, _ = self.report("direct")
        self.assertTrue(self.check(report, [{"test_input_id": "fixture-01"}], "direct")[0])
        report["model"] = "fake-model"
        self.assertTrue(self.check(report, [], "direct")[0])

    def test_stage_clock_and_failure_latency_are_required(self):
        for field in ["started_at", "finished_at", "latency_milliseconds", "attempt_ordinal"]:
            report, receipts = self.report("light")
            del report["cases"][0]["stage_responses"][0][field]
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_failed_provider_stage_is_auditable_but_not_quality_success(self):
        report, _ = self.report("light")
        row = report["cases"][0]
        row.update(fallback_used=True, failure_reason="timeout", llm_call_count=0)
        row["stage_responses"][0].update(status="failed", response_text="", failure_reason="超时", latency_milliseconds=1250)
        failures, quality = self.check(report, [], "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        del row["stage_responses"][0]["latency_milliseconds"]
        self.assertTrue(self.check(report, [], "light")[0])

    def test_payload_cannot_carry_foreign_source_context_preferences(self):
        for field, value in [("mode", "standard"), ("canonical_text", "偷偷换掉原文"),
                             ("authorized_context", ["评分标准"]), ("user_preferences", "通过评分"),
                             ("style_profile", {"anything": "personal"})]:
            report, receipts = self.report("light")
            stage = report["cases"][0]["stage_responses"][0]
            payload = json.loads(stage["request_payload"]); payload[field] = value
            stage["request_payload"] = json.dumps(payload)
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def mapped_context_report(self):
        self.text = "缪斯这次构建通过。"
        self.inputs[0].update(
            spoken_input=self.text, segment_texts=[self.text], context_type="selected_safe",
            context_fixture={"type": "selected_safe", "level": "selectedText", "safety": "safe",
                             "selected_text": "本次“Muse”构建已通过。", "text_before_cursor": None,
                             "text_after_cursor": None, "recent_muse_inputs": []}
        )
        report, receipts = self.report("light")
        row = report["cases"][0]
        row.update(canonical_input="Muse这次构建通过。", model_output="Muse这次构建通过。",
                   resolved_entities=[{"surface_text": "缪斯", "canonical": "Muse", "source_segment_ids": ["s1"],
                                       "candidate_source": "authorizedContext", "confidence": 0.96}])
        payload = json.loads(row["stage_responses"][0]["request_payload"])
        payload.update(canonical_text=row["canonical_input"], authorized_context=["缪斯 → Muse"])
        row["stage_responses"][0]["request_payload"] = json.dumps(payload, ensure_ascii=False)
        return report, receipts

    def test_verified_entity_mapping_replaces_raw_context_payload(self):
        report, receipts = self.mapped_context_report()
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"])
        payload["authorized_context"] = [self.inputs[0]["context_fixture"]["selected_text"]]
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_entity_mapping_source_ids_origin_and_confidence_cannot_be_forged(self):
        for field, value in [("surface_text", "原文没有的名字"), ("canonical", "UnknownBrand"),
                             ("source_segment_ids", ["s99"]), ("candidate_source", "personalLexicon"),
                             ("confidence", 0.2), ("confidence", True), ("confidence", float("nan"))]:
            report, receipts = self.mapped_context_report()
            report["cases"][0]["resolved_entities"][0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_mapping_cannot_explain_added_currency_or_hidden_deleted_text(self):
        report, receipts = self.mapped_context_report()
        report["cases"][0]["canonical_input"] += "预算16000元。"
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.mapped_context_report()
        report["cases"][0]["resolved_entities"] = []
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.mapped_context_report()
        report["cases"][0]["canonical_segments"][0]["text"] = "遗漏了构建结果"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_unsafe_fixture_cannot_justify_entity_mapping(self):
        report, receipts = self.mapped_context_report()
        self.inputs[0]["context_fixture"]["safety"] = "secure"
        report["cases"][0]["context_fixture"] = e.legacy.expected_context_fixture(self.inputs[0])
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_mapping_replay_preserves_unaffected_original_order_and_text(self):
        self.assertTrue(e.explained_by_mappings("甲缪斯乙缪斯丙", "甲Muse乙Muse丙", [("缪斯", "Muse")]))
        self.assertTrue(e.explained_by_mappings("甲缪斯乙", "甲缪斯乙", [("缪斯", "Muse")]))
        self.assertFalse(e.explained_by_mappings("甲缪斯乙", "乙Muse甲", [("缪斯", "Muse")]))
        self.assertFalse(e.explained_by_mappings("甲缪斯乙", "甲Muse", [("缪斯", "Muse")]))

    def test_final_output_is_bound_to_actual_patch_or_last_review(self):
        for mode in ["light", "standard"]:
            report, receipts = self.report(mode)
            report["cases"][0]["model_output"] = "新增没有来源的结论。"
            self.assertTrue(self.check(report, receipts, mode)[0])

    def test_patch_replay_handles_immutable_positions_and_rejects_overlap(self):
        self.assertEqual(e.apply_recorded_edits("甲乙丙丁", json.dumps({"edits": [
            {"before": "甲", "after": "甲甲"}, {"before": "丁", "after": "戊"}
        ]})), "甲甲乙丙戊")
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("甲乙丙", json.dumps({"edits": [
                {"before": "甲乙", "after": "甲"}, {"before": "乙丙", "after": "丙"}
            ]}))

    def test_patch_replay_separates_shared_context_and_multiple_insertions(self):
        source = "先按装再启动最后检查"
        edits = [{"before": source, "after": "先按装，再启动，最后检查"},
                 {"before": "按装再启动", "after": "安装再启动"}]
        for ordered in [edits, list(reversed(edits))]:
            self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": ordered})), "先安装，再启动，最后检查")
        self.assertEqual(e.apply_recorded_edits("甲乙丙", json.dumps({"edits": [
            {"before": "甲乙", "after": "甲，乙"}, {"before": "乙丙", "after": "，乙丙"}
        ]})), "甲，乙丙")

    def test_patch_replay_rejects_conflicting_insertions_and_overlapping_occurrences(self):
        cases = [
            ("甲乙丙", [{"before": "甲乙", "after": "甲，乙"}, {"before": "乙丙", "after": "。乙丙"}]),
            ("甲乙", [{"before": "甲乙", "after": "丙丁"}, {"before": "甲乙", "after": "甲，乙"}]),
            ("哈哈哈", [{"before": "哈哈", "after": "哈"}]),
            ("甲乙丙", [{"before": "甲", "after": "丁"}, {"before": "缺失", "after": "戊"}]),
        ]
        for source, edits in cases:
            with self.subTest(source=source, edits=edits), self.assertRaises(ValueError):
                e.apply_recorded_edits(source, json.dumps({"edits": edits}))

    def test_patch_replay_unicode_and_boundary_order_match_swift(self):
        source = "👨‍👩‍👧‍👦嗯我今天用e\u0301看结果👍🏽再发送"
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
            {"before": "嗯我今天", "after": "我今天"},
            {"before": "今天用e\u0301看结果👍🏽再发送", "after": "今天用e\u0301，看结果👍🏽，再发送。"}
        ]})), "👨‍👩‍👧‍👦我今天用e\u0301，看结果👍🏽，再发送。")
        self.assertEqual(e.apply_recorded_edits("前e\u0301后", json.dumps({"edits": [
            {"before": "e\u0301", "after": "é"}
        ]})).encode(), "前é后".encode())
        edits = [{"before": "甲乙", "after": "丙丁"}, {"before": "前甲", "after": "前，甲"},
                 {"before": "乙后", "after": "乙。后"}]
        for ordered in [edits, list(reversed(edits))]:
            self.assertEqual(e.apply_recorded_edits("前甲乙后", json.dumps({"edits": ordered})), "前，丙丁。后")

    def test_patch_replay_real_chat_and_code_anchors(self):
        source = "嗯我今天大概七点半到你们不用等我吃饭先吃就行"
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
            {"before": "嗯我今天", "after": "我今天", "kind": "filler"}
        ]})), "我今天大概七点半到你们不用等我吃饭先吃就行")
        source = "部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用"
        changes = [("三步第一跑", "三步，第一跑"), ("swift test第二跑", "swift test，第二跑"),
                   ("swift build短横线c release", "swift build -c release"),
                   ("第三执行scripts斜杠package短横线app点sh", "第三执行scripts/package-app.sh"),
                   ("等一下还有一步", "等一下，还有一步"), ("codesign所以一共四步", "codesign，所以一共四步"),
                   ("四步最后再启动应用", "四步，最后再启动应用")]
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
            {"before": before, "after": after} for before, after in changes
        ]})), "部署要做三步，第一跑swift test，第二跑swift build -c release第三执行scripts/package-app.sh等一下，还有一步要检查codesign，所以一共四步，最后再启动应用")

    def test_actual_modification_reconstruction_keeps_all_requested_changes(self):
        from itertools import product
        values = [""] + ["".join(chars) for size in range(1, 4) for chars in product("甲乙", repeat=size)]
        for before in values:
            for after in values:
                output = before
                for start, end, inserted in reversed(e.actual_modifications(before, after, 0)):
                    output = output[:start] + inserted + output[end:]
                self.assertEqual(output, after, (before, after))

    def test_editing_protocol_version_is_frozen_in_report_and_payload(self):
        report, receipts = self.report("light")
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.expected["editing_prompt_version"] = 2
        report["editing_prompt_version"] = 2
        self.assertTrue(self.check(report, receipts, "light")[0])
        payload = json.loads(report["cases"][0]["stage_responses"][0]["request_payload"])
        payload["schema_version"] = 2
        report["cases"][0]["stage_responses"][0]["request_payload"] = json.dumps(payload)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report["editing_prompt_version"] = 1
        self.assertTrue(self.check(report, receipts, "light")[0])

    def reviewed_light_report(self, kind="correction", with_review=True):
        source, before, after = {
            "word": ("周五按装软件。", "按装", "安装"),
            "correction": ("预算一万六，不对，一万五。", "一万六，不对，一万五", "一万五"),
            "directive": ("给客户回一下，周五发送第一版。", "给客户回一下，", ""),
            "punctuation": ("周五发送第一版", "第一版", "第一版。"),
        }[kind]
        self.text = source
        self.inputs[0].update(spoken_input=source, segment_texts=[source])
        self.expected["editing_prompt_version"] = 2
        report, receipts = self.report("light")
        report["editing_prompt_version"] = 2
        row = report["cases"][0]
        initial = row["stage_responses"][0]
        initial["response_text"] = json.dumps({"edits": [{"before": before, "after": after, "kind": kind}]}, ensure_ascii=False)
        initial_payload = json.loads(initial["request_payload"])
        initial_payload["schema_version"] = 2
        initial["request_payload"] = json.dumps(initial_payload, ensure_ascii=False)
        row["model_output"] = e.apply_recorded_edits(source, initial["response_text"])
        receipts[0]["response_text_sha256"] = e.legacy.sha256_text(initial["response_text"])
        if with_review:
            review = copy.deepcopy(initial)
            review.update(task="voicePolishAnalyze", response_text='{"edits":[]}', attempt_ordinal=2)
            payload = json.loads(self.payload("light", row["model_output"]))
            payload.update(schema_version=2, changes=[
                {"removed": source[start:end], "inserted": inserted}
                for start, end, inserted in e.actual_modifications(source, row["model_output"], 0)
            ])
            review["request_payload"] = json.dumps(payload, ensure_ascii=False)
            row["stage_responses"].append(review)
            row.update(llm_call_count=2, llm_attempt_count=2)
            receipt = copy.deepcopy(receipts[0])
            receipt.update(request_ordinal=2, llm_task="voicePolishAnalyze", provider_response_id="unit-test-only-review-2",
                           response_text_sha256=e.legacy.sha256_text(review["response_text"]))
            receipt["request_binding_sha256"] = e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", 2, "e" * 64)
            receipts.append(receipt)
        return report, receipts

    def test_v2_word_correction_and_directive_require_one_light_confirmation(self):
        for kind in ["word", "correction", "directive"]:
            report, receipts = self.reviewed_light_report(kind)
            self.assertEqual(self.check(report, receipts, "light"), ([], []), kind)
            report, receipts = self.reviewed_light_report(kind, with_review=False)
            self.assertTrue(self.check(report, receipts, "light")[0], kind)

    def test_v2_mechanical_edits_remain_one_call_and_v1_remains_compatible(self):
        report, receipts = self.reviewed_light_report("punctuation", with_review=False)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report, receipts = self.reviewed_light_report("punctuation")
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.reviewed_light_report("word", with_review=False)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 1
        payload = json.loads(report["cases"][0]["stage_responses"][0]["request_payload"])
        payload["schema_version"] = 1
        report["cases"][0]["stage_responses"][0]["request_payload"] = json.dumps(payload)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report, receipts = self.reviewed_light_report()
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 1
        for stage in report["cases"][0]["stage_responses"]:
            payload = json.loads(stage["request_payload"]); payload["schema_version"] = 1
            stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_nonempty_confirmation_cannot_be_applied_or_called_success(self):
        for resulting_output in ["预算一万五。", "预算一万四。"]:
            report, receipts = self.reviewed_light_report()
            row = report["cases"][0]
            review = row["stage_responses"][1]
            review["response_text"] = json.dumps({"edits": [{"before": "一万五", "after": "一万四", "kind": "content", "evidence": self.text}]})
            receipts[1]["response_text_sha256"] = e.legacy.sha256_text(review["response_text"])
            row["model_output"] = resulting_output
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_confirmation_payload_is_bound_to_original_actual_draft_and_changes(self):
        for field, value in [("canonical_text", "偷偷更换原文"), ("draft_text", "另一份稿"),
                             ("changes", []), ("changes", [{"removed": "六", "inserted": "五"}]),
                             ("changes", [{"removed": "不存在", "inserted": ""}]),
                             ("changes", None)]:
            report, receipts = self.reviewed_light_report()
            review = report["cases"][0]["stage_responses"][1]
            payload = json.loads(review["request_payload"]); payload[field] = value
            review["request_payload"] = json.dumps(payload)
            self.assertTrue(self.check(report, receipts, "light")[0], field)
        report, receipts = self.reviewed_light_report()
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"]); payload["draft_text"] = "预先提供的成稿"
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_extra_wrong_or_missing_audited_stages_cannot_pass(self):
        for task in ["voicePolishRender", "voicePolishRepair", "voicePolishFast"]:
            report, receipts = self.reviewed_light_report()
            report["cases"][0]["stage_responses"][1]["task"] = receipts[1]["llm_task"] = task
            self.assertTrue(self.check(report, receipts, "light")[0], task)
        report, receipts = self.reviewed_light_report()
        self.assertTrue(self.check(report, receipts[:1], "light")[0])
        row = report["cases"][0]
        row["stage_responses"].append(copy.deepcopy(row["stage_responses"][1]))
        row.update(llm_call_count=3, llm_attempt_count=3)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_hard_gate_fallback_may_stop_before_review_but_not_claim_success(self):
        report, receipts = self.reviewed_light_report(with_review=False)
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, hard_validation_codes=["missingProtectedFact"], failure_reason="validationFailed")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        row["llm_attempt_count"] = 3
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_failed_review_keeps_real_attempt_and_successful_first_receipt(self):
        report, receipts = self.reviewed_light_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, llm_call_count=1, failure_reason="timeout")
        row["stage_responses"][1].update(status="failed", response_text="", failure_reason="请求超时", latency_milliseconds=400)
        failures, quality = self.check(report, receipts[:1], "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        self.assertTrue(self.check(report, receipts, "light")[0])
        del row["stage_responses"][1]["latency_milliseconds"]
        self.assertTrue(self.check(report, receipts[:1], "light")[0])

    def test_v2_review_rejection_is_auditable_fallback_not_partial_delivery(self):
        report, receipts = self.reviewed_light_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        review = row["stage_responses"][1]
        review["response_text"] = json.dumps({"edits": [{"before": "一万五", "after": "一万六", "kind": "content", "evidence": self.text}]})
        receipts[1]["response_text_sha256"] = e.legacy.sha256_text(review["response_text"])
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        row["model_output"] = "预算一万五。"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_changes_must_explain_all_deletions_insertions_and_original_order(self):
        source, draft = "甲甲乙丙丁", "甲乙，丁"
        changes = [{"removed": "甲", "inserted": ""}, {"removed": "丙", "inserted": "，"}]
        self.assertTrue(e.complete_change_evidence(source, draft, changes))
        self.assertFalse(e.complete_change_evidence(source, draft, changes[:1]))
        self.assertFalse(e.complete_change_evidence(source, draft, list(reversed(changes))))
        self.assertFalse(e.complete_change_evidence(source, draft, [{"removed": "", "inserted": ""}]))
        self.assertTrue(e.complete_change_evidence("e\u0301", "é", []))

    def upgrade_report_to_v3(self, report):
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 3
        row = report["cases"][0]
        source = row["pre_resolution_canonical_input"]
        split = max(1, len(source) // 2)
        parts = [source[:split], source[split:]]
        self.inputs[0]["segment_texts"] = parts
        row.update(segment_texts=parts, segment_count=2, canonical_segments=[
            {"id": f"s{index}", "text": text, "is_final": True} for index, text in enumerate(parts, 1)
        ])
        for stage in row["stage_responses"]:
            payload = json.loads(stage["request_payload"])
            payload.update(schema_version=3, source_segments=[
                {"id": segment["id"], "text": segment["text"]} for segment in row["canonical_segments"]
            ])
            stage["request_payload"] = json.dumps(payload, ensure_ascii=False)

    def test_v3_every_polish_stage_preserves_ordered_source_segments(self):
        for mode in ["light", "standard"]:
            report, receipts = self.report(mode)
            self.upgrade_report_to_v3(report)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
        report, receipts = self.reviewed_light_report("word")
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v3_segment_omission_reorder_rewrite_and_forged_ids_are_rejected_per_stage(self):
        for mode in ["light", "standard"]:
            for index in [0, 1]:
                report, receipts = self.reviewed_light_report("word") if mode == "light" else self.report(mode)
                self.upgrade_report_to_v3(report)
                payload = json.loads(report["cases"][0]["stage_responses"][index]["request_payload"])
                segments = payload["source_segments"]
                invalid = [None, [], segments[:1], list(reversed(segments)),
                           [{**segments[0], "id": "other"}, segments[1]],
                           [segments[0], {**segments[1], "text": "改写过的下一主题"}],
                           [segments[0], segments[0]],
                           [{"id": "s1", "text": "".join(x["text"] for x in segments)}],
                           [{**segments[0], "summary": "额外摘要"}, segments[1]],
                           {"s1": segments[0]["text"], "s2": segments[1]["text"]}]
                for replacement in invalid:
                    changed = copy.deepcopy(report)
                    changed_payload = {**payload, "source_segments": replacement}
                    changed["cases"][0]["stage_responses"][index]["request_payload"] = json.dumps(changed_payload, ensure_ascii=False)
                    self.assertTrue(self.check(changed, receipts, mode)[0], (mode, index, replacement))
                del payload["source_segments"]
                report["cases"][0]["stage_responses"][index]["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, index, "missing"))

    def test_v3_segments_supplement_full_canonical_without_replacing_entity_evidence(self):
        report, receipts = self.mapped_context_report()
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"])
        self.assertTrue(payload["canonical_text"].startswith("Muse"))
        self.assertTrue(payload["source_segments"][0]["text"].startswith("缪斯"))
        payload["canonical_text"] = payload["source_segments"][0]["text"]
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v3_word_risk_still_requires_confirmation_and_empty_review(self):
        report, receipts = self.reviewed_light_report("word", with_review=False)
        self.upgrade_report_to_v3(report)
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.reviewed_light_report("word")
        self.upgrade_report_to_v3(report)
        row = report["cases"][0]
        row["stage_responses"][1]["response_text"] = '{"edits":[{"before":"软件","after":"工具","kind":"content","evidence":"软件"}]}'
        receipts[1]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][1]["response_text"])
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v1_and_v2_do_not_require_new_v3_source_segment_field(self):
        report, receipts = self.report("standard")
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        report, receipts = self.reviewed_light_report("word")
        for stage in report["cases"][0]["stage_responses"]:
            self.assertNotIn("source_segments", json.loads(stage["request_payload"]))
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v3_source_correction_replays_local_change_with_distant_literal_evidence(self):
        before, after, evidence = "小李负责看是否有重复报名", "小赵负责看是否有重复报名", "重复报名的检查改由小赵来做"
        middle = "其他事项逐项记录，当前负责人安排不要遗漏。" * 20
        source = before + "。\n\n" + middle + "\n\n" + evidence
        self.assertLessEqual(len(source), 1000)
        response = json.dumps({"edits": [{"before": before, "after": after, "kind": "correction", "evidence": evidence}]})
        self.assertEqual(e.apply_recorded_edits(source, response, editing_prompt_version=3), after + "。\n\n" + middle + "\n\n" + evidence)
        for version in (1, 2):
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(source, response, editing_prompt_version=version)

    def test_v3_source_correction_rejects_missing_foreign_long_or_non_correction_evidence(self):
        long_evidence = "改由小赵" + "说明" * 96
        for tail, evidence in [("检查改由小赵来做。", None), ("检查改由小赵来做。", "不存在的检查改由小赵来做"),
                               ("检查交给小赵来做。", "检查交给小赵来做。"), (long_evidence, long_evidence)]:
            with self.subTest(evidence=evidence), self.assertRaises(ValueError):
                e.apply_recorded_edits("小李负责检查。" + tail, json.dumps({"edits": [
                    {"before": "小李负责检查", "after": "小赵负责检查", "kind": "correction", "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_source_correction_cannot_stitch_evidence_or_exceed_one_local_word_change(self):
        cases = [("阿文负责检查", "赵敏负责检查", "改由赵老师处理，敏同学协助确认"),
                 ("甲检查乙发送", "乙发送甲检查", "改成乙发送甲检查"),
                 ("小李检查小王发送", "小赵检查小刘发送", "改成小赵检查小刘发送"),
                 ("甲" * 33, "乙", "改成乙"), ("甲", "乙" * 9, "改成" + "乙" * 9),
                 ("说明" * 48 + "甲", "说明" * 48 + "乙", "改成" + "说明" * 48 + "乙")]
        for before, after, evidence in cases:
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before + "。" + evidence, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": "correction", "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_source_correction_cannot_damage_technical_characters(self):
        for before, after in [("foo_bar", "foobar"), ("git --hard", "git hard"), ("/tmp/file", "tmp/file"),
                              ("main.swift", "mainswift"), ("10:30", "1030"), ("A+B", "AB")]:
            evidence = "改成" + after
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before + "。" + evidence, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": "correction", "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_newlines_and_paragraph_word_membership_cannot_be_changed(self):
        for newline in ["\n", "\r", "\r\n", "\v", "\f", "\x85", "\u2028", "\u2029"]:
            for before, after in [("甲" + newline + "乙丙", "甲乙丙"), ("甲" + newline + "乙丙", "甲乙" + newline + "丙"),
                                  ("甲乙丙", "甲" + newline + "乙丙")]:
                with self.subTest(newline=repr(newline), before=before), self.assertRaises(ValueError):
                    e.apply_recorded_edits(before, json.dumps({"edits": [
                        {"before": before, "after": after, "kind": "punctuation"}
                    ]}), editing_prompt_version=3)
        for before, after, kind in [("我\r\n我我今天", "我我\r\n今天", "stutter"),
                                   ("甲\r\n乙丙，不对", "甲乙\r\n丙", "correction"),
                                   ("小李\r\n负责检查", "小赵负责\r\n检查", "correction"),
                                   ("按装\r\n软件", "安\r\n装软件", "word")]:
            evidence = "改由小赵负责检查"
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                e.apply_recorded_edits(before + "。" + evidence, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": kind, "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_preserves_paragraphs_and_symbol_punctuation_support_without_rewriting_old_versions(self):
        before, after, evidence = "小李负责\n检查重复报名", "小赵负责\n检查重复报名", "重复报名检查改由小赵来做"
        self.assertEqual(e.apply_recorded_edits(before + "。\n\n" + evidence, json.dumps({"edits": [
            {"before": before, "after": after, "kind": "correction", "evidence": evidence}
        ]}), editing_prompt_version=3), after + "。\n\n" + evidence)
        command = "swift build短横线c release第三执行"
        self.assertEqual(e.apply_recorded_edits(command, json.dumps({"edits": [
            {"before": command, "after": "swift build -c release，第三执行", "kind": "symbol"}
        ]}), editing_prompt_version=3), "swift build -c release，第三执行")
        for version in (1, 2):
            before, after = "甲\r\n乙丙", "甲乙\r\n丙"
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": after, "kind": "punctuation"}
            ]}), editing_prompt_version=version), after)
            source = "预算一万六，不对，一万五。"
            self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
                {"before": source, "after": "预算一万五。", "kind": "correction"}
            ]}), editing_prompt_version=version), "预算一万五。")

    def test_v3_source_correction_report_requires_real_empty_confirmation_and_valid_evidence(self):
        report, receipts = self.reviewed_light_report("correction")
        self.text = "小李负责检查。" + "其他事项保持。" * 40 + "检查改由小赵来做。"
        self.inputs[0].update(spoken_input=self.text, segment_texts=[self.text])
        row = report["cases"][0]
        row.update(spoken_input=self.text, pre_resolution_canonical_input=self.text, canonical_input=self.text)
        edit = {"before": "小李负责检查", "after": "小赵负责检查", "kind": "correction", "evidence": "检查改由小赵来做"}
        row["stage_responses"][0]["response_text"] = json.dumps({"edits": [edit]})
        row["model_output"] = e.apply_recorded_edits(self.text, row["stage_responses"][0]["response_text"], editing_prompt_version=3)
        row["stage_responses"][0]["request_payload"] = self.payload("light")
        payload = json.loads(self.payload("light", row["model_output"]))
        payload["changes"] = [{"removed": "李", "inserted": "赵"}]
        row["stage_responses"][1]["request_payload"] = json.dumps(payload)
        receipts[0]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][0]["response_text"])
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        bad = copy.deepcopy(report)
        bad["cases"][0]["stage_responses"] = bad["cases"][0]["stage_responses"][:1]
        bad["cases"][0].update(llm_call_count=1, llm_attempt_count=1)
        self.assertTrue(self.check(bad, receipts[:1], "light")[0])
        edit["evidence"] = "源文没有的改由小赵"
        row["stage_responses"][0]["response_text"] = json.dumps({"edits": [edit]})
        receipts[0]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][0]["response_text"])
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_independent_six_joint_segment_forgery_counterexamples_are_rejected(self):
        for mode in ["light", "standard"]:
            report, receipts = self.report(mode)
            self.upgrade_report_to_v3(report)
            variants = [
                [{"id": "forged-only", "text": self.text}],
                [{"id": "s1", "text": self.text[:1]}, {"id": "s2", "text": self.text[1:]}],
                [{"id": "forged-0", "text": self.inputs[0]["segment_texts"][0]},
                 {"id": "forged-1", "text": self.inputs[0]["segment_texts"][1]}],
            ]
            self.assertEqual(self.check(report, receipts, mode), ([], []))
            for replacement in variants:
                changed = copy.deepcopy(report)
                changed["cases"][0]["canonical_segments"] = replacement
                for stage in changed["cases"][0]["stage_responses"]:
                    payload = json.loads(stage["request_payload"])
                    payload["source_segments"] = replacement
                    stage["request_payload"] = json.dumps(payload)
                failures, _ = self.check(changed, receipts, mode)
                self.assertTrue(any("冻结输入的确定性构造" in failure for failure in failures), (mode, replacement))

    def test_frozen_envelope_preserves_real_boundaries_and_final_paragraph_fallback(self):
        item = copy.deepcopy(self.inputs[0])
        item.update(spoken_input="第一段。\n\n目标用户是老师。", segment_texts=["第一段。", "目标用户是老师。"])
        canonical, segments = e.frozen_input_envelope(item)
        self.assertEqual(canonical, item["spoken_input"])
        self.assertEqual(segments, [{"id": "s1", "text": item["spoken_input"]}])
        item["segment_texts"] = ["第一段。\n\n", "目标用户是老师。"]
        self.assertEqual(e.frozen_input_envelope(item)[1], [
            {"id": "s1", "text": "第一段。\n\n"}, {"id": "s2", "text": "目标用户是老师。"}
        ])

    def test_frozen_terminology_mapping_and_cross_segment_partition_follow_production(self):
        cases = [
            (["试用 Type less。", "再确认。"], ["试用 Typeless。", "再确认。"]),
            (["试用 TYPE-LESS。", "再确认。"], ["试用 Typeless。", "再确认。"]),
            (["Type ", "less"], ["Type", "less"]),
            (["👨‍👩‍👧‍👦Type ", "less"], ["👨‍👩‍👧‍👦Type", "less"]),
        ]
        for raw, canonical in cases:
            item = copy.deepcopy(self.inputs[0])
            item.update(spoken_input="".join(raw), segment_texts=raw,
                        preconditions=["术语库中已确认 Type less → Typeless"])
            self.assertEqual(e.frozen_input_envelope(item), ("".join(canonical), [
                {"id": f"s{index}", "text": text} for index, text in enumerate(canonical, 1)
            ]), raw)
        self.assertEqual(e.composed_characters("e\u0301👍🏽\r\n甲"), ("e\u0301", "👍🏽", "\r\n", "甲"))
        self.assertEqual(e.applying_fixture_terminology("A B", ["已确认 A B → B C", "已确认 B C → D E"]), "B C")

    def test_v3_full_report_accepts_frozen_terminology_and_final_text_fallback(self):
        for raw, spoken, preconditions, canonical, segments in [
            (["試用 TYPE-LESS。", "再确认。"], "試用 TYPE-LESS。再确认。", ["已确认 Type less → Typeless"],
             "試用 Typeless。再确认。", [{"id": "s1", "text": "試用 Typeless。"}, {"id": "s2", "text": "再确认。"}]),
            (["第一段。", "目标用户是老师。"], "第一段。\n\n目标用户是老师。", [],
             "第一段。\n\n目标用户是老师。", [{"id": "s1", "text": "第一段。\n\n目标用户是老师。"}]),
        ]:
            self.text = spoken
            self.inputs[0].update(spoken_input=spoken, segment_texts=raw, preconditions=preconditions)
            report, receipts = self.report("standard")
            self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 3
            row = report["cases"][0]
            row.update(segment_count=len(raw), canonical_input=canonical, pre_resolution_canonical_input=canonical,
                       canonical_segments=segments, model_output=canonical)
            row["stage_responses"][0]["response_text"] = canonical
            receipts[0]["response_text_sha256"] = e.legacy.sha256_text(canonical)
            for index, stage in enumerate(row["stage_responses"]):
                payload = json.loads(stage["request_payload"])
                payload.update(schema_version=3, canonical_text=canonical, source_segments=segments)
                if index:
                    payload["draft_text"] = canonical
                stage["request_payload"] = json.dumps(payload)
            self.assertEqual(self.check(report, receipts, "standard"), ([], []), raw)

    def test_context_mapping_cannot_justify_jointly_renamed_original_segment_ids(self):
        report, receipts = self.mapped_context_report()
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        row = report["cases"][0]
        replacement = [{"id": "forged-1", "text": row["canonical_segments"][0]["text"]},
                       {"id": "forged-2", "text": row["canonical_segments"][1]["text"]}]
        row["canonical_segments"] = replacement
        row["resolved_entities"][0]["source_segment_ids"] = ["forged-1"]
        payload = json.loads(row["stage_responses"][0]["request_payload"])
        payload["source_segments"] = replacement
        row["stage_responses"][0]["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_independent_symbol_token_join_counterexamples_and_valid_punctuation(self):
        for before, after in [("a点b c", "a.bc"), ("v点2 api", "v.2api")]:
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": "symbol"}
                ]}), editing_prompt_version=3)
        for before, after, kind in [("a.b c", "a.bc", "punctuation"), ("v.2 api", "v.2api", "punctuation")]:
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": kind}
                ]}), editing_prompt_version=3)
        for before, after in [("a点b c", "a.b，c"), ("v点2 api", "v.2，api")]:
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": after, "kind": "symbol"}
            ]}), editing_prompt_version=3), after)

    def test_stage_order_and_full_review_cannot_be_skipped(self):
        report, receipts = self.report("standard")
        report["cases"][0]["stage_responses"].reverse()
        self.assertTrue(self.check(report, receipts, "standard")[0])
        report, receipts = self.report("standard")
        report["cases"][0]["stage_responses"].pop()
        report["cases"][0].update(llm_call_count=1, llm_attempt_count=1)
        self.assertTrue(self.check(report, receipts[:1], "standard")[0])

    def v4_report(self, source, *, mode="light", initial_edits=None, reviews=()):
        self.text = source
        self.inputs[0].update(spoken_input=source, segment_texts=[source])
        report, old_receipts = self.report(mode)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 4
        row = report["cases"][0]
        template = copy.deepcopy(row["stage_responses"][0])
        row["stage_responses"] = []
        row["repair_attempt_count"] = 0
        receipts = []
        draft = source
        documents = [source if mode == "standard" else {"edits": initial_edits or []}, *reviews]
        for index, response in enumerate(documents):
            payload = json.loads(self.payload(mode, draft if index else None))
            payload.update(schema_version=4, source_segments=[{"id": "s1", "text": source}])
            if index:
                payload["changes"] = [{"removed": source[a:b], "inserted": c}
                                      for a, b, c in e.actual_modifications(source, draft, 0)]
            stage = copy.deepcopy(template)
            stage.update(attempt_ordinal=index + 1, task=("voicePolishAnalyze" if index else
                         "voicePolishFast" if mode == "light" else "voicePolishRender"),
                         request_payload=json.dumps(payload, ensure_ascii=False),
                         response_text=response if isinstance(response, str) else json.dumps(response, ensure_ascii=False))
            row["stage_responses"].append(stage)
            receipt = copy.deepcopy(old_receipts[0])
            receipt.update(request_ordinal=index + 1, llm_task=stage["task"],
                           provider_response_id=f"unit-test-only-v4-{index + 1}",
                           response_text_sha256=e.legacy.sha256_text(stage["response_text"]),
                           request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", index + 1, "e" * 64))
            receipts.append(receipt)
            if mode == "light" or index:
                if index and response["edits"]:
                    row["repair_attempt_count"] += 1
                draft = e.apply_recorded_edits(draft, json.dumps({"edits": response["edits"]}),
                    editing_prompt_version=4 if mode == "light" else None,
                    original_source=source, allows_reviewed_directives=True)
        row.update(model_output=draft, llm_call_count=len(documents), llm_attempt_count=len(documents))
        return report, receipts

    def test_v4_real_mislabeled_mechanical_combinations_and_historical_replay(self):
        cases = [
            ("嗯我今天大概七点半到你们不用等我吃饭先吃就行", "我今天大概七点半到，你们不用等我吃饭，先吃就行。"),
            ("部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用", "部署要做三步：第一，跑 swift test；第二，跑 swift build -c release；第三，执行 scripts/package-app.sh。等一下，还有一步要检查 codesign，所以一共四步，最后再启动应用。"),
            ("嗯我我今天跑swift build短横线c release然后看结果", "我今天跑 swift build -c release，然后看结果。")]
        for before, after in cases:
            for kind in ["punctuation", "filler", "symbol", "word", "correction"]:
                edit = {"before": before, "after": after, "kind": kind}
                self.assertEqual(e.v4_requires_semantic_review([edit]), "我我" in before, (before, kind))
                self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4), after)
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [{"before": before, "after": after, "kind": "punctuation"}]}), editing_prompt_version=3)
        report, receipts = self.v4_report(cases[0][0], initial_edits=[{"before": cases[0][0], "after": cases[0][1], "kind": "word"}])
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v4_mechanical_proof_rejects_fact_deletion_token_join_and_paragraph_moves(self):
        for before, after in [("嗯a点b c", "a.bc"), ("v点2 api", "v.2api"), ("swift test", "swifttest"),
                              ("swift build短横线c release", "swift build -crelease"),
                              ("嗯明天小李负责发送", "明天发送。"), ("金额1212", "金额12"),
                              ("嗯甲乙\n丙", "甲\n乙丙"), ("甲\r\n乙丙", "甲乙\r\n丙")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit]), before)
            with self.assertRaises(ValueError, msg=before):
                e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4)
        for before, after in [("1212", "12"), ("api api", "api"), ("很好，很好", "很好")]:
            self.assertTrue(e.v4_requires_semantic_review([{"before": before, "after": after, "kind": "stutter"}]))

    def test_v4_filler_allows_plain_punctuation_but_preserves_dotfiles_and_embedded_dots(self):
        for before in ["嗯.参数", "嗯:参数"]:
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": "参数", "kind": "filler"}]}), editing_prompt_version=4), "参数")
        for before, after in [("嗯 .env", "env"), ("嗯 .gitignore", "gitignore"), ("嗯 a.b", "ab")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit]))
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4)
        self.assertEqual(e.apply_recorded_edits("嗯 .env然后检查", json.dumps({"edits": [
            {"before": "嗯 .env然后检查", "after": ".env，然后检查。", "kind": "punctuation"}]}), editing_prompt_version=4), ".env，然后检查。")

    def test_v4_filler_exemption_uses_real_left_boundary_and_extra_right_boundary_for_e(self):
        for source, before, after in [("嗯我今天发。", "嗯我今天发。", "我今天发。"),
                                      ("先说，呃今天发。", "呃今天发。", "今天发。"),
                                      ("嗯呃我今天发。", "嗯呃我今天发。", "我今天发。"),
                                      ("额，今天发。", "额，今天发。", "今天发。")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertEqual(e.v4_requires_semantic_review([edit], source), "呃" in before, source)
            self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4), source.replace(before, after))
        for source in ["额外安排复查。", "额度要保留。", "本周额外安排复查。", "金额待定。", "声音嗯要保留。"]:
            removed = "额" if "额" in source else "嗯"
            for kind in ["filler", "punctuation"]:
                edit = {"before": removed, "after": "", "kind": kind}
                self.assertTrue(e.v4_requires_semantic_review([edit], source), (source, kind))
                if kind == "punctuation":
                    with self.assertRaises(ValueError):
                        e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4)
                else:
                    self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4), source.replace(removed, ""))

    def test_v4_narrow_anchors_preserve_adjacent_real_technical_token_boundaries(self):
        for source, before, after in [("运行swift test", " ", ""), ("调用api", "ap", "ap "),
                                      ("运行swift test", "t ", "t"), ("使用.env", ".", ""), ("使用a.b", ".", "")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit], source), source)
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4)

    def test_v4_adjacent_repeated_name_or_stutter_requires_semantic_review_even_when_mislabeled(self):
        for before, after in [("莉莉负责审核。", "莉负责审核。"), ("宝宝今天到了。", "宝今天到了。"), ("我我今天发。", "我今天发。")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit], before))
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4), after)
            report, receipts = self.v4_report(before, initial_edits=[edit])
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v4_wu_and_e_deletions_are_applicable_previews_but_never_filler_exemptions(self):
        for before, after in [("唔可以退款", "可以退款"), ("唔可以取消订单", "可以取消订单"),
                              ("呃钱", "钱"), ("先说，呃今天发。", "先说，今天发。")]:
            for kind in ("filler", "punctuation"):
                edit = {"before": before, "after": after, "kind": kind}
                self.assertTrue(e.v4_requires_semantic_review([edit], before), (before, kind))
                self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4), after)
                report, receipts = self.v4_report(before, initial_edits=[edit])
                self.assertTrue(self.check(report, receipts, "light")[0], (before, kind))
        source = "嗯唔可以退款"
        edit = {"before": source, "after": "唔可以退款", "kind": "punctuation"}
        self.assertFalse(e.v4_requires_semantic_review([edit], source))
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4), "唔可以退款")

    def test_v4_batch_token_proof_covers_composed_space_deletions_and_mixed_semantic_edits(self):
        spaces = [{"before": "swift ", "after": "swift", "kind": "punctuation"},
                  {"before": " test", "after": "test", "kind": "punctuation"}]
        source = "运行swift  test"
        self.assertTrue(e.v4_requires_semantic_review(spaces, source))
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(source, json.dumps({"edits": spaces}), editing_prompt_version=4)
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("按装后运行swift  test", json.dumps({"edits": [
                {"before": "按装", "after": "安装", "kind": "word"}, *spaces]}), editing_prompt_version=4)
        self.assertEqual(e.apply_recorded_edits("按装后运行swift test", json.dumps({"edits": [
            {"before": "按装", "after": "安装", "kind": "word"},
            {"before": "运行swift test", "after": "运行 swift test。", "kind": "punctuation"}]}), editing_prompt_version=4), "安装后运行 swift test。")

    def test_v4_combined_proof_keeps_unicode_paragraphs_and_rejects_partial_application(self):
        before = "👨‍👩‍👧‍👦，嗯今天用e\u0301看结果👍🏽\r\n再运行scripts斜杠app点sh"
        after = "👨‍👩‍👧‍👦，今天用 e\u0301，看结果👍🏽。\r\n再运行 scripts/app.sh。"
        self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
            {"before": before, "after": after, "kind": "punctuation"}]}), editing_prompt_version=4), after)
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("嗯今天运行swift test", json.dumps({"edits": [
                {"before": "嗯今天", "after": "今天，", "kind": "punctuation"},
                {"before": "swift test", "after": "swifttest", "kind": "punctuation"}]}), editing_prompt_version=4)

    def test_v4_unpunctuated_directive_uses_actual_short_deletion_and_explicit_review_permission(self):
        source, after = "帮我整理一下明天小李负责发材料。", "明天小李负责发材料。"
        response = json.dumps({"edits": [{"before": source, "after": after, "kind": "directive"}]})
        self.assertTrue(e.v4_requires_semantic_review(json.loads(response)["edits"]))
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(source, response, editing_prompt_version=4)
        self.assertEqual(e.apply_recorded_edits(source, response, editing_prompt_version=4, allows_reviewed_directives=True), after)
        for before, output in [("整理" * 17 + "正文", "正文"), ("请整理甲并润色乙", "甲乙"),
                               ("帮我整理甲乙", "乙甲"), ("帮我整理正文", "新正文"), ("帮我整理。", "。")]:
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [{"before": before, "after": output, "kind": "directive"}]}),
                    editing_prompt_version=4, allows_reviewed_directives=True)

    def test_v4_reviewed_source_correction_can_anchor_punctuated_draft_without_merging_tokens(self):
        source = "阿文负责复查重复报名\n重复报名的复查改由阿宁来做"
        draft = "阿文负责复查重复报名。\n重复报名的复查改由阿宁来做。"
        edits = [{"before": "阿文负责复查重复报名。", "after": "阿宁负责复查重复报名。", "kind": "correction",
                  "evidence": "重复报名的复查改由阿宁来做"}]
        self.assertEqual(e.apply_recorded_edits(draft, json.dumps({"edits": edits}), editing_prompt_version=4,
            original_source=source), "阿宁负责复查重复报名。\n重复报名的复查改由阿宁来做。")
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(draft, json.dumps({"edits": edits}), editing_prompt_version=3, original_source=source)
        for original, actual in [("阿文负责 api test", "阿文负责 apitest。"), ("阿文负责 a.b c", "阿文负责 a.bc。"),
                                 ("阿文负责\n复查", "阿文负责复查。"), ("阿文负责其他任务", "阿文负责复查。")]:
            evidence = "复查改由阿宁来做"
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(actual, json.dumps({"edits": [{"before": actual,
                    "after": actual.replace("阿文", "阿宁"), "kind": "correction", "evidence": evidence}]}),
                    editing_prompt_version=4, original_source=original + "\n" + evidence)

    def test_v4_source_risk_requires_review_even_when_initial_edits_empty(self):
        for source in ["帮我整理一下明天发。", "给客户回一下材料已收到。", "预算说错改成一万六。"]:
            report, receipts = self.v4_report(source)
            self.assertTrue(self.check(report, receipts, "light")[0], source)
            report, receipts = self.v4_report(source, reviews=[{"source_roles": [], "edits": []}])
            self.assertEqual(self.check(report, receipts, "light"), ([], []), source)

    def test_v4_roles_require_unique_literal_source_quote_and_target_evidence(self):
        source = "帮我整理一下，发给客户。"
        valid = {"source_roles": [{"quote": "帮我整理一下", "role": "current_editor", "target_evidence": "帮我"}], "edits": []}
        self.assertEqual(e.decode_v4_review(json.dumps(valid), source), valid)
        for field, value in [("quote", "不存在"), ("quote", "，"), ("quote", ""),
                             ("quote", "甲" * 193), ("role", "invented"), ("target_evidence", ""),
                             ("target_evidence", "模型推断的对象"), ("target_evidence", "甲" * 193)]:
            changed = copy.deepcopy(valid); changed["source_roles"][0][field] = value
            with self.assertRaises(ValueError, msg=field):
                e.decode_v4_review(json.dumps(changed), source)
        with self.assertRaises(ValueError):
            e.decode_v4_review(json.dumps(valid), source + source)
        changed = copy.deepcopy(valid); changed["source_roles"] *= 2
        with self.assertRaises(ValueError):
            e.decode_v4_review(json.dumps(changed), source)
        with self.assertRaises(ValueError):
            e.decode_v4_review('{"edits":[]}', source)

    def test_v4_current_editor_residue_cannot_pass_empty_review_but_recipient_or_uncertain_can(self):
        source = "帮我整理一下明天发材料。"
        role = {"quote": "帮我整理一下", "role": "current_editor", "target_evidence": "帮我"}
        for mode in ["light", "standard"]:
            report, receipts = self.v4_report(source, mode=mode, reviews=[{"source_roles": [role], "edits": []}])
            self.assertTrue(self.check(report, receipts, mode)[0])
            for value in ["recipient_content", "uncertain"]:
                report, receipts = self.v4_report(source, mode=mode, reviews=[{"source_roles": [{**role, "role": value}], "edits": []}])
                self.assertEqual(self.check(report, receipts, mode), ([], []))

    def repaired_v4_report(self, mode="light"):
        source, output = "帮我整理一下明天小李发材料。", "明天小李发材料。"
        role = {"quote": "帮我整理一下", "role": "current_editor", "target_evidence": "帮我"}
        edit = {"before": source, "after": output, "kind": "directive" if mode == "light" else "content"}
        if mode == "standard": edit["evidence"] = source
        reviews = [{"source_roles": [role], "edits": [edit]}, {"source_roles": [role], "edits": []}]
        return self.v4_report(source, mode=mode, reviews=reviews)

    def test_v4_both_modes_repair_actual_draft_then_confirm_exact_final_draft(self):
        for mode in ["light", "standard"]:
            report, receipts = self.repaired_v4_report(mode)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
            row = report["cases"][0]
            self.assertEqual(row["repair_attempt_count"], 1)
            self.assertEqual(row["llm_attempt_count"], 3)
            self.assertEqual(row["model_output"], "明天小李发材料。")
            self.assertTrue(self.check(report, receipts[:2], mode)[0])

    def test_v4_repair_missing_confirmation_wrong_task_or_nonempty_third_cannot_pass(self):
        for mode in ["light", "standard"]:
            for mutation in ["missing", "nonempty", "wrong_task", "missing_roles", "extra"]:
                report, receipts = self.repaired_v4_report(mode)
                row = report["cases"][0]
                if mutation == "missing":
                    row["stage_responses"].pop(); receipts.pop()
                    row.update(llm_call_count=2, llm_attempt_count=2)
                elif mutation == "nonempty":
                    stage = row["stage_responses"][2]
                    value = json.loads(stage["response_text"])
                    value["edits"] = [{"before": "明天", "after": "后天", "kind": "word"}]
                    stage["response_text"] = json.dumps(value)
                    receipts[2]["response_text_sha256"] = e.legacy.sha256_text(stage["response_text"])
                elif mutation == "missing_roles":
                    row["stage_responses"][2]["response_text"] = '{"edits":[]}'
                    receipts[2]["response_text_sha256"] = e.legacy.sha256_text('{"edits":[]}')
                elif mutation == "wrong_task":
                    row["stage_responses"][2]["task"] = receipts[2]["llm_task"] = "voicePolishFast"
                else:
                    row["stage_responses"].append(copy.deepcopy(row["stage_responses"][-1]))
                    row.update(llm_call_count=4, llm_attempt_count=4)
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, mutation))

    def test_v4_every_review_binds_source_draft_changes_and_original_segments(self):
        for index in [1, 2]:
            for field, value in [("draft_text", "未经来源的稿"), ("canonical_text", "换掉原文"),
                                 ("changes", [{"removed": "不存在", "inserted": ""}]),
                                 ("source_segments", [{"id": "fake", "text": "fake"}])]:
                report, receipts = self.repaired_v4_report()
                stage = report["cases"][0]["stage_responses"][index]
                payload = json.loads(stage["request_payload"]); payload[field] = value
                stage["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(report, receipts, "light")[0], (index, field))

    def test_v4_failed_local_repair_preserves_attempt_count_and_fallback(self):
        report, receipts = self.v4_report("帮我整理一下明天发材料。", reviews=[{"source_roles": [], "edits": []}])
        row = report["cases"][0]
        invalid = {"source_roles": [], "edits": [{"before": "不存在", "after": "", "kind": "directive"}]}
        row["stage_responses"][1]["response_text"] = json.dumps(invalid)
        receipts[1]["response_text_sha256"] = e.legacy.sha256_text(json.dumps(invalid))
        row.update(fallback_used=True, repair_attempt_count=1, model_output=self.text,
                   hard_validation_codes=["planIntegrityFailure"], failure_reason="validationFailed")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["repair_attempt_count"] = 0
        self.assertTrue(self.check(report, receipts, "light")[0])
        row["repair_attempt_count"] = 1; row["model_output"] = "部分稿"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v4_timeout_confirmation_keeps_actual_attempt_and_receipt_counts(self):
        report, receipts = self.repaired_v4_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, llm_call_count=2, failure_reason="timeout")
        row["stage_responses"][2].update(status="failed", response_text="", failure_reason="请求超时", latency_milliseconds=400)
        failures, quality = self.check(report, receipts[:2], "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        self.assertTrue(self.check(report, receipts, "light")[0])
        payload = json.loads(row["stage_responses"][2]["request_payload"])
        payload["draft_text"] = "伪造的失败请求稿"
        row["stage_responses"][2]["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts[:2], "light")[0])

    def test_input_limit_checks_both_sources_and_rejects_answers(self):
        for source_length, segment_length, valid in [(1000, 1000, True), (1001, 1, False), (1, 1001, False)]:
            inputs = copy.deepcopy(self.inputs)
            inputs[0].update(spoken_input="甲" * source_length, segment_texts=["乙" * segment_length])
            if valid:
                e.validate_inputs(inputs)
            else:
                with self.assertRaises(ValueError): e.validate_inputs(inputs)
        inputs = copy.deepcopy(self.inputs); inputs[0]["reference_output"] = "答案"
        with self.assertRaises(ValueError): e.validate_inputs(inputs)
        with self.assertRaises(ValueError): e.validate_inputs(self.inputs * 2)

    def test_source_paragraph_difference_is_preserved_not_rejected(self):
        inputs = copy.deepcopy(self.inputs)
        inputs[0].update(spoken_input="第一段。\n\n第二段。", segment_texts=["第一段。", "第二段。"])
        before = copy.deepcopy(inputs)
        e.validate_inputs(inputs)
        self.assertEqual(inputs, before)

    def test_frozen_real_dataset_has_separate_suites_and_no_oversize_inputs(self):
        dataset = ROOT / "docs/2026-09-10-Muse-Three-Mode-Quality-Test-Set.json"
        contracts = ROOT / "docs/2026-09-10-Muse-Three-Mode-Quality-Contracts.json"
        document = e.validated_dataset(dataset, e.legacy.sha256_file(dataset), contracts, e.legacy.sha256_file(contracts))
        self.assertEqual(document["suite_counts"], {"acceptance127": 127, "core_regression37": 37, "mode_boundary8": 8})
        self.assertEqual(len(document["inputs"]), 172)
        self.assertEqual(max(len(x["spoken_input"]) for x in document["inputs"]), 907)
        for origin in document["input_provenance"][:127]:
            self.assertEqual(origin["source_input_sha256"], origin["input_sha256"])
        selected = e.selected_inputs(document, ["core-holdout-29", "core-sem-11", "boundary-tiny-01"])
        self.assertEqual(len(selected), 3)
        with self.assertRaises(ValueError): e.selected_inputs(document, ["does-not-exist"])
        with self.assertRaises(ValueError): e.selected_inputs(document, ["micro-01", "micro-01"])
        with self.assertRaises(ValueError): e.validated_dataset(dataset, "0" * 64, contracts, e.legacy.sha256_file(contracts))

    def test_manifest_must_freeze_new_profile_and_contract_hash(self):
        with tempfile.TemporaryDirectory(prefix="MuseThreeModeManifestTests-") as directory:
            path = Path(directory) / "manifest.json"
            requirement = 'identifier "pro.daliang.muse" and certificate leaf = H"unit-test-only"'
            manifest = {"schema_version": 1, "artifact_kind": "muse_voice_polish_quality_candidate",
                        "package_mode": "production", "bundle_id": "pro.daliang.muse",
                        "source_commit": "1" * 40, "source_tree": "2" * 40,
                        "executable_sha256": "3" * 64, "dataset_sha256": "4" * 64,
                        "designated_requirement": requirement,
                        "designated_requirement_sha256": e.legacy.sha256_text(requirement),
                        "quality_profile": "three_mode", "supported_modes": list(e.MODES),
                        "scoring_contract_sha256": "5" * 64}
            path.write_text(json.dumps(manifest))
            args = SimpleNamespace(build_manifest=path, expected_build_manifest_sha256=e.legacy.sha256_file(path),
                                   expected_source_commit="1" * 40, expected_source_tree="2" * 40,
                                   expected_executable_sha256="3" * 64, expected_dataset_sha256="4" * 64,
                                   expected_designated_requirement_sha256=e.legacy.sha256_text(requirement),
                                   expected_contract_sha256="5" * 64)
            self.assertEqual(e.validated_manifest(args)["quality_profile"], "three_mode")
            args.expected_contract_sha256 = "6" * 64
            with self.assertRaises(ValueError): e.validated_manifest(args)

    def test_launch_is_explicit_isolated_and_has_no_authorization_operation(self):
        argv = e.launch_command(Path("/fake/Muse"), Path("/input"), Path("/report"), Path("/audit"),
                                Path("/sandbox"), "light", self.nonce)
        self.assertEqual(argv[:6], ["/usr/bin/sandbox-exec", "-f", "/sandbox", "/usr/bin/nice", "-n", "15"])
        self.assertEqual(argv[argv.index("--mode") + 1], "light")
        self.assertNotIn("--voice-polish-quality-authorize-keychain", argv)
        self.assertIn("Library/Application Support/Muse", e.sandbox_policy())
        self.assertIn("deny file-read* file-write*", e.sandbox_policy())
        self.assertIn("deny device-microphone", e.sandbox_policy())
        with self.assertRaises(ValueError):
            e.launch_command(Path("/fake"), Path("/i"), Path("/r"), Path("/a"), Path("/s"), "automatic", self.nonce)

    def test_run_root_is_exclusive_and_rejects_protected_user_directory(self):
        with tempfile.TemporaryDirectory(prefix="MuseThreeModeRootTests-") as directory:
            with self.assertRaises(ValueError): e.validate_run_root(Path(directory))
            e.validate_run_root(Path(directory) / "unused")
        with self.assertRaises(ValueError): e.validate_run_root(Path("relative-output"))
        protected = Path(e.pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/Muse/forbidden-test-output"
        with self.assertRaises(ValueError): e.validate_run_root(protected)

    def test_actual_package_manifest_writer_binds_separate_contracts(self):
        package = (ROOT / "scripts/package-app.sh").read_text()
        marker = '/usr/bin/python3 - "$QUALITY_BUILD_MANIFEST_PATH" <<\'PY\'\n'
        self.assertEqual(package.count(marker), 1)
        source = package.split(marker, 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory(prefix="MuseThreeModePackageWriterTests-") as directory:
            directory = Path(directory)
            dataset = directory / "dataset.json"
            dataset.write_text(json.dumps({"inputs": self.inputs}))
            contract = directory / "contract.json"
            contract.write_text(json.dumps({"dataset_sha256": e.legacy.sha256_file(dataset), "input_count": 1}))
            output = directory / "manifest.json"
            requirement = 'identifier "pro.daliang.muse"'
            environment = {
                "MUSE_MANIFEST_PACKAGE_MODE": "test", "MUSE_MANIFEST_BUNDLE_ID": "pro.daliang.muse",
                "MUSE_MANIFEST_SOURCE_COMMIT": "1" * 40, "MUSE_MANIFEST_SOURCE_TREE": "2" * 40,
                "MUSE_MANIFEST_EXECUTABLE_SHA256": "3" * 64,
                "MUSE_MANIFEST_DATASET_SHA256": e.legacy.sha256_file(dataset),
                "MUSE_MANIFEST_DESIGNATED_REQUIREMENT": requirement,
                "MUSE_MANIFEST_DESIGNATED_REQUIREMENT_SHA256": e.legacy.sha256_text(requirement),
                "MUSE_MANIFEST_QUALITY_PROFILE": "three_mode", "MUSE_MANIFEST_CONTRACT_PATH": str(contract),
                "MUSE_MANIFEST_DATASET_PATH": str(dataset),
            }
            with patch.dict(os.environ, environment), patch.object(sys, "argv", ["manifest-writer", str(output)]):
                exec(compile(source, "package-app.sh manifest writer", "exec"), {})
            manifest = json.loads(output.read_text())
            self.assertEqual(manifest["quality_profile"], "three_mode")
            self.assertEqual(manifest["supported_modes"], list(e.MODES))
            self.assertEqual(manifest["scoring_contract_sha256"], e.legacy.sha256_file(contract))
            self.assertEqual(manifest["three_mode_input_count"], 1)
            self.assertEqual(output.stat().st_mode & 0o777, 0o444)
            contract.write_text(json.dumps({"dataset_sha256": "0" * 64, "input_count": 1}))
            with patch.dict(os.environ, environment), patch.object(sys, "argv", ["manifest-writer", str(directory / "invalid.json")]):
                with self.assertRaises(SystemExit):
                    exec(compile(source, "package-app.sh manifest writer", "exec"), {})


if __name__ == "__main__":
    unittest.main()
