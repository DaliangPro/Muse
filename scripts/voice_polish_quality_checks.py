#!/usr/bin/env python3
"""Voice Polish 冻结集与报告验收共用的语义关系检查。"""

from __future__ import annotations

import re


LIST_MARKER = re.compile(
    r"^\s*(?:(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）])\s*|[-*•]\s+)"
)


def relation_blocks(text: str) -> list[str]:
    """列表项互不借词；普通段落保留后续撤销、改派与条件语境。"""
    expanded = re.sub(
        r"(?m)(^|\s+)(?=(?:(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）])\s*|[-*•]\s+))",
        "\n",
        text,
    )
    blocks: list[str] = []
    current_item: list[str] = []
    current_paragraph: list[str] = []

    def flush_paragraph() -> None:
        if current_paragraph:
            blocks.append(" ".join(current_paragraph))
            current_paragraph.clear()

    def flush_item() -> None:
        if current_item:
            blocks.append(" ".join(current_item))
            current_item.clear()

    for line in expanded.splitlines():
        stripped = line.strip()
        if not stripped:
            flush_item()
            flush_paragraph()
            continue
        if LIST_MARKER.match(stripped):
            flush_paragraph()
            flush_item()
            current_item.append(stripped)
        elif current_item:
            current_item.append(stripped)
        else:
            current_paragraph.append(stripped)
    flush_item()
    flush_paragraph()
    return list(dict.fromkeys(blocks))


def _string_values(value: object) -> list[str]:
    if isinstance(value, str) and value:
        return [value]
    if isinstance(value, list):
        return [entry for entry in value if isinstance(entry, str) and entry]
    return []


def _field_present(block: str, value: object) -> bool:
    alternatives = _string_values(value)
    return not alternatives or any(token in block for token in alternatives)


def _selected_value(block: str, value: object) -> str | None:
    return next((token for token in _string_values(value) if token in block), None)


RESPONSIBILITY = r"负责|牵头|跟进|执行|处理|接手|承接"
DELIVERY = r"提交|交付|交|完成|给出|整理|补齐|补充|制作|精简|更新|归档|复核"
NEGATIVE_ROLE = r"不负责|不牵头|只旁听|仅旁听|旁听|只协助|仅协助|协助|只参与|仅参与|参与|名义上"
GLOBAL_REVOCATION = (
    r"(?:以上|上述|前述|这项|这套|该)(?:安排|分工|记录|说法)?.{0,12}"
    r"(?:作废|取消|不作数|无效|撤销)"
    r"|这只是旧记录.{0,8}(?:撤销|作废|取消|不作数|无效)"
    r"|(?:全部|均|都).{0,4}(?:作废|取消|不作数|无效|撤销)"
    r"|(?:负责人|截止时间|动作|任务).{0,6}(?:对调|互换|交换)"
)
UNCONFIRMED_CLAIM = r"尚未确认|还未确认|没有确认|目前未定|仍未确定|只是传言|并不属实"
MODAL_PREFIX = r"如果|假如|假设|假定|有人说|有人误称|据说|传言|误称"
TIME_EXPRESSION = (
    r"周[一二三四五六日天](?:上午|下午|中午|晚上|下班前)?"
    r"|(?:今天|明天|后天|今晚|明早|本周|下周[一二三四五六日天]?)(?:上午|下午|中午|晚上)?"
    r"|\d{1,2}月\d{1,2}日|\d{1,2}(?:点|时)"
)


def _action_match(block: str, value: object) -> re.Match[str] | None:
    """动作允许插入任务对象，也允许“验收截图需要补齐”的宾语前置。"""
    for token in _string_values(value):
        exact = re.search(re.escape(token), block)
        if exact:
            return exact
        for verb in sorted(DELIVERY.split("|"), key=len, reverse=True):
            if not token.startswith(verb):
                continue
            object_text = token[len(verb):]
            if not object_text:
                continue
            flexible = re.search(
                rf"{re.escape(verb)}.{{0,24}}?{re.escape(object_text)}",
                block,
            )
            if flexible:
                return flexible
            object_first = re.search(
                rf"{re.escape(object_text)}.{{0,16}}?(?:需要|须|应当|应)?"
                rf".{{0,4}}?{re.escape(verb)}",
                block,
            )
            if object_first:
                return object_first
    return None


def _value_position(block: str, value: object) -> tuple[str | None, int]:
    token = _selected_value(block, value)
    return token, block.find(token) if token else -1


