# Voice Polish V2 评测指南

## 固定夹具

`VoicePolishFixtureCatalog` 包含 94 条合成夹具，覆盖简短聊天、工作沟通、邮件、即时/延迟改口、旁注、乱序、列表数量变化、专有名词、数字日期、中英技术内容、AI Prompt 和自媒体口播。默认 `swift test` 会检查数量分布、确定性路由和 canonical facts。

## Live Provider Benchmark

Live Benchmark 只在显式启用时调用当前已配置的 LLM Provider：

```bash
bash scripts/run-voice-polish-live-benchmark.sh
```

可用 `MUSE_VOICE_POLISH_LIVE_LIMIT` 控制 1～94 条样本，用 `MUSE_VOICE_POLISH_LIVE_REPORT` 指定报告路径。报告记录 Provider、模型、endpoint、Prompt 版本、路由、调用次数、延迟、事实通过、旧事实残留、回退率和长度比例。

截至 2026-07-31，本次工程实施未自动调用付费/远程 Live Provider，因此 Live 报告状态为“未执行”。

## 人工盲测

先准备至少 30 条包含 `id`、`input`、`legacy_output`、`new_output` 的 JSON。旧版基线固定为 `b81bce5`。

```bash
python3 scripts/voice-polish-blind-test.py prepare \
  --input samples.json \
  --output blind-evaluation.json \
  --key blind-key.json
```

评审者只拿 `blind-evaluation.json`，把每条 `rating` 填为 `left`、`right`、`tie` 或 `both_unusable`。密钥文件不交给评审者。完成后计分：

```bash
python3 scripts/voice-polish-blind-test.py score \
  --evaluation blind-evaluation.json \
  --key blind-key.json \
  --output blind-report.json
```

新版获胜或打平比例达到 85%，且样本不少于 30 条，`product_ready` 才为 `true`。截至 2026-07-31，没有真实人工评分，因此产品验收状态为“未执行/未完成”，不得据此发布 V2。
