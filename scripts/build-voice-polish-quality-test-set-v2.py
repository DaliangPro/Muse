#!/usr/bin/env python3
"""从已验收的 V1.2 母集重建 Muse 语音润色 V2.0 多维测试集。"""

from __future__ import annotations

import copy
import csv
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "docs/2026-08-12-Muse-Voice-Polish-Quality-Test-Set.json"
OUTPUT_PATH = ROOT / "docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Set.json"
RUN_PATH = ROOT / "docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Run-Template.csv"


def length_bucket(text: str) -> str:
    size = len(text)
    if size <= 15:
        return "micro_1_15"
    if size <= 80:
        return "short_16_80"
    if size <= 300:
        return "medium_81_300"
    if size <= 1000:
        return "long_301_1000"
    if size <= 3000:
        return "very_long_1001_3000"
    return "ultra_long_3001_8000"


def common_dimensions(item: dict) -> list[str]:
    values = {"final_intent", "fact_preservation", "no_invention", "direct_send"}
    tags = set(item.get("challenge_tags", [])) | set(item.get("blind_categories", []))
    factors = set(item.get("input_factors", []))
    if {"proper_noun", "homophone_entity_error", "mixed_language"} & (tags | factors):
        values.add("terminology")
    if {"self_correction", "fact_correction", "numeric_fact_correction"} & (tags | factors):
        values.add("correction_resolution")
    if {"list", "disordered", "wrong_sentence_boundary", "wrong_punctuation"} & (tags | factors):
        values.add("semantic_layout")
    if {"stutter_repetition", "lexical_repetition", "semantic_repetition"} & factors:
        values.add("disfluency_cleanup")
    if "ai_prompt" in tags:
        values.add("prompt_not_execution")
    return sorted(values)


def new_case(
    *,
    case_id: str,
    group: str,
    scene: str,
    title: str,
    spoken: str,
    reference: str,
    preserve: list[str],
    remove: list[str],
    dimensions: list[str],
    requires_transformation: bool,
    required_substrings: list[str],
    forbidden_substrings: list[str],
    format_expectation: str = "自然成稿",
    tone_expectation: str = "保留原有语气和表达力度",
    segments: list[str] | None = None,
    context_fixture: dict | None = None,
    min_paragraphs: int | None = None,
    min_list_items: int | None = None,
    challenge_tags: list[str] | None = None,
    blind_categories: list[str] | None = None,
) -> dict:
    automatic_checks = {
        "required_substrings": required_substrings,
        "forbidden_substrings": forbidden_substrings,
        "forbidden_context_substrings": [],
    }
    if min_paragraphs is not None:
        automatic_checks["minimum_paragraph_count"] = min_paragraphs
    if min_list_items is not None:
        automatic_checks["minimum_list_item_count"] = min_list_items
    item = {
        "id": case_id,
        "scenario_group": group,
        "writing_scene": scene,
        "title": title,
        "difficulty": "high" if len(spoken) > 300 else "medium",
        "challenge_tags": challenge_tags or [],
        "blind_categories": blind_categories or [],
        "spoken_input": spoken,
        "reference_output": reference,
        "must_preserve": preserve,
        "must_remove": remove,
        "must_not_invent": ["原文和授权上下文之外的事实", "额外承诺", "额外结论"],
        "format_expectation": format_expectation,
        "tone_expectation": tone_expectation,
        "acceptable_variations": ["允许同义改写，但不得改变事实、意图和语气"],
        "evaluation_focus": ["能否直接发送", "是否完成必要整理", "是否保留全部来源事实"],
        "length_bucket": length_bucket(spoken),
        "context_type": (context_fixture or {}).get("type", "none"),
        "quality_dimensions": sorted(set(dimensions + [
            "final_intent", "fact_preservation", "no_invention", "direct_send"
        ])),
        "requires_transformation": requires_transformation,
        "segment_texts": segments or [spoken],
        "automatic_checks": automatic_checks,
    }
    if context_fixture:
        item["context_fixture"] = context_fixture
    return item