def _locally_negated(block: str, token: str, *, before: int = 5, after: int = 8) -> bool:
    position = block.find(token)
    if position < 0:
        return True
    window = block[max(0, position - before): position + len(token) + after]
    if re.search(
        rf"(?:最晚)?(?:不晚于|不迟于|不超过).{{0,4}}{re.escape(token)}",
        window,
    ):
        return False
    return bool(re.search(
        rf"(?:不|未|没有|无需|(?<!分)别|并非|不是).{{0,3}}{re.escape(token)}"
        rf"|{re.escape(token)}.{{0,4}}(?:不完成|不提交|不交付|不执行|不处理|不补|不做|不作数|取消|作废)",
        window,
    ))


def _claim_is_nonasserted(block: str, first_relation_position: int) -> bool:
    prefix = block[max(0, first_relation_position - 72):first_relation_position]
    return bool(
        re.search(MODAL_PREFIX, prefix)
        or re.search(
            r"(?:旧|历史|过期的?|上周|上次|此前|之前的?)(?:会议纪要|记录|文档|版本|说法)"
            r".{0,12}(?:写道|记载|显示|提到|称)",
            prefix,
        )
        or re.search(GLOBAL_REVOCATION, block)
        or re.search(UNCONFIRMED_CLAIM, block)
    )


def _has_later_reassignment(scope: str, owner: str, relation_end: int) -> bool:
    tail = scope[relation_end:]
    direct = re.search(
        r"(?:(?:后来|随后|后续|实际|现(?:在)?|最终)\s*(?:归|改由|交由|交给|转交(?:给)?|改派(?:给)?)"
        r"|(?:改由|交由|交给|转交(?:给)?|改派(?:给)?))\s*"
        r"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{1,12}?)"
        r"(?=[，,。；;\s]|负责|接手|牵头|跟进|执行|$)",
        tail,
    )
    if direct and owner not in direct.group("actor"):
        return True
    owner_changed = re.search(
        r"负责人.{0,8}(?:换成|变成|改成|调整为)\s*"
        r"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{1,12}?)"
        r"(?=[，,。；;\s]|$)",
        tail,
    )
    if owner_changed and owner not in owner_changed.group("actor"):
        return True
    for match in re.finditer(
        r"(?:后来|随后|后续|实际|现(?:在)?|最终|改为|改由|改派|转交|交给)"
        r".{0,18}?(?:接手|负责|牵头|跟进|执行|改派)",
        tail,
    ):
        if owner not in match.group(0):
            return True
    return False


def _due_and_action_share_claim(
    scope: str,
    due: str,
    action_match: re.Match[str],
) -> bool:
    labeled = re.search(
        rf"(?:截止|时间|期限)\s*[：:]?\s*{re.escape(due)}"
        rf".{{0,40}}?(?:动作|任务|交付(?:内容)?)\s*[：:]?.{{0,8}}?"
        rf"{re.escape(action_match.group(0))}",
        scope,
    )
    if labeled:
        return True
    due_position = scope.find(due)
    if due_position < 0:
        return False
    action_position = action_match.start()
    left = min(due_position, action_position)
    right = max(due_position + len(due), action_match.end())
    if right - left > 56:
        return False
    between = scope[min(due_position + len(due), action_match.end()):max(due_position, action_position)]
    if re.search(r"[；;。！？!?]", between):
        return False
    if action_match.end() <= due_position:
        after_action = scope[action_match.end():due_position]
        if re.match(r"\s*(?:后|之后|完成后|结束后|以后)", after_action):
            return False
    elif due_position + len(due) <= action_match.start():
        before_action = scope[due_position + len(due):action_match.start()]
        event_matches = list(re.finditer(
            r"参加|出席|开会|例会|沟通|讨论|汇报|复盘|等待|发送|提交|"
            r"确认|检查|处理|跟进|拜访|采访|培训|演示",
            before_action,
        ))
        if event_matches:
            last_event = event_matches[-1]
            direct_predicate_tail = before_action[last_event.start():]
            direct_predicate = re.fullmatch(
                r"(?:前|之前)?(?:并|再|分别|随后)?"
                r"(?:提交|确认|检查|处理|跟进|发送)"
                r"(?:[一二三四五六七八九十两\d]+(?:步|张|项|份|个)?)?",
                direct_predicate_tail,
            )
            if not direct_predicate:
                # “周一参加例会，随后补齐截图”中的周一属于例会，不能借给
                # 后面的截图动作当截止时间；“周二前确认三步操作顺序”中的
                # “确认三步”则正是名词型 action 的谓词，不能误判为另一事件。
                return False
    time_pattern = re.compile(TIME_EXPRESSION)
    times = list(time_pattern.finditer(scope))
    if times:
        action_center = (action_match.start() + action_match.end()) / 2
        nearest = min(times, key=lambda match: abs(
            (match.start() + match.end()) / 2 - action_center
        ))
        if not (
            nearest.start() <= due_position < nearest.end()
            or due_position <= nearest.start() < due_position + len(due)
        ):
            return False
    local_prefix = scope[max(0, left - 24):left]
    if re.search(MODAL_PREFIX, local_prefix):
        return False
    return True


