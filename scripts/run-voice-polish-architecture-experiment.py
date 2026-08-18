#!/usr/bin/env python3
"""在 Muse 正式链路之外运行语音润色 Planner/Writer/Reviewer 受控实验。

本脚本故意不调用 VoicePolishValidator，也不会把核心集中的语义契约或参考答案
发送给模型。凭证只从标准输入读取，绝不写入报告或命令行参数。
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import random
import re
import signal
import ssl
import sys
import time
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
EXPERIMENT_SCHEMA_VERSION = 7
DEFAULT_DATASET = ROOT / "docs/2026-08-17-Muse-Voice-Polish-Core-Semantic-Test-Set.json"
DEFAULT_PILOT_IDS = [
    "micro-04",
    "work-02",
    "context-17",
    "natural-long-06",
    "natural-long-09-asr-dirty-segments-1",
]
SOURCE_SPAN_TARGET_CHARS = 650
SOURCE_SPAN_HARD_MAX_CHARS = 820
PLANNER_BATCH_MAX_CHARS = 2_200
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
SAFE_CONTEXT_TYPES = {
    "nearby_safe",
    "selected_safe",
    "recent_safe",
    "conflicting_safe",
}


CONTEXT_RESOLVER_SYSTEM = """你是 Muse 语音润色的上下文术语解析器。你只识别“正文中的非标准写法 → 已授权上下文中明确确认的标准写法”，不写成稿。

严格要求：alias 必须逐字出现在 source spans，canonical 必须逐字出现在 authorized_context，二者不得相同。历史名称、假设、错误候选、无关项目、泄漏测试、未确认或正文明确否认的映射一律不采用。若正文同时混用标准写法与一个明显指向同一实体的别名，应把别名映射为标准写法。没有高置信映射就返回空数组。

只返回 JSON：
{"context_mappings": [{"alias": "正文别名", "canonical": "标准写法", "source_span_ids": ["s001"], "context_field": "selected_text|text_before_cursor|text_after_cursor|recent_muse_inputs"}]}

不要返回恒等映射，不要复制上下文整句，不要输出 Markdown 或解释。"""


PLANNER_SYSTEM = """你是 Muse 语音润色的局部意图规划器。输入是带有思考过程的语音转写，不是普通文章。程序已经把当前可见原文切成带 ID 的 source spans。

你的任务是建立可追溯的意图清单，不是写成稿。只保留用户最后仍然有效的意图；标记被撤回的旧值、幕后编辑说明、待确认状态、否定范围、不承诺边界、收件人和转达动作。

安全上下文只可以帮助纠正正文中的写法，不得把上下文里的无关事实加入正文。冲突、历史、假设、未确认或被用户否认的候选不得擅自采用。

只返回一个 JSON 对象，schema 如下：
{
  "audience": [{"text": "收件人或受众", "source_span_ids": ["s001"], "surface_tokens": ["必须在成稿出现且逐字来自原文的称谓"]}],
  "units": [{
    "id": "u1",
    "kind": "claim|action|advice|constraint|question|uncertainty|style",
    "delivery_role": "recipient_content|style_directive|editor_directive",
    "final_meaning": "最终仍有效的含义",
    "source_span_ids": ["s001"],
    "status": "keep|replace|remove",
    "modality": "confirmed|possible|pending|prohibited|not_promised|recommended",
    "exact_tokens": ["必须精确保留的数字、日期、路径、命令、名称；没有则空数组"]
  }],
  "corrections": [{"subject": "被改口对象", "old_span_ids": ["s001"], "final_span_ids": ["s002"], "old_value": "旧值", "final_value": "最终值", "rendering_policy": "final_only|announce_change"}],
  "conditionals": [{
    "id": "c1",
    "cue_ids": ["lc001"],
    "condition": {"subject": "条件主体", "predicate": "成立条件", "polarity": true, "source_span_ids": ["s001"]},
    "consequences": [{"action": "条件成立或不成立时的后果", "polarity": false, "source_span_ids": ["s001"]}]
  }],
  "technical_token_mappings": [{"alias": "Main Actor", "canonical": "MainActor", "source_span_ids": ["s001"], "transform": "remove_internal_ascii_whitespace"}],
  "context_mappings": [{"alias": "正文写法", "canonical": "已确认标准写法", "source_span_ids": ["s001"], "context_field": "selected_text|text_before_cursor|text_after_cursor|recent_muse_inputs"}],
  "structure": {"kind": "sentence|paragraphs|numbered_list|mixed|ai_prompt", "ordered_unit_ids": ["u1"]}
}

输入中的 required_logic_cues 是程序从原文精确定位出的高置信条件句。每个 cue ID 必须且只能由 conditionals 覆盖；一条 conditional 可以合并同一条件的多个 cue，但不能漏掉。conditionals 必须把“条件”和它共同控制的每一个后果拆开，不能把多个后果揉进一句含糊的 final_meaning。`polarity=false` 表示该条件或后果不成立/不执行。required_logic_cues 为空时才允许返回空数组。

delivery_role 必须区分“要让收件人知道什么”和“只指导本次成稿怎么写”：
- recipient_content：含义必须进入成稿；
- style_directive：只应用语气、风格或表达方式，绝不能把“语气不要催”“写得自然一些”等幕后要求照抄成正文；
- editor_directive：只执行删除、归类、排序、格式或任务层处理，绝不能把编辑过程写给收件人。
判断依据必须来自 source spans；同一句同时含正文与风格要求时拆成两个 unit，不得把 style_directive 混进 recipient_content。

第一人称的真实状态、边界和立场——例如名称尚未确认、不要代用户作决定、当前不能承诺——通常是要让收件人知道的 recipient_content，不是 editor_directive。editor_directive 必须明确指向本次写作操作（删除哪句、保留哪个精确 token、如何归类或排版）。只要原文仍包含可发送的事实或立场，units 就不能全部标成 style_directive/editor_directive。

每条 correction 还必须区分输出策略：
- final_only：只是当前口述中的口误、起步错误或尚未对外生效的旧值，成稿只保留最终值；
- announce_change：旧安排已经发布、已经生效或用户明确要求向收件人宣布取消/变更，成稿必须同时传达“旧安排取消/已改为新安排”，不能只写最终值。
必须依据 source spans 中的传播状态判断，不能因为出现“原来”就自动推断已经通知过。

audience 中的 surface_tokens 必须逐字来自所引用的 source spans，并且至少一个必须出现在成稿；它只用于防止丢失“团队、客户、小林”等接收对象，不得把上下文中的人名加入正文。若原文是“跟团队说/回复客户”，成稿应改成自然的直接消息或明确通知对象，不要机械照抄外层口述指令。

故障现象与后续排查动作必须拆成独立 unit。原文只说“先做 X”时，X 是 advice/recommended，不代表“做完一定解决”；只有原文明确给出因果或保证，才能建立确定结果。

technical_token_mappings 只用于 code/aiPrompt 场景中高置信的 ASCII 技术标识断词：alias 必须逐字来自 source spans，canonical 只能删除 alias 内部多余空白，不能改字母、大小写或标点。每条 mapping 只能覆盖一个技术标识；同一句有多个断词时分别输出多条，不得把整句或同时含普通英文词边界的长短语作为一个 alias。普通英文短语不得强行合并；不确定时返回空数组。

只能引用本次输入实际提供的 source span ID。不要复述长段原文，不要输出 Markdown 代码块，不要解释。"""


PLANNER_REPAIR_SYSTEM = """你是 Muse 意图清单的格式与角色修复器。上一版局部 Ledger 没有通过本地 schema/自洽性检查；你只修 Ledger，不写成稿。

重新阅读 source spans，根据 validation_error 修复字段、证据或 delivery_role。不能把真实正文、第一人称未确认状态、承诺边界或给收件人的禁止事项全部标成幕后指令；editor_directive 只用于明确控制本次写作操作的要求。不得借修复新增原文没有的事实、上下文映射或条件关系。

返回与局部 Planner 完全相同 schema 的单个 JSON 对象，不要输出 Markdown 或解释。"""


GLOBAL_PLANNER_SYSTEM = """你是 Muse 语音润色的全文关系规划器。局部规划器已经处理每个 batch；你只负责合并跨 batch 的改口、收件人、否定/待确认/不承诺边界和全文结构，不得重写所有局部 units。

只返回一个紧凑 JSON 对象：
{
  "global_audience": [{"text": "收件人或受众", "source_span_ids": ["s001"], "surface_tokens": ["团队"]}],
  "global_corrections": [{"subject": "对象", "old_span_ids": ["s001"], "final_span_ids": ["s009"], "old_value": "旧值", "final_value": "最终值", "rendering_policy": "final_only|announce_change"}],
  "global_constraints": [{"meaning": "跨段仍需成立的约束", "source_span_ids": ["s002", "s008"], "modality": "confirmed|possible|pending|prohibited|not_promised"}],
  "global_conditionals": [{
    "id": "gc1",
    "cue_ids": ["lc001"],
    "condition": {"subject": "条件主体", "predicate": "成立条件", "polarity": false, "source_span_ids": ["s006"]},
    "consequences": [{"action": "共同受该条件控制的动作", "polarity": false, "source_span_ids": ["s006"]}]
  }],
  "global_technical_token_mappings": [{"alias": "Main Actor", "canonical": "MainActor", "source_span_ids": ["s001"], "transform": "remove_internal_ascii_whitespace"}],
  "global_context_mappings": [{"alias": "正文中的非标准写法", "canonical": "安全上下文确认的标准写法", "source_span_ids": ["s001"], "context_field": "selected_text|text_before_cursor|text_after_cursor|recent_muse_inputs"}],
  "structure": {"kind": "paragraphs|numbered_list|mixed|ai_prompt", "ordered_batch_ids": ["b01", "b02"]}
}

global_audience 必须合并局部 ledger 已识别的所有收件人及其 surface_tokens。global_corrections 必须包含局部 ledger 已识别的改口以及跨 batch 改口，并保留其 rendering_policy；跨 batch 新发现的改口也必须判断 final_only 或 announce_change。global_conditionals 必须保留所有局部条件及跨 batch 条件，并把同一条件控制的多个后果放在同一个对象中。global_technical_token_mappings 只能去重合并局部已验证映射，不得发明新映射。只能引用实际提供的 span ID 和 batch ID。不要复制局部 unit 列表，不要输出 Markdown 代码块，不要解释。"""


WRITER_SYSTEM = """你是 Muse 语音润色的分段成稿 Writer。你的交付物是整篇成稿中的一个连续片段。

严格依据语音转写和意图清单：保留最终事实、独立约束、收件人、语气、待确认与不承诺边界；删除口吃、机械重复、被撤回旧值、改口过程和幕后编辑说明；不得摘要长文，不得补写原因、承诺、人物、日期或结论。

逐个执行 unit.delivery_role：recipient_content 才把含义写入正文；style_directive 只改变表达效果，不能复述成“语气不要催”“措辞自然”等编辑说明；editor_directive 只执行对应操作，不能出现在成稿。若同一 source span 同时有正文与风格要求，只输出 recipient_content，并让风格自然体现在措辞里。

逐条执行 correction.rendering_policy：final_only 删除旧值与改口过程，只写最终值；announce_change 必须让收件人明确知道旧安排已取消或发生变更，再写最终安排。不得把 announce_change 错当成普通口误静默删除。

global_audience 中每个对象至少一个 surface_token 必须进入成稿；把“跟团队说/回复客户”等外层口述整理成自然的直接消息或明确通知对象，不要照抄口述动作。

技术标识统一使用 global_technical_token_mappings 的 canonical。advice/recommended 只能表达建议、下一步或排查动作，不得写成执行后必然解决。

若场景是 aiPrompt，交付可直接交给 AI 执行的 Prompt 本身，不回答任务，也不要再写“请把下面内容整理成 Prompt”。用户对当前润色步骤说的“先不执行、只整理任务”也是编辑层指令，不得写入未来 AI 的 Prompt。

