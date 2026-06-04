# NimCode 迁移计划与进度

## 项目概述
将 vibecoding (Go) 完整功能移植到 nimcode (Nim)，实现完全的功能对等。

## 约束条件
- 语言: Nim，纯标准库，无外部依赖
- 配置路径: `~/.nimcode/` (非 `~/.config/nimcode/`)
- 编译: 始终使用 `-d:ssl`
- 遵循 AGENTS.md 约定

---

## 已完成功能

### Phase 1: 核心功能 (v0.1.1)
- [x] 配置路径迁移到 `~/.nimcode/`
- [x] `loadSettings()` 解析 providers, approval, retry
- [x] Provider 路由支持所有 API 类型
- [x] Help 文本不再硬编码 provider 名称
- [x] JSON 崩溃修复: guard `chunk["choices"]` 和 `delta["tool_calls"]`
- [x] Edit 工具: `edits[]` 数组 + diff 输出
- [x] Write 工具: diff 输出
- [x] Read 工具: 图片支持 (jpg/png/gif/webp base64)
- [x] Grep 工具: `include` 和 `maxResults` 参数
- [x] Find 工具: `maxResults` 参数
- [x] Bash 工具: `timeout` (max 600s) 和 `async` 后台执行
- [x] Skill_ref 工具: 按需加载 skill 参考文件
- [x] 重试机制: 429/5xx/网络错误指数退避
- [x] Thinking level: `-t` 标志 + `defaultThinkingLevel` 配置
- [x] Session resume: `-r` 标志按 ID/path
- [x] `--verbose` 和 `--debug` 标志
- [x] `confirmBeforeWrite` approval 设置
- [x] Retry 设置 (enabled, maxRetries, baseDelayMs)
- [x] Context compaction: 自动摘要旧消息
- [x] Session 文件带 ID, `sessions` 和 `usage` 交互命令
- [x] **True SSE streaming**: `chatStream()` 回调, token-by-token CLI 显示
- [x] Makefile: `build`/`release`/`clean` 目标
- [x] `.gitignore`
- [x] 版本升级到 v0.1.1

### Phase 2: Provider 增强
- [x] **Provider 类型系统** (`provider/types.nim`)
  - ThinkingLevel 枚举 (off/minimal/low/medium/high/xhigh)
  - ImageData 图片支持
  - CacheControl 缓存控制
  - ContentBlock 增加 cbtImage 和 cbtThinking
  - ToolDefinition 支持 tdkHosted 类型 (web_search)
  - StreamEvent 增加 setThinkDelta 和 setRetry
  - ChatParams 增加 thinkingLevel, temperature, topP
  - newHostedTool, newFunctionTool, parseThinkingLevel, hostedWebSearchToolType

- [x] **OpenAI Responses API** (`provider/openai.nim`)
  - 完整 `/responses` 端点 SSE 流式解析
  - 支持 reasoning 模型 (o1, o3, o3-mini)
  - `useResponsesApi` 标志切换 API
  - `thinkingFormat` 自动检测 (openai/deepseek/xiaomi)
  - `reasoning_content` 字段支持
  - 图片内容块支持

- [x] **Anthropic Provider 升级** (`provider/anthropic.nim`)
  - 真正的 SSE 流式: `chatStream` 方法
  - 重试机制: 指数退避
  - Extended Thinking 支持: thinking_delta/signature_delta
  - Cache Control 支持
  - Hosted Tools: web_search_20250305

- [x] **Google Gemini Provider 升级** (`provider/google.nim`)
  - 真正的 SSE 流式: `alt=sse` 参数
  - 重试机制
  - Thinking Budget: thinkingConfig 支持
  - 图片内联数据支持

- [x] **Provider Factory** (`provider/factory.nim`)
  - `detectApiType` 自动识别 API 类型
  - `createProvider` 统一创建入口
  - `createProviderFromSettings` 从 Settings 创建

- [x] **Agent 升级** (`agent/agent.nim`)
  - `thinkingLevel` 字段传递到 ChatParams
  - `aekThinkDelta` 事件转发
  - `setRetry` 事件显示重试信息

### Phase 3: 配置与工具扩展
- [x] **配置系统增强** (`config/config.nim`)
  - WebSearchSettings: enabled, provider, providerType
  - CompactionSettings: enabled, reserveTokens, keepRecentTokens
  - SandboxSettings: enabled, level, bwrapPath, allowNetwork
  - ContextFilesSettings: enabled, extraFiles
  - ProviderConfig 新增: vendor, thinkingFormat, cacheControl, httpProxy
  - MCPServerConfig, MCPConfig, loadMCPConfig()
  - 新路径: globalMCPPath(), projectMCPPath(), sessionDir, skillsDir

- [x] **MCP 客户端** (`mcp/mcp.nim`)
  - stdio 传输: 子进程 stdin/stdout 通信
  - JSON-RPC 2.0 协议
  - 同步调用带超时
  - 工具列表: listTools()
  - 工具调用: callTool()
  - CLI 集成: 自动加载 mcp.json

- [x] **Cron 调度器** (`cron/cron.nim`)
  - 任务管理: 创建、列表、启用/禁用、删除
  - JSON 文件持久化
  - 调度格式: @daily, @weekly, @hourly, @every 30m
  - 一次性任务: oneShot=true
  - 集成到 ToolRegistry

- [x] **Sandbox 模块** (`sandbox/sandbox.nim`)
  - Bubblewrap 集成
  - 三级安全: strict/standard/none
  - 命名空间隔离
  - 路径绑定