def _action_is_assigned_to_other(scope: str, action: object, owner: str) -> bool:
    non_actor_tokens = {
        "并", "并且", "随后", "然后", "同时", "另外", "再", "接着",
        "届时", "按时", "及时", "最终", "最后", "目前", "当前",
        "负责", "需要", "应当", "必须", "计划", "预计", "准备",
        "他", "她", "他们", "她们", "其", "本人", "负责人",
    }

    def is_explicit_other_actor(actor: str) -> bool:
        if not actor or owner in actor or actor in non_actor_tokens:
            return False
        if len(actor) > 8:
            return False
        if re.search(
            r"(?:本周|下周|周[一二三四五六日天]|今天|明天|后天|今晚|明早|"
            r"上午|下午|中午|晚上|下班前|[0-9一二三四五六七八九十]+(?:点|时)|"
            r"最晚|截止|期限|完成后|之后)",
            actor,
        ):
            return False
        return True

    for token in _string_values(action):
        for verb in sorted(DELIVERY.split("|"), key=len, reverse=True):
            if not token.startswith(verb):
                continue
            object_text = token[len(verb):]
            if not object_text:
                continue
            patterns = [
                rf"{re.escape(object_text)}.{{0,8}}?(?:由|让|交给)"
                rf"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{{1,12}}?){re.escape(verb)}",
                rf"{re.escape(verb)}.{{0,24}}?{re.escape(object_text)}.{{0,6}}?"
                rf"(?:的是|由)(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{{1,12}}?)"
                rf"(?=[，,；;。！？!?\s]|$)",
                # 显式 actor-first：王五将在周一补齐验收截图 / 王五周一补齐…。
                # actor 与动作必须位于同一逗号级小句，避免从前一句借负责人。
                rf"(?:^|[，,；;。！？!?：:])\s*"
                rf"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{{1,12}}?)"
                rf"(?:(?:将|会|计划|预计|准备|需要|应当|负责)(?:在|于)?(?:{TIME_EXPRESSION})?(?:前|之前)?"
                rf"|(?:在|于)?(?:{TIME_EXPRESSION})(?:前|之前)?)"
                rf"{re.escape(verb)}.{{0,24}}?{re.escape(object_text)}",
                rf"(?:^|[，,；;。！？!?：:])\s*"
                rf"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{{1,12}}?)"
                rf"{re.escape(verb)}.{{0,24}}?{re.escape(object_text)}",
            ]
            for pattern in patterns:
                for match in re.finditer(pattern, scope):
                    actor = match.group("actor")
                    if re.search(
                        r"最晚|不晚于|不迟于|不超过|截止|时间|期限|当天|当日",
                        actor,
                    ):
                        # “最晚不超过周一补齐”里的时间限定语不是执行人。
                        continue
                    if actor in non_actor_tokens:
                        # “小陈负责首页，并于周一补齐截图”延续上一小句主语；
                        # 连接词本身不是新的执行人。
                        continue
                    if re.fullmatch(rf"(?:{TIME_EXPRESSION})(?:前|之前)?", actor):
                        continue
                    if re.search(
                        r"(?:本周|下周|周[一二三四五六日天]|今天|明天|后天|今晚|明早|"
                        r"上午|下午|中午|晚上|下班前|[0-9一二三四五六七八九十]+(?:点|时))",
                        actor,
                    ):
                        continue
                    if is_explicit_other_actor(actor):
                        return True

            # 动作完成后又明确写“归/属于/由王五承担”，说明交付动作并不属于
            # 期望负责人；这类后置归属不能只靠前面的“由 X 负责”借词通过。
            post_assignment_patterns = [
                rf"{re.escape(token)}.{{0,8}}?(?:归|属于|交由|由)\s*"
                rf"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{{1,8}}?)"
                rf"(?=[，,；;。！？!?\s]|承担|负责|完成|$)",
                rf"{re.escape(object_text)}.{{0,8}}?(?:归|属于|交由|由)\s*"
                rf"(?P<actor>[\u4e00-\u9fffA-Za-z0-9·]{{1,8}}?)"
                rf"(?=[，,；;。！？!?\s]|承担|负责|完成|$)",
            ]
            for pattern in post_assignment_patterns:
                for match in re.finditer(pattern, scope):
                    if is_explicit_other_actor(match.group("actor")):
                        return True
    return False


