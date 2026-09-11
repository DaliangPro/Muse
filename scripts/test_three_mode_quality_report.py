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

    def test_stage_order_and_full_review_cannot_be_skipped(self):
        report, receipts = self.report("standard")
        report["cases"][0]["stage_responses"].reverse()
        self.assertTrue(self.check(report, receipts, "standard")[0])
        report, receipts = self.report("standard")
        report["cases"][0]["stage_responses"].pop()
        report["cases"][0].update(llm_call_count=1, llm_attempt_count=1)
        self.assertTrue(self.check(report, receipts[:1], "standard")[0])

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