- [x] **Web-Search 工具**
  - 配置: webSearch.enabled, webSearch.providerType
  - Hosted Tool 注册

### Phase 4: 高级功能
- [x] **Provider Factory 改进**
  - thinkingFormat, cacheControl, httpProxy 传透
  - Google Vertex 自动识别

- [x] **MCP CLI 集成**
  - 自动加载 ~/.nimcode/mcp.json 和 .nimcode/mcp.json
  - MCP 工具注册为 mcp_{server}_{tool}
  - 工具执行路由到 MCP 客户端

- [x] **系统提示增强** (`agent/system_prompt.nim`)
  - Web-Search 指南
  - Cron 指南
  - MCP 指南
  - 动态工具检测

- [x] **多 Agent 工具** (`tools/tools.nim`)
  - `spawn` 工具: 生成子 agent
  - 参数: prompt, mode, working_directory
  - 通过 nimcode CLI 执行

### Phase 5: 协议与守护进程
- [x] **A2A 模块** (`a2a/a2a.nim`)
  - Google A2A 规范 v0.1
  - 任务类型: Task, TaskState, Message, Artifact
  - Agent Card: /.well-known/agent.json
  - HTTP 服务器: tasks/send
  - 客户端: sendTask()

- [x] **ACP 模块** (`acp/acp.nim`)
  - Agent Client Protocol v1
  - stdin/stdout 通信
  - 工具调用: tools/call
  - 初始化握手

- [x] **Hermes 守护进程** (`hermes/hermes.nim`)
  - HTTP 服务器
  - 健康检查: GET /health
  - Webhook 接收: POST /webhook
  - 聊天接口: POST /chat

### Phase 6: 集成与交互
- [x] **Sandbox 集成到 Bash 工具**
  - Bwrap 包装: sandbox 启用时自动使用
  - ToolRegistry 扩展: sandbox, sandboxLevel 字段
  - 安全执行

- [x] **新的交互命令**
  - `mcp`: MCP 服务器状态
  - `sandbox`: Sandbox 配置和可用性
  - `cron`: Cron 任务列表
  - `tools`: 可用工具列表

---

## 待完成功能

### Phase 7: 测试与文档
- [ ] 单元测试覆盖
- [ ] 集成测试
- [ ] API 文档
- [ ] 用户手册

### Phase 8: 高级特性
- [ ] Hermes WebSocket 支持
- [ ] A2A 完整实现 (streaming, push notifications)
- [ ] ACP 完整实现 (资源读取, 提示模板)
- [ ] Messaging 平台集成 (WeChat, Feishu)
- [ ] TUI 界面 (bubbletea 等效)
- [ ] Provider 代理 HTTP 支持
- [ ] Cron 调度器后台线程
- [ ] A2A 服务器 CLI 集成 (--a2a 标志)

### Phase 9: 性能优化
- [ ] 并发工具执行
- [ ] 流式大文件处理
- [ ] 内存优化
- [ ] 编译优化

---

## 关键决策

### 配置路径
- **决策**: 使用 `~/.nimcode/` 而非 `~/.config/nimcode/`
- **原因**: 匹配 vibecoding 的 `~/.vibecoding/` 模式

### Provider 路由
- **决策**: Settings.json providers map 完全解析，不硬编码
- **原因**: 支持任意 provider 名称

### 流式实现
- **决策**: 使用 StreamCallback/AgentEventCallback 闭包
- **原因**: 避免 channels 或 async 的复杂性

### 外部依赖
- **决策**: 纯 Nim 标准库，无外部依赖
- **原因**: 简化构建和部署

---

## 编译命令

```bash
# Debug build
~/.nimble/bin/nim c -d:ssl -o:bin/nimcode src/nimcode.nim

# Release build
make release

# 测试
./bin/nimcode --version
./bin/nimcode --help
./bin/nimcode -P "say hi"
```

---

## 版本历史

### v0.1.1 (当前)
- 初始功能移植
- Provider 增强
- MCP/Cron/Sandbox 支持
- A2A/ACP/Hermes 骨架

### v0.1.0
- 初始版本

---

## 文件结构

```
src/nimcode/
├── a2a/
│   └── a2a.nim
├── acp/
│   └── acp.nim
├── agent/
│   ├── agent.nim
│   ├── system_prompt.nim
│   └── types.nim
├── config/
│   └── config.nim
├── context/
│   ├── compaction.nim
│   └── context.nim
├── contextfiles/
│   └── contextfiles.nim
├── cron/
│   └── cron.nim
├── gateway/
│   └── gateway.nim
├── hermes/
│   └── hermes.nim
├── mcp/
│   └── mcp.nim
├── memory/
│   └── memory.nim
├── provider/
│   ├── anthropic.nim
│   ├── factory.nim
│   ├── google.nim
│   ├── openai.nim
│   └── types.nim
├── sandbox/
│   └── sandbox.nim
├── session/
│   └── session.nim
├── skills/
│   └── skills.nim
├── tools/
│   ├── jobs.nim
│   └── tools.nim
└── tui/
    └── format.nim
```

---

## 统计

- **总文件数**: 25 个 Nim 源文件
- **代码行数**: ~92,000 行 (编译后)
- **工具数量**: 12 个内置工具 + MCP 工具 + Web Search
- **Provider 数量**: 4 个 (OpenAI, Anthropic, Google, DeepSeek)
- **协议支持**: 3 个 (MCP, A2A, ACP)
