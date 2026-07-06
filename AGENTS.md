# Muse — Agent 入口指南

> 本文件面向所有 AI 编码代理（Codex / Cursor / Gemini CLI / Copilot / Claude Code 及其他）。

## 修复任务必读（最高优先）

本项目的修复/重构工作以根目录 **[REPAIR_PLAN.md](REPAIR_PLAN.md)** 为唯一指导与进度台账：

1. 动手前先读其「使用规则」一节
2. 认领任务：状态 ⬜ → 🟡
3. 按任务卡的「修复方案」执行，满足「验收标准」并通过构建后才算完成
4. 销账：状态 → ✅，补 commit 哈希，并在文末「更新日志」追加一行

## 项目速览

macOS 菜单栏语音输入工具。Swift Package Manager 工程（无 .xcodeproj），SwiftUI 界面；
本地 ASR 为两个 Python WebSocket 服务（sensevoice-server / qwen3-asr-server，仅绑 127.0.0.1）；
多家云端 ASR + LLM 后处理。架构细节见 [CLAUDE.md](CLAUDE.md)。

## 常用命令

```bash
swift build                 # 构建（debug）
swift test                  # 运行测试（MuseTests/，217 个用例）
swift build -c release      # 发布构建
bash scripts/package-app.sh # 打包 .app
```

## 硬性约束

- 全部交流、注释、commit message 用中文；commit 格式 `<类型>: <简短描述>`（新增/更新/修复/优化/重构/文档/配置/删除），原子提交
- 未通过构建与相关测试，不得声称任务完成
- 不得触碰用户数据目录 `~/Library/Application Support/Muse/`（除非任务卡明确要求）
- 删除仓库文件用 `git rm`；删除非托管文件移入 `~/.Trash/`，禁止 `rm` 永久删除