def _subject_anchors(subject: str) -> list[str]:
    anchors = [subject]
    if len(subject) >= 4:
        anchors.append(subject[:2])
    return list(dict.fromkeys(anchors))


def _parallel_assignment(
    target: dict,
    assignments: list[dict],
    block: str,
) -> bool:
    if "分别" not in block:
        return False
    related = [
        group for group in assignments
        if _field_present(block, group.get("subject"))
        and _field_present(block, group.get("owner"))
    ]
    if len(related) < 2 or target not in related:
        return False
    related.sort(key=lambda group: block.find(_selected_value(block, group.get("subject")) or ""))

    subjects = [_selected_value(block, group.get("subject")) for group in related]
    owners = [_selected_value(block, group.get("owner")) for group in related]
    if any(value is None for value in subjects + owners):
        return False
    owner_positions = [block.find(value) for value in owners]
    if owner_positions != sorted(owner_positions) or len(set(owner_positions)) != len(owner_positions):
        return False

    first_separate = block.find("分别")
    first_subject = min(block.find(value) for value in subjects if value)
    if _claim_is_nonasserted(block, first_subject):
        return False
    first_clause = re.split(r"[，,；;。]", block[first_separate:], maxsplit=1)[0]
    if re.search(r"不由|并非|不是|" + NEGATIVE_ROLE, first_clause):
        return False
    if not re.search(RESPONSIBILITY, first_clause):
        return False

    due_values = [_selected_value(block, group.get("due")) for group in related]
    if any(value is not None for value in due_values):
        if any(value is None for value in due_values):
            return False
        due_positions = [block.find(value) for value in due_values]
        if due_positions != sorted(due_positions) or len(set(due_positions)) != len(due_positions):
            return False
        if re.search(r"分别\s*(?:不|并非|不是)", block) or any(
            _locally_negated(block, value) for value in due_values if value
        ):
            return False

    action_matches = [_action_match(block, group.get("action")) for group in related]
    if any(value is not None for value in action_matches):
        if any(value is None for value in action_matches):
            return False
        action_positions = [value.start() for value in action_matches if value]
        if action_positions != sorted(action_positions) or len(set(action_positions)) != len(action_positions):
            return False
        if any(_locally_negated(block, value.group(0)) for value in action_matches if value):
            return False

    relation_end = max(owner_positions + [first_separate])
    if _has_later_reassignment(block, target.get("owner", ""), relation_end):
        return False
    tail = block[relation_end:]
    for group in related:
        expected_owner = _selected_value(block, group.get("owner"))
        if not expected_owner:
            return False
        competing = [
            _selected_value(block, other.get("owner"))
            for other in related if other is not group
        ]
        for anchor in _subject_anchors(_selected_value(block, group.get("subject")) or ""):
            if any(
                other_owner
                and re.search(
                    rf"{re.escape(anchor)}.{{0,10}}?(?:归|由|交给|交由|改由|改派(?:给)?)\s*{re.escape(other_owner)}",
                    tail,
                )
                for other_owner in competing
            ):
                return False
    if re.search(GLOBAL_REVOCATION, block[relation_end:]):
        return False
    return all(_field_present(block, target.get(field)) for field in ("due", "action"))


