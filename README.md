<p align="center">
  <img src="docs/images/header-combined.svg" width="100%" alt="Muse - macOS 语音输入法" />
</p>


- **语音识别**：内置本地识别引擎、媲美云端引擎准确率；云端引擎采用火山引擎（豆包同款）；支持流式识别、边说边出字，说完无需等待、快速输入；
- **文本处理**：内置润色、Prompt优化、翻译功能，可自定义添加任意处理模版（比如改人设、改语气、小语种翻译等等）；
- **模型接入**：支持主流厂商API接入；文本处理支持使用Ollama接本地模型；
- **词汇管理**：支持热词、映射词，2种模式。热词用于校正语音识别引擎，映射词可作为兜底或个性化场景使用（如 Web coding -> Vibe Coding, "我的邮箱地址" -> xxx@gmail.com）；
- **历史记录**：存储所有历史识别记录，包括原始文本和处理后文本；
- **语料资产**：可从历史记录手动提炼核心观点、金句表达、高频术语、可复用片段，并支持复制、收藏、删除与回流到现有工作流；
- **词库管理Skill**：配合你的 AI 编码代理自动管理热词和映射词（新版 Skill 随新仓库发布）

## 立即体验

**方式一：直接下载DMG**

> 本项目正以新名称 **Muse** 独立发布，安装包将在 [github.com/DaliangPro/Muse](https://github.com/DaliangPro/Muse) 的 Releases 提供（筹备中）。当前请用方式二从源码构建。

系统要求：macOS 14+ (Sonoma)

**DMG提示无法打开、损坏、APP安装后打不开？**

> 解决方案：  
>
> - Step 1：打开「终端」，运行下列命令
>
>   xattr -d com.apple.quarantine /Applications/Muse.app
>
>   ```bash
>   spctl --master-disable
>   ```
>
> - Step 2：打开「系统设置」，进入「隐私与安全性 - 允许以下来源的应用程序」，选择「任何来源」
>
> - Step 3：打开DMG安装包，将Muse拖入Application文件夹后打开。
>
> - Step 4（可选）：回到系统设置，把刚刚的「允许以下来源的应用程序」从任何来源改回去。

> 因为目前还没有申请好Apple的开发者认证（努力申请中），这是正常提示，可通过配置解决。

**方式二：复制本项目的链接丢给你的 Agent帮你部署**

## 界面预览

<p align="center"><sub>· 新版 Muse 界面截图更新中 ·</sub></p>


[查看演示视频](#演示视频)


## 为什么做Muse

市面上语音输入法，至少命中以下问题之一：贵（$30/月）、封闭（不可导出记录）、扩展性差（不能自定义Prompt）、慢（强制优化及网络延迟）  

作为某最贵识别工具曾经的粉丝，心路历程就是：**「它怎么可以这么好用，但又这么难用」**
以及也不必所有的话都说的这么工工整整规规矩矩。
## 使用Tips

- 语音识别：
  - 推荐使用云端模型，成本极低（我高强度用说了5w字=5小时，对应5块人民币，豆包语音注册送40小时，[配置指引](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr)）
  - 尽管本地模型效果还不错，但十分占用内存，内嵌Sense Voice用于流式识别（2GB内存占用）、Qwen3 ASR做校准（8GB内存占用），你也可以单独开其中一个，但体验不佳，Sense Voice中文不错、但英文单词十分拉垮。
- 文本处理（接入LLM）：
  - 依旧推荐使用云端模型，接入Coding Plan API，这类轻量文本处理Token消耗肉眼不可见；
  - LLM本地跑的内存占用比语音识别还高，而且效果相比云端模型相去甚远；
  - **不要**使用思考模式，推荐轻量模型。作者自己用的是Seed-2.0-lite。例如Minimax M2.7无法关闭思考，处理时间会非常长。对于我们这种轻量文本处理完全没有必要，牺牲体验也换不到效果。
    - 如果你发现你的处理时间很长，请把你使用的厂商和模型告诉我，我看看代码里是否成功关闭思考（目前没有遍历测试所有API）
- **强烈建议**搭配词库管理 Skill 使用：市面上所有的语音输入法，专有名词均无法做到很好的识别（例如：Qwen 3.5），搭配 Skill 使用 1-2 天可大幅提升专有名词准确率（新版 Skill 随新仓库发布）



## 详细功能介绍

### 语音识别（略）

### 文本处理：需配置API Key，效果受模型影响，可自行调整/添加Prompt

每个模式可以绑定独立的全局快捷键，支持「按住说话」和「按一下开始/再按停止」两种方式。

| 模式           | 说明                                                         |
| -------------- | ------------------------------------------------------------ |
| **快速模式**   | 实时识别出文字，识别完成即输入，零延迟                       |
| **语音润色**   | （简单说就是类似Typeless的体验吧- -）帮你优化表达、消除口头语、纠正等 |
| **英文翻译**   | 说中文，输出英文翻译                                         |
| **Prompt优化** | 说一句简单的原始prompt，帮你优化后直接粘贴                   |
| **自定义**     | 自己写 prompt，用 LLM 做任何后处理                           |

#### Prompt 变量高级玩法

Prompt 模板支持三种变量，让语音输入从"听写"升级为"语音命令"：

| 变量          | 含义                     |
| ------------- | ------------------------ |
| `{text}`      | 语音识别的文字           |
| `{selected}`  | 录音开始时光标选中的文字 |
| `{clipboard}` | 录音开始时剪切板的内容   |

**用法示例**：变量玩法演示图更新中。


### 词汇管理

- **ASR 热词**：添加专有名词（如 `Claude`、`Kubernetes`），提升识别准确率
- **片段替换**：语音说「我的邮箱」，自动替换为实际邮箱地址

### 语料资产

- 可手动选择范围，从历史识别记录中提炼 4 类资产：核心观点、金句表达、高频术语、可复用片段
- 每条资产支持复制、收藏、删除，并可查看来源记录
- 高频术语可一键加入热词；可复用片段可生成片段替换草稿；观点 / 金句可生成 Prompt 草稿
- 提炼属于手动任务，不影响实时语音输入主流程
- 若当前使用云端 LLM，执行提炼时会把所选历史文本发送给对应模型服务


## 架构概览

| 模块 | 说明 |
|------|------|
| `Muse/ASR/` | ASR 引擎抽象层，可插拔 Provider 架构 |
| `Muse/Audio/` | 音频采集 (16kHz mono PCM) |
| `Muse/Session/` | 核心状态机：录音 → ASR → 注入 |
| `Muse/Services/` | 凭证存储、热词、模型管理、Python 服务管理 |
| `Muse/LLM/` | LLM 文本处理 (13 个 provider) |
| `Muse/Input/` | 全局快捷键管理 |
| `Muse/Injection/` | 文本注入 (剪贴板 Cmd+V) |
| `Muse/Bridge/` | SherpaOnnx C API Swift 桥接 (可选) |
| `Muse/UI/` | SwiftUI 界面：浮窗 + 设置 |
| `sensevoice-server/` | Python SenseVoice 流式 ASR 服务 |
| `qwen3-asr-server/` | Python Qwen3-ASR 校准服务 (Apple Silicon, MLX) |

ASR Provider 架构设计为可插拔：实现 `ASRProviderConfig`（定义凭证字段）和 `SpeechRecognizer`（实现识别逻辑），注册到 `ASRProviderRegistry` 即可添加新引擎。


## 参与贡献

欢迎提交 PR/Issue，这个项目是我全部自己用 Claude Code 写的。

对于 PR，即便有 bug/代码质量不好，我最常跟 Claude 说的一句话就是不要漏了人家的贡献。你大不了合完再改。


## 致谢

- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) - Alibaba FunAudioLLM
- [streaming-sensevoice](https://github.com/pengzhendong/streaming-sensevoice) - @pengzhendong
- [asr-decoder](https://github.com/pengzhendong/asr-decoder) - @pengzhendong
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) - k2-fsa
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) - Alibaba Qwen
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) - @moona3k


