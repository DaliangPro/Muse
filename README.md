<p align="center">
  <img src="Muse/Resources/BrandLogo.png" width="260" alt="Muse">
</p>

<h3 align="center">macOS 原生语音输入与灵感资产工作台</h3>

<p align="center">
  按一次 Option 开始说话，再按一次结束。文字直接落到当前光标，说过的内容继续沉淀为可复用语料。
</p>

<p align="center">
  <img src="docs/images/muse-models.jpg" width="860" alt="Muse 模型配置界面">
</p>

## 核心能力

- **语音输入**：全局快捷键触发，识别结果自动注入当前输入框。
- **多种识别引擎**：Apple 本机识别、火山引擎云端识别，以及 SenseVoice + Qwen3-ASR 本地离线识别。
- **AI 文本处理**：支持直出、润色、Prompt 优化、翻译和自定义处理模式。
- **常用词管理**：热词用于提升识别准确率，映射词用于把口语指令替换为固定内容。
- **历史与语料资产**：保留原始文本和处理结果，并从历史记录中提炼金句、观点、术语和可复用片段。
- **本地模型管理**：在应用内查看 SenseVoice、Qwen3-ASR、本地 LLM 和智能标点组件的状态。

## 产品界面

<p align="center">
  <img src="docs/images/muse-modes.jpg" width="49%" alt="Muse 输入模式">
  <img src="docs/images/muse-about.jpg" width="49%" alt="Muse 关于页面">
</p>

## 使用方式

1. 首次启动时授予麦克风和辅助功能权限。
2. 在「模型配置」中选择语音识别与文本处理服务。
3. 按一次 **Option** 开始说话，再按一次结束。
4. Muse 完成识别和处理后，将文字直接写入当前光标位置。

快捷键、触发方式和文本处理模式均可在设置中调整。

## 引擎选择

| 方案 | 联网 | 适用场景 | 额外配置 |
|---|---|---|---|
| Apple 本机识别 | 否 | 零配置快速开始 | 无 |
| 火山引擎 | 是 | 云端高精度流式识别 | API 凭据 |
| SenseVoice + Qwen3-ASR | 否 | Apple Silicon 本地离线识别 | 下载本地模型 |

文本处理支持云端 LLM、Ollama 和 Muse 本地模型，可按不同输入模式分别配置。

## 系统要求

- macOS 14 Sonoma 或更高版本
- 麦克风权限
- 辅助功能权限，用于全局快捷键和文字注入
- 本地 Qwen3-ASR 与本地 LLM 需要 Apple Silicon

## 从源码构建

项目使用 Swift Package Manager，不包含 `.xcodeproj`。

```bash
swift build
swift test
swift build -c release
```

打包和本机运行：

```bash
bash scripts/package-app.sh
bash scripts/build_and_run.sh --verify
```

本地识别服务位于 `sensevoice-server/` 和 `qwen3-asr-server/`，相关构建脚本位于 `scripts/`。

## 项目结构

| 路径 | 内容 |
|---|---|
| `Muse/` | macOS 应用、识别、文本处理、数据和界面代码 |
| `MuseTests/` | 单元测试与集成测试 |
| `sensevoice-server/` | SenseVoice 本地流式识别服务 |
| `qwen3-asr-server/` | Qwen3-ASR 本地终校服务 |
| `scripts/` | 构建、打包、部署和健康检查脚本 |

## 版权

Copyright (c) 2026 DaliangPro. All rights reserved.

本项目为专有软件。未经 DaliangPro 事先书面许可，不得使用、复制、修改、分发、
再许可或销售本项目及其源码。详见 [LICENSE](LICENSE)。