def _assignment_is_preserved(group: dict, groups: list[dict], block: str) -> bool:
    assignments = [entry for entry in groups if entry.get("mode") == "assignment"]
    if _parallel_assignment(group, assignments, block):
        return True

    subject = _selected_value(block, group.get("subject"))
    owner = _selected_value(block, group.get("owner"))
    if not subject or not owner:
        return False
    due = _selected_value(block, group.get("due"))
    action_match = _action_match(block, group.get("action"))
    action = action_match.group(0) if action_match else None
    if group.get("due") and not due:
        return False
    if group.get("action") and not action:
        return False

    subject_position = block.find(subject)
    subject_end = subject_position + len(subject)
    other_subject_positions = sorted(
        position
        for other in assignments
        if other is not group
        for value in [_selected_value(block, other.get("subject"))]
        for position in [block.find(value) if value else -1]
        if position >= 0
        and not (subject_position <= position < subject_end)
        and not (position <= subject_position < position + len(value or ""))
    )
    later_subjects = [position for position in other_subject_positions if position > subject_position]
    earlier_subjects = [position for position in other_subject_positions if position < subject_position]
    if earlier_subjects:
        preceding_delimiters = [
            block.rfind(token, max(earlier_subjects), subject_position)
            for token in "，,；;。！？!?"
        ]
        start = max(preceding_delimiters) + 1
    else:
        # 第一条关系必须保留句首的“如果/有人说”等语气证据，不能从主语处
        # 截断后把假设或引语误当成已经确认的分工。
        start = 0
    end = min(later_subjects) if later_subjects else len(block)
    scope = block[start:end]

    local_subject_position = scope.find(subject)
    local_owner_position = scope.find(owner)
    first_relation_position = min(
        position for position in (local_subject_position, local_owner_position) if position >= 0
    )
    if _claim_is_nonasserted(scope, first_relation_position):
        return False
    if due and _locally_negated(scope, due):
        return False
    if action and _locally_negated(scope, action):
        return False
    if due and action_match and not _due_and_action_share_claim(scope, due, action_match):
        return False
    if action_match and _action_is_assigned_to_other(scope, group.get("action"), owner):
        return False

    escaped_owner = re.escape(owner)
    escaped_subject = re.escape(subject)
    if re.search(rf"(?:不由|并非由|不是由)\s*{escaped_owner}", scope):
        return False
    if re.search(rf"{escaped_owner}.{{0,10}}(?:{NEGATIVE_ROLE})", scope):
        return False
    if re.search(
        rf"(?:曾由|原由|之前由|名义上由)?\s*{escaped_owner}.{{0,24}}"
        rf"(?:现改由|现在交给|实际交给|转交|改由|交给)\s*(?!{escaped_owner})",
        scope,
    ):
        return False

    competing_owners = [
        value
        for other in assignments
        if other is not group
        for value in [_selected_value(scope, other.get("owner"))]
        if value and value != owner
    ]
    if any(
        re.search(rf"(?:改由|交给|转交)\s*{re.escape(value)}", scope)
        or re.search(rf"{re.escape(value)}.{{0,10}}(?:{RESPONSIBILITY})", scope)
        for value in competing_owners
    ):
        return False

    subject_first = re.search(
        rf"{escaped_subject}.{{0,40}}?(?:由\s*)?{escaped_owner}.{{0,20}}?(?:{RESPONSIBILITY}|{DELIVERY})",
        scope,
    )
    owner_first = re.search(
        rf"{escaped_owner}.{{0,12}}?(?:{RESPONSIBILITY}).{{0,40}}?{escaped_subject}",
        scope,
    )
    owner_delivers_subject = re.search(
        rf"{escaped_owner}.{{0,24}}?(?:{DELIVERY}).{{0,32}}?{escaped_subject}",
        scope,
    )
    owner_handles_subject = re.search(
        rf"{escaped_owner}.{{0,12}}?(?:把|将).{{0,32}}?{escaped_subject}"
        rf".{{0,32}}?(?:{DELIVERY})",
        scope,
    )
    labeled = re.search(
        rf"{escaped_subject}\s*[：:].{{0,24}}(?:负责人\s*[：:]?\s*)?{escaped_owner}",
        scope,
    )
    relation = (
        subject_first or owner_first or owner_delivers_subject
        or owner_handles_subject or labeled
    )
    if not relation:
        return False
    if _has_later_reassignment(scope, owner, relation.end()):
        return False
    return True


def fact_group_is_preserved(group: dict, groups: list[dict], blocks: list[str]) -> bool:
    """按显式 mode 核验 assignment 或肯定式同块主张。"""
    mode = group.get("mode")
    if mode == "same_block":
        tokens = group.get("tokens", [])
        for block in blocks:
            if not all(token in block for token in tokens):
                continue
            positions = [block.find(token) for token in tokens]
            first = min(positions)
            last = max(position + len(token) for position, token in zip(positions, tokens))
            window = block[max(0, first - 16):min(len(block), last + 16)]
            if _claim_is_nonasserted(block, first):
                continue
            if re.search(
                r"并不代表|不代表|并非|不是|不能证明|无法证明|误称|错误地称|"
                r"实际不是|实际并非|尚未确认|还未确认|取消|撤销|作废",
                window,
            ):
                continue
            return True
        return False
    if mode != "assignment":
        return False
    return any(_assignment_is_preserved(group, groups, block) for block in blocks)