def short_cases() -> list[dict]:
    specs = [
        ("micro-01", "谢谢你。", "谢谢你。", ["谢谢"], [], False, ["谢谢你"], []),
        ("micro-02", "你到哪了", "你到哪了？", ["询问位置"], [], True, ["你到哪了"], []),
        ("micro-03", "周五不行。", "周五不行。", ["周五", "否定态度"], [], False, ["周五不行"], []),
        ("micro-04", "真的真的很好。", "真的真的很好。", ["有意强调两次真的"], [], False, ["真的真的很好"], []),
        ("micro-05", "我我到了", "我到了。", ["已经到达"], ["我我"], True, ["我到了"], ["我我"]),
        ("micro-06", "不不急慢慢来", "不急，慢慢来。", ["不着急", "慢慢来"], ["不不"], True, ["不急", "慢慢来"], ["不不"]),
        ("micro-07", "行行行，我知道了。", "行行行，我知道了。", ["有意重复的行行行", "已经知道"], [], False, ["行行行", "我知道了"], []),
        ("micro-08", "发第二版", "发第二版。", ["第二版"], [], True, ["第二版"], []),
    ]
    return [
        new_case(
            case_id=case_id,
            group="micro_text",
            scene="chat",
            title=f"极短文本 {index + 1}",
            spoken=spoken,
            reference=reference,
            preserve=preserve,
            remove=remove,
            dimensions=["minimal_edit", "tone_preservation", "deliberate_repetition_preservation"],
            requires_transformation=requires,
            required_substrings=required,
            forbidden_substrings=forbidden,
            challenge_tags=["short_text"],
        )
        for index, (case_id, spoken, reference, preserve, remove, requires, required, forbidden)
        in enumerate(specs)
    ]


def context_fixture(
    context_type: str,
    level: str,
    safety: str,
    *,
    selected: str | None = None,
    before: str | None = None,
    after: str | None = None,
    recent: list[str] | None = None,
) -> dict:
    return {
        "type": context_type,
        "level": level,
        "safety": safety,
        "selected_text": selected,
        "text_before_cursor": before,
        "text_after_cursor": after,
        "recent_muse_inputs": recent or [],
    }


