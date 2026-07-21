# Muse 修复执行日志

## 执行基线

- 执行日期：2026-07-20（PDT）
- 审查基线：`7144781af818fd188eff0e67215b63deddcce660`
- 工作分支：`codex/muse-hardening-v1`
- 开始前工作区：仅有用户既有未跟踪文件 `CODEX_REPAIR_PLAN.md`；执行过程中不覆盖、不修改、不纳入提交。
- 真实用户数据目录：未触碰 `~/Library/Application Support/Muse/`。
- 自动更新开关：`UpdateChecker.updateChannelEnabled = false`，保持关闭。

### 基线验证

| 命令 | 结果 |
|---|---|
| `swift build` | 通过；首次沙箱内尝试因 Swift/Clang 用户缓存无写权限失败，获准在真实环境重跑后通过。 |
| `swift test` | 通过；260 项测试，5 项按环境条件跳过，0 失败。 |
| `swift build -c release` | 通过。 |
| `bash scripts/health-check.sh` | `HEALTH_CHECK_RESULT: PASS`；debug/release 构建、全量测试、Shell 语法和两个 Python 服务语法均通过。 |

基线环境限制：`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按设计标记为 `SKIP`；未安装任何工具，也未降低核心测试标准。

## 批次 A

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| MUSE-010 | ✅ 完成 | `7ea2cb5` | 硬超时工具与三处调用统一完成。 |
| MUSE-020 | ✅ 完成 | `b2d5cd0` | 会话资源所有权与 7 条竞态回归测试完成。 |
| MUSE-030 | ✅ 完成 | `f396df3` | 火山连接生命周期与会话事件流已分离。 |
| MUSE-040 | ✅ 完成 | `05227b5` | Apple Speech 会话令牌与可靠截止时间已完成。 |
| MUSE-050 | ⚠️ 自动验收完成，人工项部分跳过 | `43c58b1` | AirPods、内置麦克风通过；USB 双声道声卡与聚合设备由用户明确跳过。 |
| MUSE-060 | ✅ 完成 | `0239544` | 本地双引擎会话流、终态和迟到终校隔离完成。 |

### MUSE-010：建立真正的硬超时工具

- 状态：✅ 完成。
- 提交：`7ea2cb5`（`修复: 建立不依赖子任务取消协作的硬超时工具`）。
- 测试优先：先新增 6 条 throwing timeout 回归测试；修复前执行 `swift test --filter AsyncTimeoutTests` 明确失败，原因为 `AsyncTimeout` 尚无 `throwingValue`。
- 修改：新增一次性完成闸门；operation、计时器和外部取消只允许一个终态；计时器胜出后立即恢复调用方并取消 detached operation，不等待底层任务退出。提炼请求、Apple Speech `endAudio`、RecognitionSession 批量兜底统一使用该工具。
- 验证：
  - `swift test --filter AsyncTimeoutTests`：10 项，0 失败。
  - `swift test --filter 'AssetExtractionRetryTests|RecognitionSessionTests'`：23 项，0 失败。
  - `swift test`：266 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：Apple Speech 的完整会话令牌、迟到回调隔离和可注入 timeout 属 MUSE-040；本任务只替换其阻塞式 Task Group 超时。自动更新开关仍为 `false`。

### MUSE-020：修复 RecognitionSession 跨会话资源竞态

- 状态：✅ 完成。
- 提交：`b2d5cd0`（`修复: 将录音资源绑定会话身份并阻断迟到任务`）。
- 测试优先：先新增 `RecognitionSessionRaceTests` 的 7 条竞态用例；修复前执行 `swift test --filter RecognitionSessionRaceTests` 明确编译失败，原因为缺少会话 ID、依赖注入接口及测试读取 API，证明新测试未被既有实现满足。
- 修改：
  - 将 `SpeechRecognizer` 限定为引用类型，以对象身份校验 ASR client 所有权。
  - 为 ASR client、事件消费任务、音频上传管线、音频采集、录音开始时间、当前配置和 speculative LLM 任务显式绑定 `RecognitionSessionID`。
  - 连接失败、事件晚到、事件任务退出和 stop 收尾均先核对会话 ID；清理 client 时同时核对局部对象身份。
  - `forceReset` 改为同步摘除共享引用：先使旧 ID 失效，再取消局部旧任务，并仅用 detached 任务断开旧 client；清理期间无 actor suspension。
  - 增加最小 ASR factory、音频采集和文本注入依赖接口；全部会话测试改用内存历史库，未访问真实用户数据。
- 验证：
  - `swift test --filter RecognitionSessionRaceTests`：7 项，0 失败。
  - `swift test --filter RecognitionSessionTests`：19 项，0 失败。
  - `swift test --filter 'RecognitionSession(Race)?Tests'`：26 项，0 失败。
  - `swift test`：273 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：本任务以可控 fake 验证跨会话所有权和迟到回调隔离，未执行真实云端 ASR 或麦克风人工录音；各 ASR client 自身的事件流生命周期分别由 MUSE-030、MUSE-040、MUSE-060 继续加固。自动更新开关仍为 `false`。

### MUSE-030：修复火山 ASR 重连后事件流永久关闭

- 状态：✅ 完成。
- 提交：`f396df3`（`修复: 分离火山连接生命周期与识别事件流生命周期`）。
- 测试优先：先新增 `VolcASRReconnectTests` 的 6 条生命周期用例；修复前执行 `swift test --filter VolcASRReconnectTests` 明确编译失败，缺少可注入拨号资源、连接退出诊断和 terminal helper 测试入口，证明现实现不具备所需连接身份与终态边界。
- 修改：
  - 每次拨号生成独立 `connectionID`，receive loop 固定捕获本地 WebSocket task 与该 ID，不再逐轮读取共享 task。
  - 重连和断开均先使旧 ID 失效、摘除共享引用，再取消局部旧 task 与 URLSession；旧 loop 的消息、错误和退出无法触碰新连接。
  - transient receive error 只发送 `.streamingInterrupted`，保留会话级事件流，后续 send 失败仍可触发一次重连。
  - 事件流只在 `disconnect`、`emitCompletedOnce`、`emitTerminalError` 三条路径结束；terminal helper 统一去重、发送终态、结束流并清理 continuation。
  - 增加可控 WebSocket 拨号抽象，覆盖旧 loop 先结束、旧 loop 晚到退出、terminal 去重、disconnect 收流及重连文本前缀拼接。
- 验证：
  - `swift test --filter VolcASRReconnectTests`：6 项，0 失败。
  - `swift test --filter VolcProtocolTests`：19 项，0 失败。
  - `swift test`：279 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：测试使用可控 WebSocket fake，未连接真实火山服务执行断网/重连人工验收；服务端关闭帧的具体时序仍需日常网络波动场景观察。自动更新开关仍为 `false`。

### MUSE-040：修复 Apple Speech 超时和迟到回调污染

- 状态：✅ 完成。
- 提交：`05227b5`（`修复: 为 Apple Speech 增加会话令牌和可靠截止时间`）。
- 测试优先：先新增 `AppleASRClientLifecycleTests` 的 6 条生命周期用例；修复前执行 `swift test --filter AppleASRClientLifecycleTests` 明确编译失败，缺少识别会话抽象、回调封装、可注入截止时间与 waiter 诊断入口，证明旧实现不具备所需会话隔离边界。
- 修改：
  - 每次 `connect` 生成唯一 `sessionID`，Apple callback 固定捕获该 ID；处理回调和结束事件流前均先核对当前会话。
  - `disconnect` 与重连先同步使会话失效、摘除 continuation 和识别引用，再取消局部旧 Apple task；迟到 transcript/error 无法结束新流。
  - `endAudio` 使用可注入 duration 的 `AsyncTimeout.throwingValue`；截止时间到期后取消对应识别任务、将最新 partial 发送为 fallback final、恢复 waiter 并立即返回。
  - 将单一 finish waiter 与 `sessionID` 绑定，对重复 waiter 增加明确断言与日志；`completed` 与 continuation 恢复均做单次终态保护。
  - 增加最小 Apple recognition session 注入边界，生产实现仍将 Speech framework 请求、追加音频和取消限定在 MainActor。
- 验证：
  - `swift test --filter AppleASRClientLifecycleTests`：6 项，0 失败。
  - `swift test`：285 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：回归测试使用可控 Apple recognition fake，未在真实麦克风与 Apple Speech 服务上人工验收授权、系统服务不可用及真实 5 秒超时时序。自动更新开关仍为 `false`。

### MUSE-050：修复 CMSampleBuffer 多声道内存越界风险

- 状态：⚠️ 实现与自动验收完成；AirPods 与内置麦克风人工录音通过，USB 双声道声卡与聚合设备由用户明确跳过。
- 提交：`43c58b1`（`修复: 按 AudioBufferList 安全转换采集音频`）。
- 测试优先：先新增 `AudioCaptureBufferConversionTests` 的 9 条用例；修复前执行 `swift test --filter AudioCaptureBufferConversionTests` 明确编译失败，原因是生产端只有 `Data` 重载，且没有安全的 CMSampleBuffer 转换与可测重采样入口。
- 修改：
  - 删除将整个 `CMBlockBuffer` 复制到第 0 声道的逻辑，改用 `CMSampleBufferCopyPCMDataIntoAudioBufferList`。
  - 按交错/非交错格式核对目标 buffer 数量，逐 buffer 检查 `mData`、`mDataByteSize` 与每帧字节数；检查 data-ready 状态和 CoreMedia copy OSStatus，失败时记录帧数、采样率、声道数、每帧字节与 flags 后丢弃。
  - 覆盖 mono/stereo、Int16/Float32、interleaved/non-interleaved 五种布局，并保持 ASR 输出为 16 kHz、mono、Int16、interleaved。
  - 重采样 frame capacity 改为 `ceil(sourceFrames * 16000 / sourceRate) + 1`，对 44.1/48 kHz 与奇数帧留出安全余量。
- 验证：
  - `swift test --filter AudioCaptureBufferConversionTests`：9 项，0 失败。
  - `swift test --filter AudioCaptureEngineTests`：10 项，0 失败。
  - `swift test --sanitize address --filter AudioCaptureBufferConversionTests`：9 项，0 失败，未报告内存越界。
  - `swift test`：294 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- AirPods 人工验收（2026-07-20 PDT）：
  - 当前默认输入为“听”，Bluetooth、1 声道、24 kHz、Float32；无需切换系统输入。
  - 经用户明确授权后，使用直接编译生产 `AudioCaptureEngine` 的临时程序执行 5 秒内存采集；音频未保存、未上传，也未访问用户数据目录。
  - 成功产生 22 个音频块、136,298 字节；最大绝对采样值 13,544，最大归一化电平 0.6825921；0 个 `CMSampleBuffer` 转换失败或被丢弃。
  - 转换结果保持 16 kHz、mono、Int16、interleaved，验收程序返回 `ACCEPTANCE_RESULT=PASS`。
  - 验收后 `swift test --filter 'AudioCaptureBufferConversionTests|AudioCaptureEngineTests'`：19 项，0 失败；`swift test`：299 项，5 项按环境条件跳过，0 失败。
- 内置麦克风人工验收（2026-07-20 PDT）：
  - 经用户明确授权，将默认输入从 AirPods“听”（CoreAudio ID 267）临时切换至“MacBook Pro麦克风”（ID 104）；测试结束后立即恢复 ID 267，并再次读取确认恢复成功。
  - 使用同一临时程序执行 5 秒内存采集；输入为 44.1 kHz、1 声道，音频未保存、未上传，也未访问用户数据目录。
  - 成功产生 25 个音频块、155,486 字节；最大绝对采样值 1,903，最大归一化电平 0.31228927；0 个 `CMSampleBuffer` 转换失败或被丢弃。
  - 转换结果保持 16 kHz、mono、Int16、interleaved，验收程序返回 `ACCEPTANCE_RESULT=PASS`。
  - 验收后 `swift test --filter 'AudioCaptureBufferConversionTests|AudioCaptureEngineTests'`：19 项，0 失败；`swift test`：299 项，5 项按环境条件跳过，0 失败。
- USB 双声道声卡人工验收：用户于 2026-07-20 明确指示跳过；未切换至 USB 输入、未录音，不计为通过。跳过后复核发现 AirPods 已离线，系统默认输入自行回落至内置麦克风，并非本次操作切换。
- 聚合音频设备人工验收：用户于 2026-07-20 明确指示停止并跳过剩余音频测试；未创建聚合设备、未切换输入、未录音，不计为通过。
- 硬件盘点：当前可见 AirPods“听”（1 声道/24 kHz）、MacBook Pro 内置麦克风（1 声道/44.1 kHz）、Maono USB 双声道输入（48 kHz）、Maono AI USB 双声道输入（48 kHz）及多个虚拟多声道设备；未确认聚合音频设备。
- 遗留风险：AirPods 与内置麦克风已通过；USB 双声道声卡和聚合音频设备均被明确跳过且未通过，MUSE-050 不具备完整四设备人工验收结论。自动更新开关仍为 `false`。

### MUSE-060：修复 SenseVoiceWSClient 中断后终校事件丢失

- 状态：✅ 完成。
- 提交：`0239544`（`修复: 保持本地双引擎会话流直至终校完成`）。
- 测试优先：先新增 `SenseVoiceWSLifecycleTests` 的 5 条生命周期用例；修复前执行 `swift test --filter SenseVoiceWSLifecycleTests` 明确编译失败，缺少可注入 WebSocket/Qwen 边界、连接身份与迟到循环诊断入口，证明旧实现不具备所需的会话/连接所有权。
- 修改：
  - 每次识别会话生成 `sessionID`，每次 SenseVoice 连接生成 `connectionID`；receive loop 固定捕获局部 socket 与双 ID，旧 loop 的消息、错误和退出均无法触及新会话。
  - 删除 receive loop 退出时无条件 `finish()` 会话流的逻辑；传输中断只发送 `.streamingInterrupted`，Qwen final 继续在同一事件流中发送 final transcript 和 completed。
  - completed/error helper 统一执行会话校验、单次终态、发送事件、finish 流和清理 continuation。
  - `disconnect` 先使 session/connection ID 失效、摘除共享引用，再取消旧 receive、WebSocket、URLSession 和 Qwen debounce 资源。
  - Qwen 投机与 final 的快照、HTTP 返回、确认 offset 和 `resetQwen3State` 均核对原会话；旧 `endAudio` 返回后不能发布迟到文本，也不能清空新会话已累积音频。
  - 将本地服务解析、WebSocket 拨号和 Qwen transcriber 提炼为最小可注入边界，生产默认行为仍使用现有 server manager 和 localhost HTTP/WebSocket。
- 验证：
  - `swift test --filter SenseVoiceWSLifecycleTests`：5 项，0 失败。
  - `swift test --filter 'AudioChunkUploadPipelineTests|RecognitionSessionTests'`：21 项，0 失败。
  - `swift test`：299 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `swift build -c release`：通过。
  - `git diff --check`：通过。
- 遗留风险：生命周期测试使用可控 WebSocket 与 Qwen transcriber fake，未启动真实 SenseVoice/Qwen Python 服务执行断连后终校人工验收；将在批次 A 汇报中明确列为待办。自动更新开关仍为 `false`。

## 批次 A 收口

- 代码任务：MUSE-010 至 MUSE-060 已按依赖顺序实施，每项均先红灯、再修复、跑定向与全量测试、最后独立提交。
- 当前代码 HEAD：`023954481fb45ec0898811b3c94caf19d00ce1e5`。
- 自动更新：`UpdateChecker.updateChannelEnabled = false`，未改动。
- 真实用户数据：未访问、未修改 `~/Library/Application Support/Muse/`。
- 收口自动验收：`bash scripts/health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建通过，全量 `swift test` 执行 299 项、5 项按环境条件跳过、0 失败，Shell 语法与两个 Python 服务语法检查通过。
- 收口环境限制：`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按设计标记为 `SKIP`；未安装工具，也未降低构建或测试门槛。
- 音频人工验收豁免：用户于 2026-07-20 明确要求停止并跳过剩余音频测试；USB 双声道声卡与聚合设备未通过，批次 A 仅按显式豁免继续推进，不代表原四设备门槛全部满足。
- 待人工项：MUSE-030 真实火山断网/重连；MUSE-040 真实 Apple Speech 超时；MUSE-060 真实 SenseVoice 中断后 Qwen 终校。

## 批次 B

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| MUSE-070 | ✅ 完成 | `b387d76` | 本地服务进程级 token 鉴权与 HTTP、LLM、WebSocket 输入边界完成。 |

### MUSE-070：给本地 ASR 和 LLM 服务增加鉴权与输入上限

- 状态：✅ 完成。
- 提交：`b387d76`（`修复: 为本地推理服务增加会话鉴权和请求边界`）。
- 测试优先：
  - 先新增 `LocalServiceAuthTests`；修复前运行 `swift test --filter LocalServiceAuthTests` 明确失败，编译器报告找不到 `LocalServiceAuth`。
  - 先新增 Python 共用安全合同与真实路由接线测试；修复前运行 `python3 -m unittest discover -s local-service-shared -p 'test_*.py'` 明确失败，报告缺少 `local_service_security` 模块。
- 修改：
  - Swift 使用 `SecRandomCopyBytes` 每进程生成 32 字节随机 token，编码为 base64url；token 仅保存在内存，经 `MUSE_LOCAL_AUTH_TOKEN` 传入 SenseVoice、Qwen 子进程，不持久化、不写日志。
  - 为 `/ws`、两处 `/health`、`/transcribe`、`/llm/load`、`/llm/unload` 和 localQwen 的 `/v1/chat/completions` 补 `X-Muse-Local-Token`；Ollama 与云端请求不携带该 Header。
  - 两套 Python 服务使用 `hmac.compare_digest` 校验 HTTP/WS token；WS 在 `accept` 前鉴权，继续执行原 Host/Origin 防护和单活动连接约束；主入口缺 token 时在模型加载前退出。
  - 共用校验模块限制 HTTP PCM 为 octet-stream、偶数字节、最大 60 MB；LLM JSON 最大 2 MB，并统一校验 messages、总 content、temperature、max_tokens；WS 单帧最大 1 MB、累计音频最大 30 分钟，Qwen 越界帧仅追加剩余容量。
  - 两份 PyInstaller 脚本加入共享模块搜索路径；健康检查新增 Python 语法与 12 项 unittest 的强制步骤。
- 验证：
  - `swift test --filter 'LocalServiceAuthTests|SenseVoiceWSLifecycleTests|DoubaoChatClientTests'`：11 项，0 失败。
  - `python3 -m unittest discover -s local-service-shared -p 'test_*.py'`：12 项，0 失败。
  - `swift test`：304 项，5 项按环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、全量 Swift 测试、Shell/Python 语法和 Python 服务测试全部通过。
  - `git diff --check`：通过。
- 遗留风险：测试通过 FastAPI TestClient、stub 模型和可控 WebSocket 验证，不加载真实 ASR/LLM 模型；当前环境未安装 PyInstaller，未执行冻结制品导入冒烟。启动 gate 以当前打包入口 `main()` 为边界，未来若改用 `uvicorn module:app` 需同步迁移到 lifespan/startup gate。`shellcheck`、`swiftlint`、`periphery` 未安装，按健康检查既有规则标记为跳过。未执行任何麦克风或音频设备测试。自动更新开关仍为 `false`。