conditionals/global_conditionals 是条件逻辑的唯一准绳：条件的 polarity 与每个 consequence 的 polarity 必须分别保持，多个共同后果不得漏掉，也不得把“条件不成立时不执行”错写成“条件成立后仍不执行”。

只处理当前 batch 的 source spans；相邻边界文字只用于理解，不得重复输出。若局部 unit 带有 resolved_correction：旧位置只负责删除旧值，不得在旧位置再次写一遍 final_value；final_span_ids 所在位置才负责呈现最终值。若 unit 的 rendering_instruction 是 omit_obsolete_unit_at_old_location，整条旧 unit 都不输出。

若最后一个 source span 带 high_confidence_abandoned_tail，只删除其中标出的残缺尾句；不得把它扩写成“待确认”“尚未明确”或任何新事项。global_context_mappings 是已通过来源校验的标准写法，成稿中同一实体必须统一采用 canonical。

只输出本片段成稿，不要解释，不要加“润色结果”等前缀，不要自行添加全篇编号。"""


REVIEWER_SYSTEM = """你是与 Writer 隔离的 Muse 语音润色复核器。你不负责改写全文，只负责根据语音转写、已授权上下文和意图清单检查候选成稿。

逐项核对：最终事实、改口后的最终值、被撤回旧值、独立约束、收件人、主体-动作-时间关系、否定范围、不承诺/未确认状态、上下文纠错与上下文泄漏、AI Prompt 的任务层级、长文是否摘要或遗漏。global_audience 的接收对象不得遗漏，外层“跟谁说/回复谁”应落实为自然成稿。advice/recommended 不得被写成确定因果或保证结果；global_technical_token_mappings 的 canonical 必须精确出现，alias 不得残留。对 conditionals/global_conditionals 必须重新阅读对应 source spans，独立核对条件 polarity、每个后果 polarity 及共同作用范围；不得因为 Writer 与 Planner 表述一致就默认正确。逐个检查 delivery_role：recipient_content 不得遗漏；style_directive/editor_directive 的幕后措辞不得出现在候选成稿，只能看到其执行结果。逐条检查 correction.rendering_policy：final_only 不得残留旧值；announce_change 不得只剩最终值，必须保留旧安排取消/变更这一对收件人有用的信息。resolved_correction 的旧位置不得重复呈现 final_value；high_confidence_abandoned_tail 必须删除且不得被扩写成待确认事项；global_context_mappings 指定的同一实体不得混用 alias 与 canonical。没有来源证据的问题不得成立。

只返回一个 JSON 对象：
{
  "verdict": "pass|repair|unsafe",
  "issues": [{
    "type": "missing|wrong_relation|wrong_condition|wrong_modality|obsolete_retained|invented|context_leak|task_layer|instruction_leak|style_shift",
    "severity": "major|minor",
    "unit_ids": ["u1"],
    "source_span_ids": ["s001"],
    "draft_span": "候选成稿中的相关片段；缺失时为空",
    "repair_instruction": "只说明应恢复、删除或纠正什么"
  }]
}

完全合格才返回 pass；能通过一次局部修改安全修复时返回 repair；出现上下文秘密、无法确定正确含义或修复可能改变用户意图时返回 unsafe。issue 必须引用实际 source span ID，以便只重写对应 batch。不要输出 Markdown 代码块，不要解释。"""


REPAIR_SYSTEM = """你是 Muse 语音润色的定向片段修复器。根据当前 batch 原文、局部意图清单、全文关系、上一版片段和独立复核问题，只修改被指出的局部。