def context_cases() -> list[dict]:
    rows = [
        {
            "id": "context-01", "type": "nearby_safe", "scene": "workChat",
            "spoken": "灵建这次更新先发给测试组确认没问题再发客户",
            "reference": "灵简这次更新先发给测试组确认，没问题后再发给客户。",
            "before": "项目统一名称是“灵简”，上一条消息也使用了“灵简”。",
            "required": ["灵简", "测试组", "客户"], "forbidden": ["灵建"],
        },
        {
            "id": "context-02", "type": "nearby_safe", "scene": "workChat",
            "spoken": "Max A I社群的课程母版先别动图片只改标题",
            "reference": "MaxAI 社群的课程母版先不要改图片，只修改标题。",
            "before": "当前项目：MaxAI 社群。文件：课程母版。",
            "required": ["MaxAI 社群", "课程母版", "标题"], "forbidden": ["Max A I"],
        },
        {
            "id": "context-03", "type": "nearby_safe", "scene": "customerSupport",
            "spoken": "work buddy这次还是识别不到输入框让他先开辅助功能",
            "reference": "WorkBuddy 这次仍然识别不到输入框，请先开启辅助功能。",
            "before": "客户当前使用的软件是 WorkBuddy。",
            "required": ["WorkBuddy", "辅助功能"], "forbidden": ["work buddy"],
        },
        {
            "id": "context-04", "type": "nearby_safe", "scene": "code",
            "spoken": "voice polish pipeline的修复先跑测试再合并",
            "reference": "VoicePolishPipeline 的修复先运行测试，再合并。",
            "before": "正在审查 `VoicePolishPipeline` 的实现。",
            "required": ["VoicePolishPipeline", "测试", "合并"], "forbidden": ["voice polish pipeline"],
        },
        {
            "id": "context-05", "type": "selected_safe", "scene": "workChat",
            "spoken": "森斯 voice服务启动后先看 health",
            "reference": "SenseVoice 服务启动后，先检查 health。",
            "selected": "SenseVoice 服务启动说明",
            "required": ["SenseVoice", "health"], "forbidden": ["森斯 voice"],
        },
        {
            "id": "context-06", "type": "selected_safe", "scene": "workChat",
            "spoken": "接口调试完成以后再定上线时间",
            "reference": "接口联调完成后，再确定上线时间。",
            "selected": "接口联调排期与上线检查",
            "required": ["接口联调", "上线时间"], "forbidden": ["接口调试"],
        },
        {
            "id": "context-07", "type": "recent_safe", "scene": "workChat",
            "spoken": "戴量老师那边确认以后我再发最终版",
            "reference": "大梁老师确认后，我再发送最终版。",
            "recent": ["大梁老师刚确认了课程结构。"],
            "required": ["大梁老师", "最终版"], "forbidden": ["戴量老师"],
        },
        {
            "id": "context-08", "type": "recent_safe", "scene": "code",
            "spoken": "缪斯这次构建通过以后覆盖安装",
            "reference": "Muse 这次构建通过后，覆盖安装。",
            "recent": ["Muse 的 Release 构建正在执行。"],
            "required": ["Muse", "构建", "覆盖安装"], "forbidden": ["缪斯"],
        },
        {
            "id": "context-09", "type": "conflicting_safe", "scene": "workChat",
            "spoken": "灵建这个名字我还没确认先保留别替我猜",
            "reference": "“灵建”这个名字尚未确认，请先保留，不要替我猜测。",
            "before": "上文有人写“灵简”。", "after": "下文另一处写“灵境”。",
            "required": ["灵建", "尚未确认"], "forbidden": [],
        },
        {
            "id": "context-10", "type": "irrelevant_safe", "scene": "workChat",
            "spoken": "明天下午把方案发给客户确认",
            "reference": "明天下午把方案发给客户确认。",
            "before": "另一个项目的内部代号是 Aurora，但当前消息与它无关。",
            "required": ["明天下午", "客户"], "forbidden": ["Aurora"],
        },
        {
            "id": "context-11", "type": "secure_blocked", "scene": "chat",
            "spoken": "帮我回复已经收到",
            "reference": "已经收到。",
            "before": "安全字段中的内容绝不能进入模型：内部验证码 654321。",
            "required": ["已经收到"], "forbidden": ["654321", "验证码"],
            "safety": "secure",
        },
        {
            "id": "context-12", "type": "unknown_blocked", "scene": "chat",
            "spoken": "跟他说我晚十分钟到",
            "reference": "跟他说我会晚 10 分钟到。",
            "before": "未知控件里有无关的人名王小明和地址海棠路八号。",
            "required": ["晚 10 分钟"], "forbidden": ["王小明", "海棠路八号"],
            "safety": "unknown",
        },
    ]

    result = []
    for row in rows:
        level = "selectedText" if row["type"] == "selected_safe" else "nearbyText"
        if row["type"] == "recent_safe":
            level = "metadataOnly"
        fixture = context_fixture(
            row["type"],
            level,
            row.get("safety", "safe"),
            selected=row.get("selected"),
            before=row.get("before"),
            after=row.get("after"),
            recent=row.get("recent"),
        )
        item = new_case(
            case_id=row["id"],
            group="context_correction",
            scene=row["scene"],
            title=f"授权上下文纠错 {row['id'].split('-')[-1]}",
            spoken=row["spoken"],
            reference=row["reference"],
            preserve=row["required"],
            remove=row["forbidden"],
            dimensions=["contextual_typo_correction", "context_non_leakage", "terminology"],
            requires_transformation=True,
            required_substrings=row["required"],
            forbidden_substrings=row["forbidden"],
            context_fixture=fixture,
            challenge_tags=["context"],
            blind_categories=["proper_noun"] if row["id"] <= "context-09" else [],
        )
        item["automatic_checks"]["forbidden_context_substrings"] = row["forbidden"]
        result.append(item)
    return result


