#!/usr/bin/env python3
"""润色 Runner 报告的客观问题特征检查。

只检查能从输入与输出文字直接判断的失败特征，用于快速比较提示词、模型或参数
变体；不替代独立评审的逐条判读。每个标记都是「可能有问题」，需人工确认。

用法：
  python3 scripts/voice-polish-autocheck.py REPORT.json [REPORT2.json ...] [--ratings RATINGS.csv] [--details]
"""
import argparse
import csv
import json
import re
import sys
from collections import Counter

CORRECTION_IN_INPUT = re.compile(r"不对|说错了|口误|改一下|改成|改为|不是.{0,12}是")
CORRECTION_RESIDUE = re.compile(r"不对[，,。]|说错了|我改一下|口误")
PUBLIC_CORRECTION = re.compile(r"更正通知|勘误|更正公告|更正说明")

# 说给输入法的编辑指令：输入中出现且原样留在输出里视为残留。
EDITOR_INSTRUCTION = re.compile(
    r"帮我(?:整理|写|改|弄|润色)|整理成|整理得|写得太重|别写得太|不要写得太|"
    r"按(?:我说的|原来的|原)?顺序(?:逐项)?整理|按这个(?:分工|顺序)整理|发一条|这句别|这段别|"
    r"别放在|先别(?:真的)?开始|只整理任务|都要保留|不要换算|不要加总|别把.{0,8}对调|"
    r"按那个名称写|要保留的|不用展开"
)

COUNT_CUE = re.compile(
    r"(?:两|二|三|四|五|六|七|八|九|十|[2-9])"
    r"(?:步|个原因|个理由|件事|个事情|件事情|组|点要求|项|个问题|条要求|个要求|个方面)"
)
SEQUENCE_CUE = re.compile(r"先.{1,40}?(?:然后|再|接着).{1,40}?(?:最后|然后|再)")
LIST_LINE = re.compile(r"(?m)^\s*(?:\d+[.、)）]|[-•*]\s|[一二三四五六七八九十]+[、.])")

CN_DIGITS = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
             "六": 6, "七": 7, "八": 8, "九": 9}
CN_UNITS = {"十": 10, "百": 100, "千": 1000, "万": 10000}
CN_NUMBER = re.compile(r"[零〇一二两三四五六七八九十百千万]{2,}")
TIME_WORDS = re.compile(
    r"(?:下下|下|本|这|上)?(?:周|星期|礼拜)[一二三四五六日天]|明早|今晚|明晚|今早|后天|大后天|月底|月初"
)


def cn_to_int(text):
    total, section, number = 0, 0, 0
    for ch in text:
        if ch in CN_DIGITS:
            number = CN_DIGITS[ch]
        elif ch in CN_UNITS:
            unit = CN_UNITS[ch]
            if unit == 10000:
                section = (section + number) * unit
                total += section
                section = 0
            else:
                section += (number or 1) * unit
            number = 0
    return total + section + number


def numbers(text):
    values = set(re.findall(r"\d+(?:\.\d+)?", text))
    for token in CN_NUMBER.findall(text):
        if any(u in token for u in CN_UNITS):
            values.add(str(cn_to_int(token)))
    return values


def check(case):
    source = case["canonical_input"]
    output = case["model_output"]
    flags = []
    if case.get("fallback_used"):
        flags.append("fallback")
    if not output.strip():
        flags.append("empty")
        return flags

    if CORRECTION_IN_INPUT.search(source) and not PUBLIC_CORRECTION.search(source) \
            and CORRECTION_RESIDUE.search(output):
        flags.append("correction_residue")

    residue = sorted({m.group(0) for m in EDITOR_INSTRUCTION.finditer(output)
                      if m.group(0) in source})
    if residue:
        flags.append("editor_instruction_residue:" + "|".join(residue))

    if (COUNT_CUE.search(source) or SEQUENCE_CUE.search(source)) \
            and len(LIST_LINE.findall(output)) < 2:
        flags.append("enumeration_not_listed")

    if not CORRECTION_IN_INPUT.search(source):
        missing_time = sorted(set(TIME_WORDS.findall(source)) - set(TIME_WORDS.findall(output)))
        if missing_time:
            flags.append("time_word_missing:" + "|".join(missing_time))
        missing_numbers = sorted(numbers(source) - numbers(output))
        if missing_numbers:
            flags.append("number_missing:" + "|".join(missing_numbers))
    return flags


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="+")
    parser.add_argument("--ratings", help="独立评审 ratings.csv，用于核对标记与判读的一致性")
    parser.add_argument("--details", action="store_true")
    args = parser.parse_args()

    ratings = {}
    if args.ratings:
        with open(args.ratings, encoding="utf-8") as handle:
            ratings = {row["test_input_id"]: row["rating"] for row in csv.DictReader(handle)}

    for path in args.reports:
        report = json.load(open(path, encoding="utf-8"))
        cases = report["cases"]
        kinds = Counter()
        flagged = 0
        agreement = Counter()
        for case in cases:
            flags = check(case)
            if flags:
                flagged += 1
            kinds.update(f.split(":")[0] for f in flags)
            rating = ratings.get(case["test_input_id"])
            if rating:
                agreement[(bool(flags), rating != "direct_send")] += 1
            if args.details and flags:
                print(f"  {case['test_input_id']}: {'; '.join(flags)}"
                      + (f"  [评审:{rating}]" if rating else ""))
        latencies = sorted(c["latency_milliseconds"] for c in cases)
        print(f"{path}")
        print(f"  模型 {report.get('model')}  条数 {len(cases)}  无标记 {len(cases) - flagged}"
              f"（{(len(cases) - flagged) / len(cases):.1%}）")
        print("  标记分布 " + "  ".join(f"{k}={v}" for k, v in kinds.most_common()))
        print(f"  延迟 P50 {latencies[len(latencies) // 2]}ms  P95 {latencies[int(len(latencies) * 0.95)]}ms")
        if agreement:
            print("  与评审对照（有标记, 评审非直发）: "
                  + "  ".join(f"{k}={v}" for k, v in sorted(agreement.items())))


if __name__ == "__main__":
    sys.exit(main())