不得把上一版成稿当作新事实来源，不得补写原文没有的事实，不得摘要。global_audience 缺失时只恢复对应接收对象，并把外层口述整理成自然的通知或直接消息。advice/recommended 不得升级成保证结果，技术标识使用 global_technical_token_mappings 的 canonical。修复条件关系时必须逐项遵守 global_conditionals，不能只改条件句而遗留后果的错误否定。recipient_content 必须保留；style_directive/editor_directive 只执行，不复述幕后措辞。correction 为 final_only 时只留最终值；为 announce_change 时必须保留旧安排取消/变更的收件人信息。resolved_correction 的旧位置只删除旧值，不重复写 final_value；high_confidence_abandoned_tail 只删除，不升级成待确认；global_context_mappings 必须统一应用。只输出修复后的当前 batch 完整片段，不要解释。"""


@dataclass(frozen=True)
class Credentials:
    api_key: str
    model: str
    base_url: str


class ExperimentError(RuntimeError):
    pass


class ProviderAbsoluteTimeout(TimeoutError):
    """Provider 持续分块传输但始终不结束时，按墙上时钟强制终止。"""


@contextmanager
def absolute_wall_clock_timeout(seconds: float):
    """为同步 Provider I/O 增加绝对时限，而不是仅依赖 socket 读超时。"""

    if seconds <= 0:
        raise ExperimentError("Provider 绝对时限必须大于 0 秒")
    if not hasattr(signal, "setitimer"):
        yield
        return

    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()

    def raise_timeout(_signum: int, _frame: Any) -> None:
        raise ProviderAbsoluteTimeout(f"Provider 请求超过绝对时限 {seconds:g} 秒")

    signal.signal(signal.SIGALRM, raise_timeout)
    signal.setitimer(signal.ITIMER_REAL, float(seconds))
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_timer[0] > 0:
            elapsed = time.monotonic() - started
            remaining = max(0.001, previous_timer[0] - elapsed)
            signal.setitimer(signal.ITIMER_REAL, remaining, previous_timer[1])


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def append_jsonl(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())


def normalized_base_url(raw: str) -> str:
    value = raw.strip().rstrip("/")
    if not value.startswith("https://"):
        raise ExperimentError("受控实验只允许 HTTPS Provider Base URL")
    if value.endswith("/chat/completions"):
        value = value[: -len("/chat/completions")]
    return value.rstrip("/")


def load_credentials_from_stdin() -> Credentials:
    try:
        payload = json.loads(sys.stdin.read())
    except json.JSONDecodeError as error:
        raise ExperimentError(f"标准输入中的凭证 JSON 无法解析：{error}") from error
    if not isinstance(payload, dict):
        raise ExperimentError("标准输入中的凭证必须是 JSON 对象")
    api_key = str(payload.get("apiKey", "")).strip()
    model = str(payload.get("model", "")).strip()
    base_url = normalized_base_url(str(payload.get("baseURL", "")))
    if not api_key or not model:
        raise ExperimentError("凭证缺少 apiKey 或 model")
    return Credentials(api_key=api_key, model=model, base_url=base_url)


def load_dataset(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ExperimentError(f"数据集不存在、非普通文件或是符号链接：{path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schema_version") != 1 or value.get("case_count") != 25:
        raise ExperimentError("核心语义数据集身份不正确")
    return value


def safe_context(case: dict[str, Any]) -> dict[str, Any] | None:
    if case.get("context_type") not in SAFE_CONTEXT_TYPES:
        return None
    fixture = case.get("context_fixture")
    if not isinstance(fixture, dict):
        return None
    return {
        "context_type": case["context_type"],
        "selected_text": fixture.get("selected_text", ""),
        "text_before_cursor": fixture.get("text_before_cursor", ""),
        "text_after_cursor": fixture.get("text_after_cursor", ""),
        "recent_muse_inputs": fixture.get("recent_muse_inputs", []),
    }


def model_case_metadata(case: dict[str, Any]) -> dict[str, Any]:
    """构造模型可见元数据；此函数是语义契约隔离的唯一入口。"""
    return {
        "test_input_id": case["test_input_id"],
        "writing_scene": case["writing_scene"],
        "task_layer": (
            "executable_prompt" if case["writing_scene"] == "aiPrompt" else "final_message"
        ),
        "asr_segment_count": len(case["segment_texts"]),
        "authorized_context": safe_context(case),
    }


def high_confidence_abandoned_tail(source: str) -> dict[str, Any] | None:
    """只识别位于文末、含明确停顿且以空指代收尾的残缺口述。"""
    trimmed = source.rstrip()
    if not trimmed or trimmed.endswith(("。", "！", "？", ".", "!", "?", "；", ";")):
        return None
    tail_start = max(0, len(trimmed) - 80)
    tail = trimmed[tail_start:]
    match = re.search(
        r"(?:^|[\s，,。！？；])(?P<fragment>(?:还有|另外|然后|以及)"
        r"[^。！？；\n]{0,28}"
        r"(?:呃|嗯|这个|那个|怎么说)[^。！？；\n]{0,14}"
        r"(?:后面那个|那个|这个|那块|这块|怎么说|就是))$",
        tail,
    )
    if match is None:
        return None
    fragment = match.group("fragment").strip()
    if len(fragment) < 4:
        return None
    global_start = tail_start + match.start("fragment")
    return {
        "kind": "high_confidence_abandoned_tail",
        "start": global_start,
        "end": global_start + len(fragment),
        "sha256": sha256_text(fragment),
        "text": fragment,
        "instruction": "删除这段残缺口述，不得补成待确认事项或新事实",
    }


def high_confidence_logic_cues(
    source: str, spans: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """定位显式条件构式；只要求 Planner 建模，不在本地判断语义。"""
    patterns = [
        (
            "only_if",
            r"只有[^。！？；\n]{1,48}?才[^。！？；\n]{1,72}(?=[。！？；\n]|$)",
        ),
        (
            "as_long_as",
            r"只要[^。！？；\n]{1,48}?就[^。！？；\n]{1,72}(?=[。！？；\n]|$)",
        ),
        (
            "negative_then",
            r"不能[^。！？；\n]{1,48}?就[^。！？；\n]{1,72}(?=[。！？；\n]|$)",
        ),
        (
            "explicit_if",
            r"如果[^。！？；\n]{1,96}(?=[。！？；\n]|$)",
        ),
    ]
    matches: list[tuple[int, int, str, str]] = []
    for kind, pattern in patterns:
        for match in re.finditer(pattern, source):
            matches.append((match.start(), match.end(), kind, match.group(0)))
    matches.sort(key=lambda item: (item[0], -(item[1] - item[0]), item[2]))
    accepted: list[tuple[int, int, str, str]] = []
    for candidate in matches:
        start, end, _, _ = candidate
        if any(start < known_end and known_start < end for known_start, known_end, _, _ in accepted):
            continue
        accepted.append(candidate)
    cues: list[dict[str, Any]] = []
    for start, end, kind, text in sorted(accepted):
        span_ids = [
            span["id"]
            for span in spans
            if start < span["end"] and span["start"] < end
        ]
        cues.append(
            {
                "id": f"lc{len(cues) + 1:03d}",
                "kind": kind,
                "start": start,
                "end": end,
                "sha256": sha256_text(text),
                "text": text,
                "source_span_ids": span_ids,
            }
        )
    return cues


def source_spans(case: dict[str, Any]) -> list[dict[str, Any]]:
    """把正文切成稳定字符范围；优先语义边界，必要时才做有界硬切。"""
    source = case["spoken_input"]
    spans: list[dict[str, Any]] = []
    start = 0
    natural_boundaries = set("。！？；\n")
    while start < len(source):
        hard_end = min(len(source), start + SOURCE_SPAN_HARD_MAX_CHARS)
        target_end = min(len(source), start + SOURCE_SPAN_TARGET_CHARS)
        lower_bound = min(len(source), start + SOURCE_SPAN_TARGET_CHARS // 2)
        candidates = [
            index
            for index in range(lower_bound, hard_end + 1)
            if index > start and source[index - 1] in natural_boundaries
        ]
        before_target = [index for index in candidates if index <= target_end]
        if before_target:
            end = before_target[-1]
        elif candidates:
            end = candidates[0]
        else:
            end = target_end
            # 不在 ASCII 路径、命令或单词中间硬切。
            while (
                end > start + SOURCE_SPAN_TARGET_CHARS // 2
                and end < len(source)
                and (source[end - 1].isascii() and source[end - 1].isalnum())
                and (source[end].isascii() and source[end].isalnum())
            ):
                end -= 1
        if end <= start:
            end = hard_end
        text = source[start:end]
        span_id = f"s{len(spans) + 1:03d}"
        spans.append(
            {
                "id": span_id,
                "start": start,
                "end": end,
                "sha256": sha256_text(text),
                "text": text,
            }
        )
        start = end
    abandoned_tail = high_confidence_abandoned_tail(source)
    if abandoned_tail is not None:
        last = spans[-1]
        if last["start"] <= abandoned_tail["start"] < last["end"]:
            last["high_confidence_abandoned_tail"] = abandoned_tail
    return spans


def planner_batches(spans: list[dict[str, Any]]) -> list[dict[str, Any]]:
    batches: list[dict[str, Any]] = []
    current: list[dict[str, Any]] = []
    current_chars = 0
    for span in spans:
        if current and current_chars + len(span["text"]) > PLANNER_BATCH_MAX_CHARS:
            batches.append({"id": f"b{len(batches) + 1:02d}", "source_spans": current})
            current = []
            current_chars = 0
        current.append(span)
        current_chars += len(span["text"])
    if current:
        batches.append({"id": f"b{len(batches) + 1:02d}", "source_spans": current})
    return batches


def visible_logic_cues(
    case: dict[str, Any], visible_spans: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    all_spans = source_spans(case)
    visible_ids = {span["id"] for span in visible_spans}
    return [
        cue
        for cue in high_confidence_logic_cues(case["spoken_input"], all_spans)
        if set(cue["source_span_ids"]).issubset(visible_ids)
    ]


def json_user_message(title: str, payload: dict[str, Any]) -> str:
    return f"{title}\n" + json.dumps(payload, ensure_ascii=False, indent=2)


def context_resolver_messages(
    case: dict[str, Any], spans: list[dict[str, Any]]
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": CONTEXT_RESOLVER_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请解析当前正文可被安全上下文证明的术语映射：",
                {
                    "input": model_case_metadata(case),
                    "source_spans": spans,
                },
            ),
        },
    ]


def planner_messages(
    case: dict[str, Any], batch: dict[str, Any]
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": PLANNER_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请为当前 batch 建立局部意图清单：",
                {
                    "input": model_case_metadata(case),
                    "batch_id": batch["id"],
                    "source_spans": batch["source_spans"],
                    "required_logic_cues": visible_logic_cues(
                        case, batch["source_spans"]
                    ),
                },
            ),
        },
    ]


def planner_repair_messages(
    case: dict[str, Any],
    batch: dict[str, Any],
    invalid_response: str,
    validation_error: str,
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": PLANNER_REPAIR_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请修复当前 batch 的局部意图清单：",
                {
                    "input": model_case_metadata(case),
                    "batch_id": batch["id"],
                    "source_spans": batch["source_spans"],
                    "required_logic_cues": visible_logic_cues(
                        case, batch["source_spans"]
                    ),
                    "invalid_ledger_response": invalid_response,
                    "validation_error": validation_error,
                },
            ),
        },
    ]


def global_planner_messages(
    case: dict[str, Any], planned_batches: list[dict[str, Any]]
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": GLOBAL_PLANNER_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请合并全文跨 batch 关系：",
                {
                    "input": model_case_metadata(case),
                    "required_logic_cues": high_confidence_logic_cues(
                        case["spoken_input"], source_spans(case)
                    ),
                    "batches": planned_batches,
                },
            ),
        },
    ]


def writer_messages(
    case: dict[str, Any],
    batch: dict[str, Any],
    ledger: dict[str, Any],
    global_plan: dict[str, Any],
    previous_tail: str,
    next_head: str,
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": WRITER_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请生成当前 batch 对应的成稿片段：",
                {
                    "input": model_case_metadata(case),
                    "batch_id": batch["id"],
                    "source_spans": batch["source_spans"],
                    "local_intent_ledger": ledger,
                    "global_plan": global_plan,
                    "boundary_context_only": {
                        "previous_tail": previous_tail,
                        "next_head": next_head,
                    },
                },
            ),
        },
    ]


def reviewer_messages(
    case: dict[str, Any],
    spans: list[dict[str, Any]],
    planned_batches: list[dict[str, Any]],
    global_plan: dict[str, Any],
    fragments: list[dict[str, str]],
    draft: str,
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": REVIEWER_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请独立复核候选成稿：",
                {
                    "input": model_case_metadata(case),
                    "source_spans": spans,
                    "planned_batches": planned_batches,
                    "global_plan": global_plan,
                    "draft_fragments": fragments,
                    "candidate_draft": draft,
                },
            ),
        },
    ]


def repair_messages(
    case: dict[str, Any],
    batch: dict[str, Any],
    ledger: dict[str, Any],
    global_plan: dict[str, Any],
    fragment: str,
    issues: list[dict[str, Any]],
) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": REPAIR_SYSTEM},
        {
            "role": "user",
            "content": json_user_message(
                "请仅修复以下已定位问题：",
                {
                    "input": model_case_metadata(case),
                    "batch_id": batch["id"],
                    "source_spans": batch["source_spans"],
                    "local_intent_ledger": ledger,
                    "global_plan": global_plan,
                    "previous_fragment": fragment,
                    "review_issues": issues,
                },
            ),
        },
    ]


def serialized_messages(messages: list[dict[str, str]]) -> str:
    return json.dumps(messages, ensure_ascii=False, sort_keys=True)


def assert_no_contract_leak(messages: list[dict[str, str]]) -> None:
    serialized = serialized_messages(messages)
    leaked = sorted(key for key in FORBIDDEN_MODEL_INPUT_KEYS if key in serialized)
    if leaked:
        raise ExperimentError(f"模型输入泄漏语义评分字段：{leaked}")


def parse_json_object(text: str, label: str) -> dict[str, Any]:
    value = text.strip()
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value, flags=re.IGNORECASE)
        value = re.sub(r"\s*```$", "", value)
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        start = value.find("{")
        end = value.rfind("}")
        if start < 0 or end <= start:
            raise ExperimentError(f"{label} 未返回 JSON 对象")
        try:
            parsed = json.loads(value[start : end + 1])
        except json.JSONDecodeError as error:
            raise ExperimentError(f"{label} JSON 无法解析：{error}") from error
    if not isinstance(parsed, dict):
        raise ExperimentError(f"{label} 必须返回 JSON 对象")
    return parsed


def flattened_context_text(case: dict[str, Any]) -> str:
    context = safe_context(case)
    return "" if context is None else json.dumps(context, ensure_ascii=False)


def validate_span_ids(value: Any, allowed: set[str], label: str) -> None:
    if not isinstance(value, list) or not value:
        raise ExperimentError(f"{label} 必须是非空 span ID 数组")
    if any(not isinstance(span_id, str) or span_id not in allowed for span_id in value):
        raise ExperimentError(f"{label} 引用了未知 span ID")


def validate_conditionals(
    value: Any,
    allowed_span_ids: set[str],
    label: str,
    required_cue_ids: set[str] | None = None,
) -> None:
    if not isinstance(value, list):
        raise ExperimentError(f"{label} 必须是数组")
    known_ids: set[str] = set()
    covered_cue_ids: list[str] = []
    allowed_cue_ids = required_cue_ids or set()
    for rule in value:
        if not isinstance(rule, dict):
            raise ExperimentError(f"{label} 条目必须是对象")
        rule_id = rule.get("id")
        if not isinstance(rule_id, str) or not rule_id or rule_id in known_ids:
            raise ExperimentError(f"{label} ID 为空或重复")
        known_ids.add(rule_id)
        cue_ids = rule.get("cue_ids")
        if not isinstance(cue_ids, list) or not cue_ids or any(
            not isinstance(cue_id, str) or cue_id not in allowed_cue_ids
            for cue_id in cue_ids
        ):
            raise ExperimentError(f"{label} {rule_id} cue_ids 缺失或越界")
        covered_cue_ids.extend(cue_ids)
        condition = rule.get("condition")
        consequences = rule.get("consequences")
        if not isinstance(condition, dict):
            raise ExperimentError(f"{label} {rule_id} 缺少 condition")
        for key in ("subject", "predicate"):
            if not isinstance(condition.get(key), str) or not condition[key].strip():
                raise ExperimentError(f"{label} {rule_id} condition.{key} 必须非空")
        if not isinstance(condition.get("polarity"), bool):
            raise ExperimentError(f"{label} {rule_id} condition.polarity 必须为布尔值")
        validate_span_ids(
            condition.get("source_span_ids"),
            allowed_span_ids,
            f"{label} {rule_id} condition",
        )
        if not isinstance(consequences, list) or not consequences:
            raise ExperimentError(f"{label} {rule_id} consequences 必须是非空数组")
        for index, consequence in enumerate(consequences, start=1):
            if not isinstance(consequence, dict):
                raise ExperimentError(f"{label} {rule_id} consequence {index} 必须是对象")
            if not isinstance(consequence.get("action"), str) or not consequence[
                "action"
            ].strip():
                raise ExperimentError(f"{label} {rule_id} consequence {index} action 必须非空")
            if not isinstance(consequence.get("polarity"), bool):
                raise ExperimentError(
                    f"{label} {rule_id} consequence {index} polarity 必须为布尔值"
                )
            validate_span_ids(
                consequence.get("source_span_ids"),
                allowed_span_ids,
                f"{label} {rule_id} consequence {index}",
            )
    if set(covered_cue_ids) != allowed_cue_ids or len(covered_cue_ids) != len(
        set(covered_cue_ids)
    ):
        raise ExperimentError(f"{label} 未一一覆盖 required_logic_cues")


def validate_technical_token_mappings(
    value: Any,
    visible_spans: list[dict[str, Any]],
    label: str,
) -> None:
    if not isinstance(value, list):
        raise ExperimentError(f"{label} 必须是数组")
    allowed_span_ids = {span["id"] for span in visible_spans}
    span_text_by_id = {span["id"]: span["text"] for span in visible_spans}
    seen_aliases: set[str] = set()
    for mapping in value:
        if not isinstance(mapping, dict):
            raise ExperimentError(f"{label} 条目必须是对象")
        alias = mapping.get("alias")
        canonical = mapping.get("canonical")
        span_ids = mapping.get("source_span_ids")
        if (
            not isinstance(alias, str)
            or not isinstance(canonical, str)
            or alias in seen_aliases
            or mapping.get("transform") != "remove_internal_ascii_whitespace"
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z0-9]+)+", alias)
        ):
            raise ExperimentError(f"{label} alias、transform 或格式不合法")
        seen_aliases.add(alias)
        validate_span_ids(span_ids, allowed_span_ids, label)
        evidence = "".join(span_text_by_id[span_id] for span_id in span_ids)
        if alias not in evidence:
            raise ExperimentError(f"{label} alias 必须逐字来自引用的 source spans")
        expected = re.sub(r"(?<=[A-Za-z0-9])\s+(?=[A-Za-z0-9])", "", alias)
        if canonical != expected or canonical == alias:
            raise ExperimentError(f"{label} canonical 只能删除该技术标识内部的 ASCII 空白")


def sanitize_ledger_context_mappings(
    case: dict[str, Any],
    ledger: dict[str, Any],
    visible_spans: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """只保留可由正文 alias + 已授权 canonical 确定证明的映射。"""
    mappings = ledger.get("context_mappings", [])
    if not isinstance(mappings, list):
        raise ExperimentError("意图清单 context_mappings 必须是数组")
    source = case["spoken_input"]
    context = flattened_context_text(case)
    allowed_span_ids = {span["id"] for span in visible_spans}
    allowed_context_fields = {
        "selected_text",
        "text_before_cursor",
        "text_after_cursor",
        "recent_muse_inputs",
    }
    accepted: list[dict[str, Any]] = []
    diagnostics: list[dict[str, Any]] = []
    for mapping in mappings:
        reason = None
        if not isinstance(mapping, dict):
            reason = "mapping_not_object"
        elif case.get("context_type") == "conflicting_safe":
            reason = "conflicting_context_forbids_mapping"
        else:
            alias = mapping.get("alias")
            canonical = mapping.get("canonical")
            span_ids = mapping.get("source_span_ids")
            context_field = mapping.get("context_field")
            if not isinstance(alias, str) or not alias or alias not in source:
                reason = "alias_not_in_source"
            elif alias == canonical:
                reason = "identity_mapping"
            elif not isinstance(canonical, str) or not canonical or canonical not in context:
                reason = "canonical_not_in_authorized_context"
            elif (
                not isinstance(span_ids, list)
                or not span_ids
                or any(span_id not in allowed_span_ids for span_id in span_ids)
            ):
                reason = "invalid_source_span_ids"
            elif context_field not in allowed_context_fields:
                reason = "invalid_context_field"
        if reason is None:
            accepted.append(mapping)
        else:
            diagnostics.append(
                {
                    "type": "discarded_unsupported_context_mapping",
                    "reason": reason,
                    "mapping": mapping,
                }
            )
    ledger["context_mappings"] = accepted
    return diagnostics


def merge_global_context_mappings(
    case: dict[str, Any],
    global_plan: dict[str, Any],
    planned_batches: list[dict[str, Any]],
    spans: list[dict[str, Any]],
    preflight_mappings: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """校验全文映射，并合并局部 Planner 已证明的非恒等映射。"""
    proposed = [
        *copy.deepcopy(preflight_mappings),
        *copy.deepcopy(global_plan.get("global_context_mappings", [])),
    ]
    if not isinstance(proposed, list):
        raise ExperimentError("全文计划 global_context_mappings 必须是数组")
    holder = {"context_mappings": copy.deepcopy(proposed)}
    diagnostics = sanitize_ledger_context_mappings(case, holder, spans)
    accepted = holder["context_mappings"]
    seen = {
        (
            mapping["alias"],
            mapping["canonical"],
            tuple(mapping["source_span_ids"]),
            mapping["context_field"],
        )
        for mapping in accepted
    }
    for planned in planned_batches:
        for mapping in planned["local_ledger"].get("context_mappings", []):
            key = (
                mapping["alias"],
                mapping["canonical"],
                tuple(mapping["source_span_ids"]),
                mapping["context_field"],
            )
            if mapping["alias"] != mapping["canonical"] and key not in seen:
                accepted.append(copy.deepcopy(mapping))
                seen.add(key)
    global_plan["global_context_mappings"] = accepted
    return diagnostics


def apply_verified_context_mappings(text: str, global_plan: dict[str, Any]) -> str:
    """只应用已通过 alias/source/canonical/context 四重校验的精确映射。"""
    mappings = sorted(
        global_plan.get("global_context_mappings", []),
        key=lambda item: len(item.get("alias", "")),
        reverse=True,
    )
    result = text
    for mapping in mappings:
        alias = mapping.get("alias", "")
        canonical = mapping.get("canonical", "")
        if alias and canonical and alias != canonical:
            result = result.replace(alias, canonical)
    return result


def merged_local_technical_token_mappings(
    planned_batches: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    merged: list[dict[str, Any]] = []
    canonical_by_alias: dict[str, str] = {}
    seen: set[tuple[str, str, tuple[str, ...]]] = set()
    for planned in planned_batches:
        for mapping in planned["local_ledger"].get(
            "technical_token_mappings", []
        ):
            alias = mapping["alias"]
            canonical = mapping["canonical"]
            previous = canonical_by_alias.get(alias)
            if previous is not None and previous != canonical:
                raise ExperimentError("局部技术标识映射存在冲突 canonical")
            canonical_by_alias[alias] = canonical
            key = (alias, canonical, tuple(mapping["source_span_ids"]))
            if key not in seen:
                merged.append(copy.deepcopy(mapping))
                seen.add(key)
    return merged


def apply_verified_technical_token_mappings(
    text: str, global_plan: dict[str, Any]
) -> str:
    result = text
    mappings = sorted(
        global_plan.get("global_technical_token_mappings", []),
        key=lambda item: len(item.get("alias", "")),
        reverse=True,
    )
    for mapping in mappings:
        alias = mapping.get("alias", "")
        canonical = mapping.get("canonical", "")
        if alias and canonical and alias != canonical:
            result = result.replace(alias, canonical)
    return result


def apply_verified_mappings(text: str, global_plan: dict[str, Any]) -> str:
    return apply_verified_technical_token_mappings(
        apply_verified_context_mappings(text, global_plan),
        global_plan,
    )


def validate_ledger(
    case: dict[str, Any], ledger: dict[str, Any], visible_spans: list[dict[str, Any]]
) -> None:
    units = ledger.get("units")
    if not isinstance(units, list) or not units:
        raise ExperimentError("意图清单缺少非空 units")
    source = case["spoken_input"]
    context = flattened_context_text(case)
    allowed_span_ids = {span["id"] for span in visible_spans}
    known_ids: set[str] = set()
    allowed_delivery_roles = {
        "recipient_content",
        "style_directive",
        "editor_directive",
    }
    allowed_kinds = {
        "claim",
        "action",
        "advice",
        "constraint",
        "question",
        "uncertainty",
        "style",
    }
    allowed_modalities = {
        "confirmed",
        "possible",
        "pending",
        "prohibited",
        "not_promised",
        "recommended",
    }
    observed_delivery_roles: list[str] = []
    for unit in units:
        if not isinstance(unit, dict):
            raise ExperimentError("意图单元必须是对象")
        unit_id = unit.get("id")
        if not isinstance(unit_id, str) or not unit_id or unit_id in known_ids:
            raise ExperimentError("意图单元 ID 空或重复")
        known_ids.add(unit_id)
        validate_span_ids(
            unit.get("source_span_ids"), allowed_span_ids, f"意图单元 {unit_id}"
        )
        if unit.get("delivery_role") not in allowed_delivery_roles:
            raise ExperimentError(
                f"意图单元 {unit_id} delivery_role 缺失或不合法"
            )
        if unit.get("kind") not in allowed_kinds:
            raise ExperimentError(f"意图单元 {unit_id} kind 缺失或不合法")
        if unit.get("modality") not in allowed_modalities:
            raise ExperimentError(f"意图单元 {unit_id} modality 缺失或不合法")
        if (unit["kind"] == "advice") != (unit["modality"] == "recommended"):
            raise ExperimentError(
                f"意图单元 {unit_id} advice 必须与 recommended 成对"
            )
        observed_delivery_roles.append(unit["delivery_role"])
    if "recipient_content" not in observed_delivery_roles:
        raise ExperimentError("意图清单不得把全部正文标为幕后风格或编辑指令")
    structure = ledger.get("structure")
    if not isinstance(structure, dict) or not isinstance(structure.get("kind"), str):
        raise ExperimentError("意图清单缺少 structure")
    ordered_unit_ids = structure.get("ordered_unit_ids")
    if not isinstance(ordered_unit_ids, list) or any(
        unit_id not in known_ids for unit_id in ordered_unit_ids
    ):
        raise ExperimentError("意图清单 structure 引用了未知 unit ID")

    audience = ledger.get("audience", [])
    if not isinstance(audience, list):
        raise ExperimentError("意图清单 audience 必须是数组")
    for item in audience:
        if not isinstance(item, dict):
            raise ExperimentError("收件人缺少可回溯证据")
        span_ids = item.get("source_span_ids")
        validate_span_ids(
            span_ids, allowed_span_ids, "收件人证据"
        )
        if not isinstance(item.get("text"), str) or not item["text"].strip():
            raise ExperimentError("收件人 text 必须非空")
        surface_tokens = item.get("surface_tokens")
        if (
            not isinstance(surface_tokens, list)
            or not surface_tokens
            or any(not isinstance(token, str) or not token for token in surface_tokens)
        ):
            raise ExperimentError("收件人 surface_tokens 必须是非空字符串数组")
        audience_evidence = "".join(
            span["text"] for span in visible_spans if span["id"] in span_ids
        )
        if any(token not in audience_evidence for token in surface_tokens):
            raise ExperimentError("收件人 surface_tokens 必须逐字来自引用的 source spans")

    corrections = ledger.get("corrections", [])
    if not isinstance(corrections, list):
        raise ExperimentError("意图清单 corrections 必须是数组")
    for correction in corrections:
        if not isinstance(correction, dict):
            raise ExperimentError("改口关系必须是对象")
        validate_span_ids(
            correction.get("old_span_ids"), allowed_span_ids, "改口关系 old_span_ids"
        )
        validate_span_ids(
            correction.get("final_span_ids"),
            allowed_span_ids,
            "改口关系 final_span_ids",
        )
        for key in ("old_value", "final_value"):
            if not isinstance(correction.get(key), str) or not correction[key].strip():
                raise ExperimentError(f"改口关系 {key} 必须非空")
        if correction.get("rendering_policy") not in {
            "final_only",
            "announce_change",
        }:
            raise ExperimentError("改口关系 rendering_policy 缺失或不合法")

    validate_conditionals(
        ledger.get("conditionals"),
        allowed_span_ids,
        "局部条件关系",
        {
            cue["id"]
            for cue in visible_logic_cues(case, visible_spans)
        },
    )

    technical_mappings = ledger.get("technical_token_mappings")
    if technical_mappings and case.get("writing_scene") not in {"code", "aiPrompt"}:
        raise ExperimentError("技术标识断词映射只允许用于 code/aiPrompt 场景")
    validate_technical_token_mappings(
        technical_mappings,
        visible_spans,
        "局部技术标识映射",
    )

    mappings = ledger.get("context_mappings", [])
    if not isinstance(mappings, list):
        raise ExperimentError("意图清单 context_mappings 必须是数组")
    for mapping in mappings:
        if not isinstance(mapping, dict):
            raise ExperimentError("上下文映射必须是对象")
        alias = mapping.get("alias")
        canonical = mapping.get("canonical")
        if not isinstance(alias, str) or not alias or alias not in source:
            raise ExperimentError("上下文映射 alias 必须逐字来自正文")
        if not isinstance(canonical, str) or not canonical or canonical not in context:
            raise ExperimentError("上下文映射 canonical 必须来自已授权上下文")
        validate_span_ids(
            mapping.get("source_span_ids"), allowed_span_ids, "上下文映射"
        )
        if mapping.get("context_field") not in {
            "selected_text",
            "text_before_cursor",
            "text_after_cursor",
            "recent_muse_inputs",
        }:
            raise ExperimentError("上下文映射 context_field 不合法")


def parse_and_validate_ledger(
    case: dict[str, Any],
    batch: dict[str, Any],
    response_text: str,
    label: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    ledger = parse_json_object(response_text, label)
    diagnostics = sanitize_ledger_context_mappings(
        case, ledger, batch["source_spans"]
    )
    validate_ledger(case, ledger, batch["source_spans"])
    return ledger, diagnostics


def validate_global_plan(
    plan: dict[str, Any], spans: list[dict[str, Any]], batches: list[dict[str, Any]]
) -> None:
    allowed_span_ids = {span["id"] for span in spans}
    allowed_batch_ids = {batch["id"] for batch in batches}
    audience = plan.get("global_audience")
    corrections = plan.get("global_corrections")
    constraints = plan.get("global_constraints")
    conditionals = plan.get("global_conditionals")
    technical_mappings = plan.get("global_technical_token_mappings")
    mappings = plan.get("global_context_mappings", [])
    structure = plan.get("structure")
    if (
        not isinstance(audience, list)
        or not isinstance(corrections, list)
        or not isinstance(constraints, list)
        or not isinstance(technical_mappings, list)
    ):
        raise ExperimentError(
            "全文计划缺少 audience、corrections、constraints 或技术映射数组"
        )
    span_text_by_id = {span["id"]: span["text"] for span in spans}
    for item in audience:
        if not isinstance(item, dict):
            raise ExperimentError("全文收件人必须是对象")
        span_ids = item.get("source_span_ids")
        validate_span_ids(span_ids, allowed_span_ids, "全文收件人")
        surface_tokens = item.get("surface_tokens")
        if (
            not isinstance(item.get("text"), str)
            or not item["text"].strip()
            or not isinstance(surface_tokens, list)
            or not surface_tokens
            or any(not isinstance(token, str) or not token for token in surface_tokens)
        ):
            raise ExperimentError("全文收件人字段不完整")
        evidence = "".join(span_text_by_id[span_id] for span_id in span_ids)
        if any(token not in evidence for token in surface_tokens):
            raise ExperimentError("全文收件人 surface_tokens 无法回溯原文")
    for correction in corrections:
        if not isinstance(correction, dict):
            raise ExperimentError("全文改口关系必须是对象")
        validate_span_ids(
            correction.get("old_span_ids"), allowed_span_ids, "全文改口 old_span_ids"
        )
        validate_span_ids(
            correction.get("final_span_ids"),
            allowed_span_ids,
            "全文改口 final_span_ids",
        )
        if correction.get("rendering_policy") not in {
            "final_only",
            "announce_change",
        }:
            raise ExperimentError("全文改口 rendering_policy 缺失或不合法")
    for constraint in constraints:
        if not isinstance(constraint, dict):
            raise ExperimentError("全文约束必须是对象")
        validate_span_ids(
            constraint.get("source_span_ids"), allowed_span_ids, "全文约束"
        )
    validate_conditionals(
        conditionals,
        allowed_span_ids,
        "全文条件关系",
        {
            cue["id"]
            for cue in high_confidence_logic_cues(
                "".join(span["text"] for span in spans), spans
            )
        },
    )
    validate_technical_token_mappings(
        technical_mappings,
        spans,
        "全文技术标识映射",
    )
    if not isinstance(mappings, list):
        raise ExperimentError("全文计划 global_context_mappings 必须是数组")
    for mapping in mappings:
        if not isinstance(mapping, dict):
            raise ExperimentError("全文上下文映射必须是对象")
        validate_span_ids(
            mapping.get("source_span_ids"), allowed_span_ids, "全文上下文映射"
        )
    if not isinstance(structure, dict):
        raise ExperimentError("全文计划缺少 structure")
    ordered = structure.get("ordered_batch_ids")
    if not isinstance(ordered, list) or ordered != [batch["id"] for batch in batches]:
        raise ExperimentError("全文计划未保持 batch 顺序")
    if any(batch_id not in allowed_batch_ids for batch_id in ordered):
        raise ExperimentError("全文计划引用了未知 batch ID")


def resolve_local_ledgers_with_global_plan(
    planned_batches: list[dict[str, Any]], global_plan: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """把全文已确认的改口投影回局部 ledger，消除 Reviewer 的新旧值歧义。"""
    resolved = copy.deepcopy(planned_batches)
    diagnostics: list[dict[str, Any]] = []
    for correction in global_plan.get("global_corrections", []):
        old_span_ids = set(correction.get("old_span_ids", []))
        final_span_ids = set(correction.get("final_span_ids", []))
        old_value = str(correction.get("old_value", "")).strip()
        matched_units: list[str] = []
        for planned in resolved:
            for unit in planned["local_ledger"].get("units", []):
                unit_span_ids = set(unit.get("source_span_ids", []))
                if not (old_span_ids & unit_span_ids):
                    continue
                searchable = "\n".join(
                    [
                        str(unit.get("final_meaning", "")),
                        *[str(token) for token in unit.get("exact_tokens", [])],
                    ]
                )
                if old_value and old_value not in searchable:
                    continue
                unit["status"] = "replace"
                unit["rendering_instruction"] = (
                    "render_final_only_in_this_unit"
                    if final_span_ids & unit_span_ids
                    else "omit_obsolete_unit_at_old_location"
                )
                unit["resolved_correction"] = {
                    "subject": correction.get("subject", ""),
                    "old_value": old_value,
                    "final_value": correction.get("final_value", ""),
                    "final_span_ids": correction.get("final_span_ids", []),
                    "rendering_policy": correction.get(
                        "rendering_policy", "final_only"
                    ),
                }
                matched_units.append(f"{planned['batch_id']}:{unit.get('id', '')}")
        diagnostics.append(
            {
                "type": "global_correction_projection",
                "subject": correction.get("subject", ""),
                "old_value": old_value,
                "final_value": correction.get("final_value", ""),
                "matched_units": matched_units,
            }
        )
    return resolved, diagnostics


def validate_review(review: dict[str, Any], allowed_span_ids: set[str]) -> None:
    verdict = review.get("verdict")
    issues = review.get("issues")
    if verdict not in {"pass", "repair", "unsafe"}:
        raise ExperimentError("复核 verdict 不合法")
    if not isinstance(issues, list):
        raise ExperimentError("复核 issues 必须是数组")
    if verdict == "pass" and issues:
        raise ExperimentError("复核 pass 时 issues 必须为空")
    if verdict != "pass" and not issues:
        raise ExperimentError(f"复核 {verdict} 时必须给出可定位 issue")
    for issue in issues:
        if not isinstance(issue, dict):
            raise ExperimentError("复核 issue 必须是对象")
        validate_span_ids(issue.get("source_span_ids"), allowed_span_ids, "复核 issue")


def sanitize_review_for_delivery_roles(
    review: dict[str, Any],
    planned_batches: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """删除可由 typed delivery role 证明为自相矛盾的 Reviewer issue。"""
    roles_by_unit_id: dict[str, set[str]] = {}
    for planned in planned_batches:
        for unit in planned["local_ledger"].get("units", []):
            unit_id = unit.get("id")
            role = unit.get("delivery_role")
            if isinstance(unit_id, str) and isinstance(role, str):
                roles_by_unit_id.setdefault(unit_id, set()).add(role)
    kept: list[dict[str, Any]] = []
    diagnostics: list[dict[str, Any]] = []
    for issue in review.get("issues", []):
        unit_ids = issue.get("unit_ids", [])
        cited_roles = [roles_by_unit_id.get(unit_id, set()) for unit_id in unit_ids]
        provably_editor_only = bool(cited_roles) and all(
            roles == {"editor_directive"} for roles in cited_roles
        )
        empty_draft_span = not str(issue.get("draft_span", "")).strip()
        if (
            provably_editor_only
            and empty_draft_span
            and issue.get("type") in {"missing", "instruction_leak"}
        ):
            diagnostics.append(
                {
                    "type": "discarded_contradictory_reviewer_issue",
                    "unit_ids": unit_ids,
                    "reason": "editor_directive_without_draft_evidence_must_not_be_rendered",
                }
            )
            continue
        kept.append(issue)
    sanitized = dict(review)
    sanitized["issues"] = kept
    if not kept and diagnostics:
        sanitized["verdict"] = "pass"
    return sanitized, diagnostics


def deterministic_output_issues(
    case: dict[str, Any],
    spans: list[dict[str, Any]],
    output: str,
    *,
    global_plan: dict[str, Any] | None = None,
    batches: list[dict[str, Any]] | None = None,
    fragments: list[dict[str, str]] | None = None,
) -> list[dict[str, Any]]:
    """只检查能由产品任务层级确定证明的错误，不判断开放式自然度。"""
    issues: list[dict[str, Any]] = []
    if global_plan is not None:
        for audience in global_plan.get("global_audience", []):
            surface_tokens = audience.get("surface_tokens", [])
            if any(token in output for token in surface_tokens):
                continue
            audience_text = str(audience.get("text", "收件人")).strip()
            issues.append(
                {
                    "type": "missing",
                    "severity": "major",
                    "unit_ids": [],
                    "source_span_ids": audience.get("source_span_ids", []),
                    "draft_span": "",
                    "repair_instruction": (
                        f"恢复接收对象“{audience_text}”，并用自然的直接消息或通知表达；"
                        "不得只保留事件正文。"
                    ),
                }
            )
        for mapping in global_plan.get("global_technical_token_mappings", []):
            alias = mapping.get("alias", "")
            canonical = mapping.get("canonical", "")
            if canonical in output and alias not in output:
                continue
            issues.append(
                {
                    "type": "wrong_relation",
                    "severity": "major",
                    "unit_ids": [],
                    "source_span_ids": mapping.get("source_span_ids", []),
                    "draft_span": alias if alias in output else "",
                    "repair_instruction": (
                        f"将 ASR 断开的技术标识“{alias}”统一恢复为“{canonical}”；"
                        "不得改变其他字符。"
                    ),
                }
            )
    if case.get("writing_scene") == "aiPrompt":
        meta_prompt_patterns = [
            r"(?:整理|改写|生成|制作|输出|写)成一?份?(?:可直接[^\n，。]{0,24})?\s*[Pp]rompt",
            r"(?:整理|改写|生成|制作|输出|写)[^\n。]{0,30}\s*[Pp]rompt",
            r"以下[^\n。]{0,30}整理[^\n。]{0,20}\s*[Pp]rompt",
        ]
        matches = [
            match
            for pattern in meta_prompt_patterns
            if (match := re.search(pattern, output, flags=re.IGNORECASE))
        ]
        source_has_prompt_authoring_layer = bool(
            re.search(r"(?:整理|改写|生成|写)[^\n。]{0,40}[Pp]rompt", case["spoken_input"])
        )
        if source_has_prompt_authoring_layer:
            editor_deferral_patterns = [
                r"(?:现在|先|暂时|目前)?不(?:要)?(?:开始|执行|进行)(?:研究|分析|任务)",
                r"只(?:整理|改写|生成)(?:以下)?(?:任务|要求|\s*[Pp]rompt)",
            ]
            matches.extend(
                match
                for pattern in editor_deferral_patterns
                if (match := re.search(pattern, output, flags=re.IGNORECASE))
            )
        seen_spans: set[tuple[int, int]] = set()
        for match in matches:
            match_span = (match.start(), match.end())
            if any(
                match_span[0] < seen_end and seen_start < match_span[1]
                for seen_start, seen_end in seen_spans
            ):
                continue
            seen_spans.add(match_span)
            issues.append(
                {
                    "type": "task_layer",
                    "severity": "major",
                    "unit_ids": [],
                    "source_span_ids": [spans[0]["id"]],
                    "draft_span": match.group(0),
                    "repair_instruction": "直接交付可由未来 AI 执行的任务 Prompt 本身；删除要求 AI 再次整理 Prompt 的外层任务，以及只针对当前润色步骤的“先不执行、只整理任务”。",
                }
            )
    if global_plan is not None and batches is not None and fragments is not None:
        batch_by_span_id = {
            span["id"]: batch["id"]
            for batch in batches
            for span in batch["source_spans"]
        }
        batch_by_id = {batch["id"]: batch for batch in batches}
        fragment_by_id = {fragment["batch_id"]: fragment["text"] for fragment in fragments}
        for correction in global_plan.get("global_corrections", []):
            old_span_ids = correction.get("old_span_ids", [])
            final_span_ids = correction.get("final_span_ids", [])
            old_batch_ids = {
                batch_by_span_id[span_id]
                for span_id in old_span_ids
                if span_id in batch_by_span_id
            }
            final_batch_ids = {
                batch_by_span_id[span_id]
                for span_id in final_span_ids
                if span_id in batch_by_span_id
            }
            final_value = str(correction.get("final_value", "")).strip()
            if not final_value or old_batch_ids & final_batch_ids:
                continue
            for batch_id in sorted(old_batch_ids):
                old_source = "".join(
                    span["text"] for span in batch_by_id[batch_id]["source_spans"]
                )
                old_fragment = fragment_by_id.get(batch_id, "")
                if final_value in old_source or final_value not in old_fragment:
                    continue
                issues.append(
                    {
                        "type": "obsolete_retained",
                        "severity": "minor",
                        "unit_ids": [],
                        "source_span_ids": old_span_ids,
                        "draft_span": final_value,
                        "repair_instruction": (
                            f"旧位置不得提前重复最终值“{final_value}”；删除该旧事项，"
                            "最终值只由 final_span_ids 所在位置呈现。"
                        ),
                    }
                )
    return issues


def merge_deterministic_issues(
    review: dict[str, Any], issues: list[dict[str, Any]]
) -> dict[str, Any]:
    if not issues or review.get("verdict") == "unsafe":
        return review
    merged = dict(review)
    merged["issues"] = list(review.get("issues", [])) + issues
    merged["verdict"] = "repair"
    merged["deterministic_issue_count"] = len(issues)
    return merged


class OpenAICompatibleClient:
    def __init__(
        self,
        credentials: Credentials,
        audit_path: Path,
        timeout_seconds: int,
        max_output_tokens: int,
    ) -> None:
        self.credentials = credentials
        self.audit_path = audit_path
        self.timeout_seconds = timeout_seconds
        self.max_output_tokens = max_output_tokens
        self.ssl_context = ssl.create_default_context()
        self.request_ordinal = 0

    def list_models(self) -> list[str]:
        request = urllib.request.Request(
            f"{self.credentials.base_url}/models",
            headers={"Authorization": f"Bearer {self.credentials.api_key}"},
        )
        with absolute_wall_clock_timeout(self.timeout_seconds):
            with urllib.request.urlopen(
                request, timeout=self.timeout_seconds, context=self.ssl_context
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
        rows = payload.get("data")
        if not isinstance(rows, list):
            raise ExperimentError("Provider /models 未返回 data 数组")
        return sorted(
            row["id"]
            for row in rows
            if isinstance(row, dict) and isinstance(row.get("id"), str)
        )

    def call(
        self,
        *,
        model: str,
        case_id: str,
        stage: str,
        messages: list[dict[str, str]],
        json_response: bool,
    ) -> dict[str, Any]:
        assert_no_contract_leak(messages)
        self.request_ordinal += 1
        body: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "stream": False,
            "temperature": 0.1,
            "max_tokens": self.max_output_tokens,
        }
        if "reasoner" in model.lower():
            body["thinking"] = {"type": "enabled"}
        else:
            body["thinking"] = {"type": "disabled"}
        if json_response:
            body["response_format"] = {"type": "json_object"}
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request_sha = sha256_bytes(encoded)
        request = urllib.request.Request(
            f"{self.credentials.base_url}/chat/completions",
            data=encoded,
            headers={
                "Authorization": f"Bearer {self.credentials.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        started = time.monotonic()
        status = 0
        response_id = None
        response_model = None
        finish_reason = None
        usage = None
        content = ""
        error_message = None
        try:
            with absolute_wall_clock_timeout(self.timeout_seconds):
                with urllib.request.urlopen(
                    request, timeout=self.timeout_seconds, context=self.ssl_context
                ) as response:
                    status = response.status
                    payload = json.loads(response.read().decode("utf-8"))
            response_id = payload.get("id")
            response_model = payload.get("model")
            usage = payload.get("usage")
            choices = payload.get("choices")
            if not isinstance(choices, list) or not choices:
                raise ExperimentError("Provider 响应缺少 choices")
            choice = choices[0]
            finish_reason = choice.get("finish_reason")
            message = choice.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("content"), str):
                raise ExperimentError("Provider 响应缺少 message.content")
            content = message["content"].strip()
            if not content:
                raise ExperimentError("Provider 返回空文本")
        except urllib.error.HTTPError as error:
            status = error.code
            error_message = f"HTTP {error.code}: {error.reason}"
        except Exception as error:  # noqa: BLE001 - 必须将单次 Provider 失败写入证据
            error_message = str(error)
        elapsed_ms = int((time.monotonic() - started) * 1_000)
        audit = {
            "schema_version": 1,
            "recorded_at": now_iso(),
            "request_ordinal": self.request_ordinal,
            "case_id": case_id,
            "stage": stage,
            "configured_model": model,
            "response_model": response_model,
            "endpoint_url": f"{self.credentials.base_url}/chat/completions",
            "http_status": status,
            "request_body_sha256": request_sha,
            "response_text_sha256": sha256_text(content) if content else None,
            "provider_response_id": response_id,
            "finish_reason": finish_reason,
            "latency_ms": elapsed_ms,
            "usage": usage,
            "error": error_message,
        }
        append_jsonl(self.audit_path, audit)
        if error_message:
            raise ExperimentError(error_message[:2_000])
        return {"text": content, "audit": audit}


def require_complete_response(response: dict[str, Any]) -> None:
    if response["audit"].get("finish_reason") == "length":
        raise ExperimentError("Provider 返回长度截断")


def run_case(
    *,
    client: OpenAICompatibleClient,
    model: str,
    reviewer_model: str,
    case: dict[str, Any],
    model_input_log: list[dict[str, Any]],
) -> dict[str, Any]:
    case_id = case["test_input_id"]
    spans = source_spans(case)
    required_logic_cues = high_confidence_logic_cues(case["spoken_input"], spans)
    batches = planner_batches(spans)
    allowed_span_ids = {span["id"] for span in spans}
    record: dict[str, Any] = {
        "test_input_id": case_id,
        "model": model,
        "reviewer_model": reviewer_model,
        "outcome": "unavailable",
        "stage": "planner",
        "source_spans": spans,
        "required_logic_cues": required_logic_cues,
        "verified_context_mappings": [],
        "planner_batches": [
            {"id": batch["id"], "source_span_ids": [span["id"] for span in batch["source_spans"]]}
            for batch in batches
        ],
        "local_ledgers": [],
        "planner_diagnostics": [],
        "global_plan": None,
        "resolved_local_ledgers": [],
        "resolution_diagnostics": [],
        "initial_fragments": [],
        "final_fragments": [],
        "initial_draft": None,
        "initial_review": None,
        "initial_review_diagnostics": [],
        "initial_deterministic_issues": [],
        "repaired_draft": None,
        "confirm_review": None,
        "confirm_review_diagnostics": [],
        "confirm_deterministic_issues": [],
        "raw_responses": [],
        "output_text": "",
        "error": None,
        "call_count": 0,
    }
    try:
        preflight_mappings: list[dict[str, Any]] = []
        if safe_context(case) is not None and case.get("context_type") != "conflicting_safe":
            record["stage"] = "context_resolver"
            messages = context_resolver_messages(case, spans)
            model_input_log.append(
                {
                    "case_id": case_id,
                    "model": model,
                    "stage": "context_resolver",
                    "messages": messages,
                }
            )
            record["call_count"] += 1
            response = client.call(
                model=model,
                case_id=case_id,
                stage="context_resolver",
                messages=messages,
                json_response=True,
            )
            record["raw_responses"].append(
                {"stage": "context_resolver", "text": response["text"]}
            )
            require_complete_response(response)
            resolved_context = parse_json_object(
                response["text"], "Context Resolver"
            )
            diagnostics = sanitize_ledger_context_mappings(
                case, resolved_context, spans
            )
            record["planner_diagnostics"].extend(
                {"stage": "context_resolver", **diagnostic}
                for diagnostic in diagnostics
            )
            preflight_mappings = resolved_context["context_mappings"]
            record["verified_context_mappings"] = copy.deepcopy(
                preflight_mappings
            )
        planned_batches: list[dict[str, Any]] = []
        for batch in batches:
            stage = f"planner:{batch['id']}"
            record["stage"] = stage
            messages = planner_messages(case, batch)
            model_input_log.append(
                {"case_id": case_id, "model": model, "stage": stage, "messages": messages}
            )
            record["call_count"] += 1
            response = client.call(
                model=model,
                case_id=case_id,
                stage=stage,
                messages=messages,
                json_response=True,
            )
            record["raw_responses"].append({"stage": stage, "text": response["text"]})
            require_complete_response(response)
            diagnostic_stage = stage
            try:
                ledger, diagnostics = parse_and_validate_ledger(
                    case,
                    batch,
                    response["text"],
                    f"Planner {batch['id']}",
                )
            except ExperimentError as first_error:
                repair_stage = f"planner_repair:{batch['id']}"
                record["stage"] = repair_stage
                repair_messages_value = planner_repair_messages(
                    case,
                    batch,
                    response["text"],
                    str(first_error),
                )
                model_input_log.append(
                    {
                        "case_id": case_id,
                        "model": model,
                        "stage": repair_stage,
                        "messages": repair_messages_value,
                    }
                )
                record["call_count"] += 1
                repaired_response = client.call(
                    model=model,
                    case_id=case_id,
                    stage=repair_stage,
                    messages=repair_messages_value,
                    json_response=True,
                )
                record["raw_responses"].append(
                    {"stage": repair_stage, "text": repaired_response["text"]}
                )
                require_complete_response(repaired_response)
                diagnostic_stage = repair_stage
                ledger, diagnostics = parse_and_validate_ledger(
                    case,
                    batch,
                    repaired_response["text"],
                    f"Planner Repair {batch['id']}",
                )
            record["planner_diagnostics"].extend(
                {"stage": diagnostic_stage, **diagnostic}
                for diagnostic in diagnostics
            )
            planned = {
                "batch_id": batch["id"],
                "source_spans": batch["source_spans"],
                "local_ledger": ledger,
            }
            planned_batches.append(planned)
            record["local_ledgers"].append(
                {"batch_id": batch["id"], "ledger": ledger}
            )

        if len(batches) == 1:
            local = planned_batches[0]["local_ledger"]
            global_plan = {
                "global_audience": copy.deepcopy(local.get("audience", [])),
                "global_corrections": local.get("corrections", []),
                "global_constraints": [],
                "global_conditionals": copy.deepcopy(
                    local.get("conditionals", [])
                ),
                "global_technical_token_mappings": copy.deepcopy(
                    local.get("technical_token_mappings", [])
                ),
                "global_context_mappings": copy.deepcopy(
                    local.get("context_mappings", [])
                ),
                "structure": {
                    "kind": local.get("structure", {}).get("kind", "paragraphs"),
                    "ordered_batch_ids": [batches[0]["id"]],
                },
            }
        else:
            record["stage"] = "global_planner"
            messages = global_planner_messages(case, planned_batches)
            model_input_log.append(
                {
                    "case_id": case_id,
                    "model": model,
                    "stage": "global_planner",
                    "messages": messages,
                }
            )
            record["call_count"] += 1
            response = client.call(
                model=model,
                case_id=case_id,
                stage="global_planner",
                messages=messages,
                json_response=True,
            )
            record["raw_responses"].append(
                {"stage": "global_planner", "text": response["text"]}
            )
            require_complete_response(response)
            global_plan = parse_json_object(response["text"], "Global Planner")
        global_plan["global_technical_token_mappings"] = (
            merged_local_technical_token_mappings(planned_batches)
        )
        record["planner_diagnostics"].extend(
            {"stage": "global_context_mapping", **diagnostic}
            for diagnostic in merge_global_context_mappings(
                case,
                global_plan,
                planned_batches,
                spans,
                preflight_mappings,
            )
        )
        validate_global_plan(global_plan, spans, batches)
        record["global_plan"] = global_plan
        resolved_planned_batches, resolution_diagnostics = (
            resolve_local_ledgers_with_global_plan(planned_batches, global_plan)
        )
        record["resolved_local_ledgers"] = [
            {"batch_id": item["batch_id"], "ledger": item["local_ledger"]}
            for item in resolved_planned_batches
        ]
        record["resolution_diagnostics"] = resolution_diagnostics

        fragments: list[dict[str, str]] = []
        for batch_index, (batch, planned) in enumerate(
            zip(batches, resolved_planned_batches)
        ):
            previous_tail = ""
            next_head = ""
            if batch_index > 0:
                previous_tail = batches[batch_index - 1]["source_spans"][-1]["text"][-160:]
            if batch_index + 1 < len(batches):
                next_head = batches[batch_index + 1]["source_spans"][0]["text"][:160]
            stage = f"writer:{batch['id']}"
            record["stage"] = stage
            messages = writer_messages(
                case,
                batch,
                planned["local_ledger"],
                global_plan,
                previous_tail,
                next_head,
            )
            model_input_log.append(
                {"case_id": case_id, "model": model, "stage": stage, "messages": messages}
            )
            record["call_count"] += 1
            response = client.call(
                model=model,
                case_id=case_id,
                stage=stage,
                messages=messages,
                json_response=False,
            )
            record["raw_responses"].append({"stage": stage, "text": response["text"]})
            require_complete_response(response)
            fragments.append(
                {
                    "batch_id": batch["id"],
                    "text": apply_verified_mappings(
                        response["text"], global_plan
                    ),
                }
            )
        record["initial_fragments"] = fragments
        draft = "\n\n".join(fragment["text"] for fragment in fragments if fragment["text"])
        record["initial_draft"] = draft

        record["stage"] = "reviewer"
        messages = reviewer_messages(
            case, spans, resolved_planned_batches, global_plan, fragments, draft
        )
        model_input_log.append(
            {
                "case_id": case_id,
                "model": reviewer_model,
                "stage": "reviewer",
                "messages": messages,
            }
        )
        record["call_count"] += 1
        response = client.call(
            model=reviewer_model,
            case_id=case_id,
            stage="reviewer",
            messages=messages,
            json_response=True,
        )
        record["raw_responses"].append({"stage": "reviewer", "text": response["text"]})
        require_complete_response(response)
        review = parse_json_object(response["text"], "Reviewer")
        validate_review(review, allowed_span_ids)
        review, review_diagnostics = sanitize_review_for_delivery_roles(
            review, resolved_planned_batches
        )
        record["initial_review_diagnostics"] = review_diagnostics
        validate_review(review, allowed_span_ids)
        deterministic_issues = deterministic_output_issues(
            case,
            spans,
            draft,
            global_plan=global_plan,
            batches=batches,
            fragments=fragments,
        )
        record["initial_deterministic_issues"] = deterministic_issues
        review = merge_deterministic_issues(review, deterministic_issues)
        record["initial_review"] = review
        if review["verdict"] == "pass":
            record["final_fragments"] = fragments
            record.update(outcome="polished", stage="complete", output_text=draft)
            return record
        if review["verdict"] == "unsafe":
            record.update(stage="reviewer_unsafe", error="复核器判定无法安全修复")
            return record

        batch_by_span_id = {
            span["id"]: batch["id"]
            for batch in batches
            for span in batch["source_spans"]
        }
        affected_batch_ids = []
        for issue in review["issues"]:
            for span_id in issue["source_span_ids"]:
                batch_id = batch_by_span_id[span_id]
                if batch_id not in affected_batch_ids:
                    affected_batch_ids.append(batch_id)
        if len(affected_batch_ids) > 2:
            record.update(
                stage="repair_scope_too_broad",
                error="复核问题横跨超过 2 个 batch，拒绝重写大片已合格文本",
            )
            return record

        repaired_fragments = [dict(fragment) for fragment in fragments]
        planned_by_batch = {
            item["batch_id"]: item for item in resolved_planned_batches
        }
        batch_by_id = {batch["id"]: batch for batch in batches}
        fragment_by_id = {fragment["batch_id"]: fragment for fragment in repaired_fragments}
        for batch_id in affected_batch_ids:
            batch = batch_by_id[batch_id]
            batch_issues = [
                issue
                for issue in review["issues"]
                if any(batch_by_span_id[span_id] == batch_id for span_id in issue["source_span_ids"])
            ]
            stage = f"repair:{batch_id}"
            record["stage"] = stage
            messages = repair_messages(
                case,
                batch,
                planned_by_batch[batch_id]["local_ledger"],
                global_plan,
                fragment_by_id[batch_id]["text"],
                batch_issues,
            )
            model_input_log.append(
                {"case_id": case_id, "model": model, "stage": stage, "messages": messages}
            )
            record["call_count"] += 1
            response = client.call(
                model=model,
                case_id=case_id,
                stage=stage,
                messages=messages,
                json_response=False,
            )
            record["raw_responses"].append({"stage": stage, "text": response["text"]})
            require_complete_response(response)
            fragment_by_id[batch_id]["text"] = apply_verified_mappings(
                response["text"], global_plan
            )
        repaired = "\n\n".join(
            fragment_by_id[batch["id"]]["text"] for batch in batches
        )
        record["repaired_draft"] = repaired
        record["final_fragments"] = repaired_fragments

        record["stage"] = "confirm_reviewer"
        messages = reviewer_messages(
            case,
            spans,
            resolved_planned_batches,
            global_plan,
            repaired_fragments,
            repaired,
        )
        model_input_log.append(
            {
                "case_id": case_id,
                "model": reviewer_model,
                "stage": "confirm_reviewer",
                "messages": messages,
            }
        )
        record["call_count"] += 1
        response = client.call(
            model=reviewer_model,
            case_id=case_id,
            stage="confirm_reviewer",
            messages=messages,
            json_response=True,
        )
        record["raw_responses"].append(
            {"stage": "confirm_reviewer", "text": response["text"]}
        )
        require_complete_response(response)
        confirm = parse_json_object(response["text"], "Confirm Reviewer")
        validate_review(confirm, allowed_span_ids)
        confirm, confirm_diagnostics = sanitize_review_for_delivery_roles(
            confirm, resolved_planned_batches
        )
        record["confirm_review_diagnostics"] = confirm_diagnostics
        validate_review(confirm, allowed_span_ids)
        confirm_deterministic_issues = deterministic_output_issues(
            case,
            spans,
            repaired,
            global_plan=global_plan,
            batches=batches,
            fragments=repaired_fragments,
        )
        record["confirm_deterministic_issues"] = confirm_deterministic_issues
        confirm = merge_deterministic_issues(confirm, confirm_deterministic_issues)
        record["confirm_review"] = confirm
        if confirm["verdict"] == "pass":
            record.update(outcome="polished", stage="complete", output_text=repaired)
        else:
            record.update(stage="confirm_failed", error="定向修复后仍未通过独立复核")
    except ExperimentError as error:
        record["error"] = str(error)
    return record


def blind_packet(
    dataset: dict[str, Any],
    cases: list[dict[str, Any]],
    models: list[str],
    results: list[dict[str, Any]],
    run_nonce: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    result_by_key = {(row["test_input_id"], row["model"]): row for row in results}
    packet_cases: list[dict[str, Any]] = []
    sealed_map: dict[str, Any] = {}
    for case in cases:
        case_id = case["test_input_id"]
        shuffled = list(models)
        random.Random(f"{run_nonce}:{case_id}").shuffle(shuffled)
        candidates = []
        case_map = {}
        for index, model in enumerate(shuffled):
            label = chr(ord("A") + index)
            result = result_by_key[(case_id, model)]
            candidates.append(
                {
                    "candidate_label": label,
                    "outcome": result["outcome"],
                    "output_text": result["output_text"],
                    "failure_stage": None if result["outcome"] == "polished" else result["stage"],
                    "failure_reason": None if result["outcome"] == "polished" else result["error"],
                }
            )
            case_map[label] = model
        packet_cases.append(
            {
                "test_input_id": case_id,
                "title": case["title"],
                "writing_scene": case["writing_scene"],
                "spoken_input": case["spoken_input"],
                "context_type": case["context_type"],
                "context_fixture": case["context_fixture"],
                "semantic_contract": case["semantic_contract"],
                "candidates": candidates,
            }
        )
        sealed_map[case_id] = case_map
    packet = {
        "schema_version": EXPERIMENT_SCHEMA_VERSION,
        "dataset_name": dataset["name"],
        "run_nonce": run_nonce,
        "rules": {
            "reviewer_must_not_open_sealed_model_map": True,
            "score_each_candidate_independently": True,
            "rating_scale": ["direct_send", "minor_edit", "major_error", "unusable"],
            "major_error_or_unusable_fails_case": True,
            "critical_error_types": dataset["rules"]["critical_error_types"],
        },
        "cases": packet_cases,
    }
    sealed = {
        "schema_version": EXPERIMENT_SCHEMA_VERSION,
        "run_nonce": run_nonce,
        "case_candidate_model_map": sealed_map,
    }
    return packet, sealed


def select_cases(dataset: dict[str, Any], raw_ids: str | None) -> list[dict[str, Any]]:
    requested = DEFAULT_PILOT_IDS if raw_ids is None else [
        value.strip() for value in raw_ids.split(",") if value.strip()
    ]
    by_id = {case["test_input_id"]: case for case in dataset["inputs"]}
    missing = [case_id for case_id in requested if case_id not in by_id]
    if missing:
        raise ExperimentError(f"核心集缺少指定样本：{missing}")
    if len(set(requested)) != len(requested):
        raise ExperimentError("样本 ID 不得重复")
    return [by_id[case_id] for case_id in requested]


def self_test(dataset: dict[str, Any]) -> None:
    deadline_triggered = False
    try:
        with absolute_wall_clock_timeout(0.01):
            time.sleep(0.05)
    except ProviderAbsoluteTimeout:
        deadline_triggered = True
    if not deadline_triggered:
        raise ExperimentError("Provider 绝对时限自检未触发")

    technical_source = [
        {
            "id": "s001",
            "text": "Main Actor isolated property cannot be refer enced",
        }
    ]
    validate_technical_token_mappings(
        [
            {
                "alias": "Main Actor",
                "canonical": "MainActor",
                "source_span_ids": ["s001"],
                "transform": "remove_internal_ascii_whitespace",
            },
            {
                "alias": "refer enced",
                "canonical": "referenced",
                "source_span_ids": ["s001"],
                "transform": "remove_internal_ascii_whitespace",
            }
        ],
        technical_source,
        "技术标识映射自检",
    )
    try:
        validate_technical_token_mappings(
            [
                {
                    "alias": "Main Actor isolated property cannot be refer enced",
                    "canonical": "MainActor isolated property cannot be referenced",
                    "source_span_ids": ["s001"],
                    "transform": "remove_internal_ascii_whitespace",
                }
            ],
            technical_source,
            "错误技术标识映射自检",
        )
    except ExperimentError:
        pass
    else:
        raise ExperimentError("跨普通词边界的技术标识映射未被 schema 拒绝")

    cases = dataset["inputs"]
    for case in cases:
        spans = source_spans(case)
        batches = planner_batches(spans)
        if "".join(span["text"] for span in spans) != case["spoken_input"]:
            raise ExperimentError(f"{case['test_input_id']} source spans 无法无损拼回")
        if any(span["end"] - span["start"] > SOURCE_SPAN_HARD_MAX_CHARS for span in spans):
            raise ExperimentError(f"{case['test_input_id']} source span 超出硬上限")
        first_span_id = batches[0]["source_spans"][0]["id"]
        first_batch_cues = visible_logic_cues(case, batches[0]["source_spans"])
        dummy_ledger = {
            "audience": [],
            "units": [
                {
                    "id": "u1",
                    "kind": "claim",
                    "delivery_role": "recipient_content",
                    "final_meaning": "测试",
                    "source_span_ids": [first_span_id],
                    "status": "keep",
                    "modality": "confirmed",
                    "exact_tokens": [],
                }
            ],
            "corrections": [],
            "conditionals": [
                {
                    "id": f"c{index}",
                    "cue_ids": [cue["id"]],
                    "condition": {
                        "subject": "测试主体",
                        "predicate": "测试条件",
                        "polarity": True,
                        "source_span_ids": cue["source_span_ids"],
                    },
                    "consequences": [
                        {
                            "action": "测试后果",
                            "polarity": True,
                            "source_span_ids": cue["source_span_ids"],
                        }
                    ],
                }
                for index, cue in enumerate(first_batch_cues, start=1)
            ],
            "technical_token_mappings": [],
            "context_mappings": [],
            "structure": {"kind": "sentence", "ordered_unit_ids": ["u1"]},
        }
        validate_ledger(case, dummy_ledger, batches[0]["source_spans"])
        planned_batches = [
            {
                "batch_id": batch["id"],
                "source_spans": batch["source_spans"],
                "local_ledger": dummy_ledger,
            }
            for batch in batches
        ]
        global_plan = {
            "global_audience": [],
            "global_corrections": [],
            "global_constraints": [],
            "global_conditionals": [
                {
                    "id": f"gc{index}",
                    "cue_ids": [cue["id"]],
                    "condition": {
                        "subject": "测试主体",
                        "predicate": "测试条件",
                        "polarity": True,
                        "source_span_ids": cue["source_span_ids"],
                    },
                    "consequences": [
                        {
                            "action": "测试后果",
                            "polarity": True,
                            "source_span_ids": cue["source_span_ids"],
                        }
                    ],
                }
                for index, cue in enumerate(
                    high_confidence_logic_cues(case["spoken_input"], spans),
                    start=1,
                )
            ],
            "global_technical_token_mappings": [],
            "global_context_mappings": [],
            "structure": {
                "kind": "paragraphs",
                "ordered_batch_ids": [batch["id"] for batch in batches],
            },
        }
        validate_global_plan(global_plan, spans, batches)
        fragments = [{"batch_id": batch["id"], "text": "测试成稿"} for batch in batches]
        for messages in (
            context_resolver_messages(case, spans),
            planner_messages(case, batches[0]),
            planner_repair_messages(
                case,
                batches[0],
                json.dumps(dummy_ledger, ensure_ascii=False),
                "自检错误",
            ),
            global_planner_messages(case, planned_batches),
            writer_messages(
                case,
                batches[0],
                dummy_ledger,
                global_plan,
                "",
                "",
            ),
            reviewer_messages(
                case,
                spans,
                planned_batches,
                global_plan,
                fragments,
                "测试成稿",
            ),
            repair_messages(
                case,
                batches[0],
                dummy_ledger,
                global_plan,
                "测试成稿",
                [],
            ),
        ):
            assert_no_contract_leak(messages)
    secure = next(case for case in cases if case["test_input_id"] == "context-11")
    if safe_context(secure) is not None:
        raise ExperimentError("secure_blocked 上下文被错误暴露给模型")
    safe = next(case for case in cases if case["test_input_id"] == "context-03")
    if safe_context(safe) is None:
        raise ExperimentError("nearby_safe 上下文未提供给模型")
    parsed = parse_json_object('```json\n{"verdict":"pass","issues":[]}\n```', "self-test")
    validate_review(parsed, {"s001"})
    if normalized_base_url("https://api.deepseek.com/chat/completions") != "https://api.deepseek.com":
        raise ExperimentError("Provider Base URL 归一化失败")
    projected, diagnostics = resolve_local_ledgers_with_global_plan(
        [
            {
                "batch_id": "b01",
                "source_spans": [{"id": "s001", "text": "重试先按三次"}],
                "local_ledger": {
                    "units": [
                        {
                            "id": "u1",
                            "delivery_role": "recipient_content",
                            "source_span_ids": ["s001"],
                            "final_meaning": "重试先按三次",
                            "exact_tokens": ["三次"],
                            "status": "keep",
                        }
                    ]
                },
            }
        ],
        {
            "global_corrections": [
                {
                    "subject": "重试次数",
                    "old_span_ids": ["s001"],
                    "final_span_ids": ["s002"],
                    "old_value": "三次",
                    "final_value": "两次",
                    "rendering_policy": "final_only",
                }
            ]
        },
    )
    if projected[0]["local_ledger"]["units"][0].get("status") != "replace":
        raise ExperimentError("全文改口未投影回局部 ledger")
    if diagnostics[0].get("matched_units") != ["b01:u1"]:
        raise ExperimentError("全文改口投影证据不完整")
    projected_unit = projected[0]["local_ledger"]["units"][0]
    if projected_unit.get("rendering_instruction") != "omit_obsolete_unit_at_old_location":
        raise ExperimentError("旧值局部 unit 未收到仅删除旧位置的渲染指令")
    abandoned = high_confidence_abandoned_tail("正文已经说完 还有日志那块呃后面那个")
    if abandoned is None or abandoned.get("text") != "还有日志那块呃后面那个":
        raise ExperimentError("残缺尾句未被高置信识别")
    if high_confidence_abandoned_tail("正文已经说完，另外还有日志需要补充。") is not None:
        raise ExperimentError("完整尾句被误判为残缺口述")
    mapped = apply_verified_context_mappings(
        "缪斯进程与 Muse 设置",
        {
            "global_context_mappings": [
                {
                    "alias": "缪斯",
                    "canonical": "Muse",
                    "source_span_ids": ["s001"],
                    "context_field": "recent_muse_inputs",
                }
            ]
        },
    )
    if mapped != "Muse进程与 Muse 设置":
        raise ExperimentError("已验证的全文实体映射未统一应用")
    correction_issues = deterministic_output_issues(
        {"writing_scene": "document", "spoken_input": "旧值在前，最终值在后"},
        [
            {"id": "s001", "text": "重试先按三次"},
            {"id": "s002", "text": "最终最多两次"},
        ],
        "重试次数最多两次。\n\n最终最多两次。",
        global_plan={
            "global_corrections": [
                {
                    "old_span_ids": ["s001"],
                    "final_span_ids": ["s002"],
                    "final_value": "最多两次",
                }
            ]
        },
        batches=[
            {"id": "b01", "source_spans": [{"id": "s001", "text": "重试先按三次"}]},
            {"id": "b02", "source_spans": [{"id": "s002", "text": "最终最多两次"}]},
        ],
        fragments=[
            {"batch_id": "b01", "text": "重试次数最多两次。"},
            {"batch_id": "b02", "text": "最终最多两次。"},
        ],
    )
    if not any(issue.get("type") == "obsolete_retained" for issue in correction_issues):
        raise ExperimentError("旧位置重复最终值未被确定性门禁识别")
    audience_issues = deterministic_output_issues(
        {"writing_scene": "workChat", "spoken_input": "跟团队说会议改期"},
        [{"id": "s001", "text": "跟团队说会议改期"}],
        "会议已经改期。",
        global_plan={
            "global_audience": [
                {
                    "text": "团队",
                    "source_span_ids": ["s001"],
                    "surface_tokens": ["团队"],
                }
            ]
        },
    )
    if not any(issue.get("type") == "missing" for issue in audience_issues):
        raise ExperimentError("收件人缺失未被确定性门禁识别")
    sanitized_review, review_diagnostics = sanitize_review_for_delivery_roles(
        {
            "verdict": "repair",
            "issues": [
                {
                    "type": "missing",
                    "severity": "major",
                    "unit_ids": ["u1"],
                    "source_span_ids": ["s001"],
                    "draft_span": "",
                    "repair_instruction": "恢复幕后指令",
                }
            ],
        },
        [
            {
                "batch_id": "b01",
                "local_ledger": {
                    "units": [
                        {"id": "u1", "delivery_role": "editor_directive"}
                    ]
                },
            }
        ],
    )
    if sanitized_review.get("verdict") != "pass" or not review_diagnostics:
        raise ExperimentError("Reviewer 恢复 editor_directive 的矛盾意见未被丢弃")
    validate_conditionals(
        [
            {
                "id": "c1",
                "cue_ids": ["lc001"],
                "condition": {
                    "subject": "独立 Agent",
                    "predicate": "明确通过",
                    "polarity": False,
                    "source_span_ids": ["s001"],
                },
                "consequences": [
                    {
                        "action": "更新修复台账为完成",
                        "polarity": False,
                        "source_span_ids": ["s001"],
                    },
                    {
                        "action": "覆盖安装正式应用",
                        "polarity": False,
                        "source_span_ids": ["s001"],
                    },
                ],
            }
        ],
        {"s001"},
        "自检条件关系",
        {"lc001"},
    )
    try:
        validate_conditionals(
            [
                {
                    "id": "c1",
                    "cue_ids": ["lc001"],
                    "condition": {
                        "subject": "测试",
                        "predicate": "通过",
                        "polarity": "false",
                        "source_span_ids": ["s001"],
                    },
                    "consequences": [
                        {
                            "action": "安装",
                            "polarity": False,
                            "source_span_ids": ["s001"],
                        }
                    ],
                }
            ],
            {"s001"},
            "错误条件关系",
            {"lc001"},
        )
    except ExperimentError:
        pass
    else:
        raise ExperimentError("非布尔条件 polarity 未被 schema 拒绝")
    print(f"PASS：受控实验工具自检通过（{len(cases)} 条输入均无评分契约泄漏）")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--models", nargs="+")
    parser.add_argument(
        "--cross-reviewers",
        action="store_true",
        help="仅限两个模型：每个 Writer 候选由另一个模型执行 Reviewer 与 Confirm",
    )
    parser.add_argument("--case-ids", help="逗号分隔；缺省为 5 条小样")
    parser.add_argument("--credentials-stdin", action="store_true")
    parser.add_argument("--list-models", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--max-output-tokens", type=int, default=8192)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    dataset = load_dataset(arguments.dataset.resolve())
    if arguments.self_test:
        self_test(dataset)
        return
    if not arguments.credentials_stdin:
        raise ExperimentError("真实 Provider 操作必须使用 --credentials-stdin")
    credentials = load_credentials_from_stdin()
    audit_path = (
        arguments.output_dir.resolve() / "provider-audit.jsonl"
        if arguments.output_dir
        else ROOT / "build/voice-polish-architecture-experiment/provider-audit.jsonl"
    )
    client = OpenAICompatibleClient(
        credentials,
        audit_path,
        arguments.timeout_seconds,
        arguments.max_output_tokens,
    )
    if arguments.list_models:
        models = client.list_models()
        print(json.dumps({"stored_model": credentials.model, "available_models": models}, ensure_ascii=False, indent=2))
        return
    if not arguments.models or len(arguments.models) < 2:
        raise ExperimentError("受控对照至少需要两个 --models")
    models = [model.strip() for model in arguments.models if model.strip()]
    if len(set(models)) != len(models):
        raise ExperimentError("对照模型不得重复")
    if arguments.cross_reviewers and len(models) != 2:
        raise ExperimentError("--cross-reviewers 必须且只能搭配两个模型")
    output_dir = arguments.output_dir.resolve() if arguments.output_dir else None
    if output_dir is None:
        raise ExperimentError("真实实验必须显式指定 --output-dir")
    output_dir.mkdir(parents=True, exist_ok=False)
    audit_path.touch(mode=0o600, exist_ok=False)
    cases = select_cases(dataset, arguments.case_ids)
    run_nonce = uuid.uuid4().hex
    run_path = output_dir / "experiment-run.json"
    model_input_path = output_dir / "model-inputs.json"
    run: dict[str, Any] = {
        "schema_version": EXPERIMENT_SCHEMA_VERSION,
        "status": "running",
        "started_at": now_iso(),
        "completed_at": None,
        "run_nonce": run_nonce,
        "dataset_path": str(arguments.dataset.resolve()),
        "dataset_sha256": sha256_bytes(arguments.dataset.resolve().read_bytes()),
        "provider_base_url": credentials.base_url,
        "stored_model": credentials.model,
        "models": models,
        "reviewer_strategy": (
            "cross_model_swap" if arguments.cross_reviewers else "same_model"
        ),
        "case_ids": [case["test_input_id"] for case in cases],
        "results": [],
    }
    atomic_write_json(run_path, run)
    model_inputs: list[dict[str, Any]] = []
    try:
        for case in cases:
            for model_index, model in enumerate(models):
                reviewer_model = (
                    models[1 - model_index] if arguments.cross_reviewers else model
                )
                result = run_case(
                    client=client,
                    model=model,
                    reviewer_model=reviewer_model,
                    case=case,
                    model_input_log=model_inputs,
                )
                run["results"].append(result)
                atomic_write_json(run_path, run)
                atomic_write_json(model_input_path, model_inputs)
                print(
                    f"{case['test_input_id']} | {model} | {result['outcome']} | "
                    f"calls={result['call_count']} | stage={result['stage']}",
                    flush=True,
                )
        packet, sealed = blind_packet(dataset, cases, models, run["results"], run_nonce)
        atomic_write_json(output_dir / "blind-review-packet.json", packet)
        atomic_write_json(output_dir / "sealed-model-map.json", sealed)
        run["status"] = "complete"
    except Exception as error:  # noqa: BLE001 - 必须持久化中断证据
        run["status"] = "failed"
        run["fatal_error"] = str(error)
        raise
    finally:
        run["completed_at"] = now_iso()
        atomic_write_json(run_path, run)
        atomic_write_json(model_input_path, model_inputs)
    print(f"PASS：受控实验完成，证据目录 {output_dir}")


if __name__ == "__main__":
    try:
        main()
    except ExperimentError as error:
        raise SystemExit(f"FAIL：{error}") from error