def numbered_case(
    *,
    case_id: str,
    group: str,
    scene: str,
    title: str,
    items: list[tuple[str, str, str, str]],
    prefix_segments: list[str] | None = None,
    prefix_reference: list[str] | None = None,
    old_facts: list[str] | None = None,
    final_facts: list[str] | None = None,
) -> dict:
    raw_segments = list(prefix_segments or [])
    reference_lines = list(prefix_reference or [])
    if not prefix_segments:
        raw_segments.append(f"下面共 {len(items)} 项，请按原顺序逐项整理，每项都要完整保留")
        reference_lines.append(f"工作安排（共 {len(items)} 项）：")
    required = list(final_facts or [])
    for index, (subject, owner, deadline, action) in enumerate(items, start=1):
        deadline_limit = deadline if deadline.endswith("前") else f"{deadline}前"
        variants = [
            f"关于{subject}，负责人是{owner}，要求{deadline_limit}{action}，这部分别漏，验收时要把实际结果和原始要求逐项核对，如果遇到阻塞就写清真实原因不要替换任务目标，这部分需要单独交代",
            f"{subject}，由{owner}负责，截止{deadline}，交付内容是{action}，要完整保留，交付时同时说明当前状态和待确认事项，不要因为内容长就把这一块概括掉，这部分不能省略",
            f"{subject}，现在归{owner}跟进，{deadline_limit}要{action}，不要合并到别的任务，完成后请按对应标准复核，不能借用相邻任务的结果代替，复核结论也要留下",
            f"{subject}，由{owner}负责，时间是{deadline}，动作是{action}，这个也要写进去，如果外部条件发生变化只更新受影响部分，其余事实和约束仍然原样保留，变化原因需要可追溯",
        ]
        raw_segments.append(variants[(index - 1) % len(variants)])
        reference_lines.append(f"{index}. {subject}：由{owner}负责，{deadline_limit}{action}。")
        required.extend([subject, owner, deadline, action])
    spoken = "".join(raw_segments)
    reference = "\n".join(reference_lines)
    required = list(dict.fromkeys(required))
    return new_case(
        case_id=case_id,
        group=group,
        scene=scene,
        title=title,
        spoken=spoken,
        reference=reference,
        preserve=required,
        remove=list(old_facts or []),
        dimensions=[
            "long_content_completion", "semantic_layout", "multi_segment",
            "independent_constraint_preservation",
        ] + (["cross_segment_correction"] if prefix_segments else []),
        requires_transformation=True,
        required_substrings=required,
        forbidden_substrings=list(old_facts or []),
        format_expectation=f"按原顺序列出 {len(items)} 项，前置信息单独成段",
        segments=raw_segments,
        min_list_items=len(items),
        challenge_tags=["long_text", "list"] + (["self_correction"] if old_facts else []),
        blind_categories=["list", "numbers"] + (["self_correction"] if old_facts else []),
    )


def make_items(subjects: list[str], owners: list[str], deadlines: list[str], actions: list[str]) -> list[tuple[str, str, str, str]]:
    return [
        (
            subject,
            owners[index % len(owners)],
            deadlines[index % len(deadlines)],
            actions[index % len(actions)],
        )
        for index, subject in enumerate(subjects)
    ]