## For AI Agents

If you're an AI agent (Claude Code, Cursor, Copilot, etc.) tasked with building, deploying, or contributing to Muse, here's everything you need.

### Read these files first

1. `CLAUDE.md` - full architecture guide, credential storage, key files, development patterns, and how to add new ASR/LLM providers
2. `Package.swift` - Swift Package Manager dependencies and build targets
3. `scripts/deploy.sh` - the build & deploy pipeline (calls `scripts/package-app.sh`)

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.12: `brew install python@3.12` (for local ASR servers)
- CMake: `brew install cmake` (only if building SherpaOnnx punctuation engine)

### Build & deploy

```bash
# 1. Clone
git clone https://github.com/DaliangPro/Muse.git && cd Muse

# 2. (Optional) Build SherpaOnnx punctuation engine (~5 min, needs cmake)
bash scripts/build-sherpa.sh

# 3. (Optional) Setup local ASR servers (needs python3.12)
cd sensevoice-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# 4. Deploy (builds, bundles .app, signs, installs to /Applications, launches)
bash scripts/deploy.sh

# Subsequent updates
git pull && bash scripts/deploy.sh
```

Steps 2-3 are optional. Skipping them disables local ASR, but cloud ASR works fine.

### Code signing & permissions

`deploy.sh` handles code signing automatically to **preserve macOS permissions across rebuilds**:

- **First deploy** auto-creates a self-signed certificate ("Muse Local", valid 10 years) if no signing identity exists. This may trigger a **Keychain password prompt** that requires human interaction.
- **Subsequent deploys** reuse the same certificate. Accessibility/Microphone permissions persist, no re-grant needed.
- After first launch, the user must grant **Accessibility permission** once (System Settings → Privacy & Security → Accessibility → enable Muse).
- To override signing identity: `CODESIGN_IDENTITY="Your Cert" bash scripts/deploy.sh`
- Fallback to ad-hoc signing: `CODESIGN_IDENTITY="-" bash scripts/deploy.sh` (Accessibility permission will reset each build)

### Key architecture points

- **Swift Package Manager** project, no `.xcodeproj` needed
- **Local ASR**: dual-engine design. SenseVoice (streaming partial results) + Qwen3-ASR (final calibration via MLX/Metal). Both run as Python WebSocket servers managed by `SenseVoiceServerManager`
- **Cloud ASR**: 7 providers implemented (Volcano, OpenAI, Deepgram, AssemblyAI, Soniox, Bailian, Baidu)
- **Credentials**: stored at `~/Library/Application Support/Muse/credentials.json` (mode 0600), never in code or environment variables. GUI apps cannot read shell env vars from `~/.zshrc`
- **ASR provider architecture**: plugin-based. To add a new provider: implement `ASRProviderConfig` + `SpeechRecognizer` protocol, register in `ASRProviderRegistry.all`. See `CLAUDE.md` for details
- **Audio format**: 16kHz mono PCM16-LE, 200ms chunks (6400 bytes)
- **Text injection**: clipboard-based Cmd+V paste with save/restore


## 演示视频

<video src="https://github.com/user-attachments/assets/d5ad6da9-b924-4fd6-9812-d0d9868563a4" width="600" title="demo" controls>demo</video>


## 许可证

[MIT License](LICENSE)