def long_cases() -> list[dict]:
    owners = ["小陈", "小林", "产品组", "设计组", "开发组", "测试组", "运营组", "大梁老师"]
    deadlines = ["周一上午", "周二下班前", "周三中午", "周四下午", "周五发布前", "下周一十点"]
    actions = [
        "补齐验收截图", "确认最终文案", "跑完回归测试", "整理风险清单",
        "核对数据来源", "完成客户复核", "更新操作说明", "归档本轮结论",
    ]

    cases = [
        numbered_case(
            case_id="long-01", group="long_text", scene="workChat", title="长项目更新与跨段日期改口",
            prefix_segments=[
                "先说发布时间原定八月二十日这部分先记一下",
                "不对刚确认最终发布时间是八月二十八日要以这个为准下面共 6 项工作",
            ],
            prefix_reference=["最终发布时间为 8 月 28 日。", "工作安排（共 6 项）："],
            old_facts=["八月二十日", "8 月 20 日"], final_facts=["8 月 28 日"],
            items=make_items(
                ["首页文案", "引导截图", "权限说明", "长文润色", "历史记录", "安装包签名"],
                owners, deadlines, actions,
            ),
        ),
        numbered_case(
            case_id="long-02", group="long_text", scene="document", title="长会议纪要与跨段预算改口",
            prefix_segments=[
                "预算先按一万六千八准备这句在前面",
                "我改一下最终预算是一万六不能再保留旧数字会议共 7 项决定",
            ],
            prefix_reference=["最终预算为 16,000。", "会议决定（共 7 项）："],
            old_facts=["一万六千八", "16,800"], final_facts=["16,000"],
            items=make_items(
                ["课程定位", "目标用户", "交付形式", "录制顺序", "质检标准", "发布时间", "复盘机制"],
                owners[1:], deadlines, actions[1:],
            ),
        ),
        numbered_case(
            case_id="long-03", group="long_text", scene="customerSupport", title="客户问题长交接单",
            items=make_items(
                ["登录失败", "授权弹窗", "识别延迟", "长文回退", "剪贴板恢复", "菜单栏图标", "版本升级"],
                owners, deadlines, actions,
            ),
        ),
        numbered_case(
            case_id="long-04", group="long_text", scene="code", title="发布前长技术检查",
            items=make_items(
                ["Debug 构建", "Release 构建", "Swift 全量测试", "Python 服务测试", "Bundle ID", "严格签名", "二进制 UUID", "单一进程"],
                owners[2:], deadlines, actions,
            ),
        ),
    ]

    medium_subject_sets = [
        ("long-05", "email", "课程生产长交接邮件", [
            "选题确认", "脚本初稿", "事实核查", "口播录制", "界面截图", "图片标注", "字幕校对",
            "封面设计", "课程剪辑", "素材授权", "章节说明", "学员作业", "发布检查", "数据复盘",
        ]),
        ("long-06", "aiPrompt", "复杂 AI 任务约束", [
            "研究目标", "来源范围", "发布日期", "事实引用", "竞品数量", "用户画像", "功能比较",
            "价格比较", "风险说明", "不得预测", "输出结构", "表格字段", "结论边界", "复核清单",
        ]),
        ("long-07", "document", "产品需求长清单", [
            "录音启动", "流式识别", "终包处理", "术语纠正", "安全上下文", "口误清理", "语义分段",
            "列表整理", "事实保护", "失败回退", "历史诊断", "用户纠正", "自动学习", "隐私退出",
        ]),
        ("long-08", "socialPost", "内容计划长口述", [
            "主题开场", "真实经历", "问题背景", "第一次尝试", "失败原因", "第二次调整", "关键转折",
            "实际结果", "适用对象", "不适用对象", "方法步骤", "注意事项", "个人感受", "自然收束",
        ]),
    ]
    for case_id, scene, title, subjects in medium_subject_sets:
        cases.append(numbered_case(
            case_id=case_id,
            group="very_long_text",
            scene=scene,
            title=title,
            items=make_items(subjects, owners, deadlines, actions),
        ))

    ultra_subjects_1 = [
        "首页结构", "首页文案", "注册流程", "登录流程", "权限引导", "快捷键设置", "录音提示音", "流式字幕",
        "停止录音", "终包等待", "网络重连", "批量兜底", "术语热词", "错词替换", "上下文捕获", "场景判断",
        "短句成稿", "长文成稿", "改口识别", "口吃清理", "错标点重建", "错断句重建", "自然分段", "步骤列点",
        "事实校验", "数字保护", "专名保护", "路径保护", "命令保护", "模型超时", "输出截断", "安全回退",
        "历史状态", "性能诊断", "纠正入口", "术语学习", "表达学习", "隐私开关", "模型配置", "安装打包",
        "严格签名", "Bundle 核验", "进程核验", "自动更新", "发布说明", "用户引导", "客服手册", "质量复盘",
    ]
    ultra_subjects_2 = [
        "课程总目标", "学员起点", "第一章导览", "第二章安装", "第三章账号", "第四章模型", "第五章提示词", "第六章语音输入",
        "第七章文本润色", "第八章文件处理", "第九章网页研究", "第十章图片生成", "第十一章视频制作", "第十二章表格分析",
        "第十三章文档排版", "第十四章幻灯片", "第十五章知识库", "第十六章自动化", "第十七章 Agent", "第十八章 Skill",
        "第十九章 MCP", "第二十章安全", "真实截图", "截图标注", "示例账号脱敏", "API Key 脱敏", "录屏节奏", "口播校对",
        "字幕规范", "章节封面", "课程作业", "参考答案", "常见错误", "学员问答", "更新日志", "版本兼容",
        "Windows 差异", "macOS 差异", "移动端边界", "教师手册", "助教手册", "发布页文案", "购买须知", "售后说明",
        "内容授权", "最终质检",
    ]
    cases.append(numbered_case(
        case_id="long-09", group="ultra_long_text", scene="document", title="超长产品全链路复盘",
        items=make_items(ultra_subjects_1, owners, deadlines, actions),
    ))
    cases.append(numbered_case(
        case_id="long-10", group="ultra_long_text", scene="document", title="超长课程生产总计划",
        items=make_items(ultra_subjects_2, owners[::-1], deadlines[::-1], actions[::-1]),
    ))
    return cases


def enrich_source_dataset(document: dict) -> tuple[list[dict], list[dict]]:
    cases = []
    for original in document["cases"]:
        item = copy.deepcopy(original)
        item["length_bucket"] = length_bucket(item["spoken_input"])
        item["context_type"] = "none"
        item["quality_dimensions"] = common_dimensions(item)
        item["requires_transformation"] = True
        item["segment_texts"] = [item["spoken_input"]]
        item["automatic_checks"] = {
            "required_substrings": [],
            "forbidden_substrings": [],
            "forbidden_context_substrings": [],
        }
        cases.append(item)

    variants = []
    base_by_id = {item["id"]: item for item in cases}
    for original in document["stress_variants"]:
        item = copy.deepcopy(original)
        base = base_by_id[item["base_case_id"]]
        item["length_bucket"] = length_bucket(item["spoken_input"])
        item["context_type"] = "none"
        item["quality_dimensions"] = sorted(set(common_dimensions(item) + base["quality_dimensions"]))
        item["requires_transformation"] = True
        item["segment_texts"] = [item["spoken_input"]]
        item["automatic_checks"] = {
            "required_substrings": [],
            "forbidden_substrings": [],
            "forbidden_context_substrings": [],
        }
        variants.append(item)
    return cases, variants


def main() -> None:
    source = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
    cases, variants = enrich_source_dataset(source)
    cases.extend(short_cases())
    cases.extend(context_cases())
    cases.extend(long_cases())

    document = {
        "schema_version": 4,
        "name": "Muse 语音润色多维产品质量测试集 V2.0",
        "created_at": "2026-08-17",
        "language": "zh-CN",
        "source_dataset": SOURCE_PATH.name,
        "north_star_metric": "direct_send",
        "rating_scale": source["rating_scale"],
        "case_count": len(cases),
        "stress_variant_count": len(variants),
        "total_input_count": len(cases) + len(variants),
        "length_bucket_definitions": {
            "micro_1_15": "1～15 字，验证最小必要修改与不过度改写",
            "short_16_80": "16～80 字，验证日常消息成稿",
            "medium_81_300": "81～300 字，验证多句与轻结构",
            "long_301_1000": "301～1000 字，验证完整长消息",
            "very_long_1001_3000": "1001～3000 字，验证多主题长文",
            "ultra_long_3001_8000": "3001～8000 字，验证超长成稿与不截断",
        },
        "length_bucket_coverage_requirements": {
            "micro_1_15": 8,
            "short_16_80": 25,
            "medium_81_300": 20,
            "long_301_1000": 4,
            "very_long_1001_3000": 4,
            "ultra_long_3001_8000": 2,
        },
        "context_type_definitions": {
            "none": "不提供正文上下文",
            "nearby_safe": "安全输入框附近文字",
            "selected_safe": "用户明确选中的安全文字",
            "recent_safe": "同一应用近期 Muse 输入",
            "conflicting_safe": "授权上下文存在冲突，不得猜测",
            "irrelevant_safe": "上下文含无关事实，不得注入正文",
            "secure_blocked": "安全字段正文必须被清空",
            "unknown_blocked": "未知控件正文必须被清空",
        },
        "context_type_coverage_requirements": {
            "none": 77,
            "nearby_safe": 4,
            "selected_safe": 2,
            "recent_safe": 2,
            "conflicting_safe": 1,
            "irrelevant_safe": 1,
            "secure_blocked": 1,
            "unknown_blocked": 1,
        },
        "quality_dimension_definitions": {
            "final_intent": "最终意图唯一且正确",
            "fact_preservation": "来源事实完整保留",
            "no_invention": "不新增无来源内容",
            "direct_send": "成稿可直接发送",
            "minimal_edit": "短文本只做必要修改",
            "tone_preservation": "保留语气与力度",
            "deliberate_repetition_preservation": "保留有意重复",
            "contextual_typo_correction": "利用授权上下文纠正错词",
            "context_non_leakage": "上下文无关内容不进入正文",
            "terminology": "专名和中英混排正确",
            "long_content_completion": "长文不摘要、不截断、不回退",
            "semantic_layout": "按语义分段或列点",
            "multi_segment": "真实多 ASR segment",
            "cross_segment_correction": "跨 segment 只保留最终事实",
            "independent_constraint_preservation": "独立事项和约束逐项保留",
            "correction_resolution": "改口正确收口",
            "disfluency_cleanup": "口吃和机械重复清理",
            "prompt_not_execution": "AI Prompt 只整理不执行",
        },
        "quality_dimension_coverage_requirements": {
            "minimal_edit": 8,
            "tone_preservation": 8,
            "deliberate_repetition_preservation": 8,
            "contextual_typo_correction": 12,
            "context_non_leakage": 12,
            "long_content_completion": 10,
            "semantic_layout": 20,
            "multi_segment": 10,
            "cross_segment_correction": 2,
        },
        "input_factor_definitions": source["input_factor_definitions"],
        "factor_acceptance_rules": source["factor_acceptance_rules"],
        "factor_coverage_requirements": source["factor_coverage_requirements"],
        "stutter_form_definitions": source["stutter_form_definitions"],
        "stutter_form_coverage_requirements": source["stutter_form_coverage_requirements"],
        "cases": cases,
        "stress_variants": variants,
    }
    OUTPUT_PATH.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    rows = []
    for item in cases:
        rows.append((item["id"], item["id"], "base", item))
    for item in variants:
        rows.append((item["id"], item["base_case_id"], "stress_variant", item))
    with RUN_PATH.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow([
            "test_input_id", "base_case_id", "input_kind", "length_bucket", "context_type",
            "quality_dimensions", "requires_transformation", "model_output", "fallback_used",
            "validation_codes", "hard_checks", "rating", "reviewer", "notes",
        ])
        for test_id, base_id, kind, item in rows:
            writer.writerow([
                test_id, base_id, kind, item["length_bucket"], item["context_type"],
                "+".join(item["quality_dimensions"]), str(item["requires_transformation"]).lower(),
                "", "", "", "", "", "", "",
            ])

    print(f"生成完成：{len(cases)} 条基准 + {len(variants)} 条变体 = {len(rows)} 次输入")
    print(OUTPUT_PATH)
    print(RUN_PATH)


if __name__ == "__main__":
    main()
