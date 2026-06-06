# NimCode

NimCode 是一个终端 AI 编码助手，使用纯 Nim 编写，零外部依赖。

## 特性

- **纯 Nim** — 仅使用 Nim 标准库，无外部依赖
- **多 Provider 支持** — 支持 OpenAI、Anthropic、Google Gemini、DeepSeek 等
- **内置工具** — read、write、edit、bash、ls、grep、find、plan、jobs、kill、cron、spawn、skill_ref
- **会话持久化** — JSONL 格式存储对话历史
- **多模式** — plan（只读）、agent（默认）、yolo（无限制）
- **沙箱支持** — 可选 bwrap 隔离执行 bash 命令
- **MCP 协议** — 支持 Model Context Protocol 扩展工具
- **上下文管理** — 自动加载 AGENTS.md、CLAUDE.md、.cursorrules
- **记忆系统** — 持久化记忆存储
- **Cron 调度** — 定时任务支持

## 支持平台

| 平台 | amd64 | arm64 | 备注 |
|------|-------|-------|------|
| Linux | ✓ | ✓ | 主要目标平台 |
| Windows | ✓ | ○ | amd64 就绪；arm64 需要交叉编译器 |
| macOS | ○ | ○ | 交叉编译需要 Zig 或 osxcross |

## 前置要求

### 必需

- [Nim](https://nim-lang.org/) >= 2.0.0
- `gcc`（Linux amd64 原生构建）

### 交叉编译（发布构建）

```bash
# Linux arm64
sudo apt-get install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross

# Windows amd64
sudo apt-get install -y mingw-w64

# 推荐：使用 Zig 处理所有平台
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /opt/zig
sudo ln -s /opt/zig/zig /usr/local/bin/zig
```

## 安装

```bash
# 克隆仓库
git clone <repository-url>
cd NimCode

# 编译（原生 Linux amd64）
nim c -d:ssl -o:bin/nimcode src/nimcode.nim

# 带优化的发布构建
nim c -d:ssl -d:release --opt:size -o:bin/nimcode src/nimcode.nim

# 或使用 Makefile
make build      # 调试构建
make release    # 发布构建
```

## 配置

创建配置文件 `~/.nimcode/settings.json`：

```json
{
  "providers": {
    "openai": {
      "apiKey": "${OPENAI_API_KEY}",
      "baseUrl": "https://api.openai.com/v1",
      "api": "openai-chat"
    },
    "anthropic": {
      "apiKey": "${ANTHROPIC_API_KEY}",
      "baseUrl": "https://api.anthropic.com",
      "api": "anthropic-messages"
    },
    "deepseek": {
      "apiKey": "${DEEPSEEK_API_KEY}",
      "baseUrl": "https://api.deepseek.com",
      "api": "openai-chat"
    },
    "google-gemini": {
      "apiKey": "${GOOGLE_API_KEY}",
      "baseUrl": "https://generativelanguage.googleapis.com",
      "api": "google-gemini"
    }
  },
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek-chat",
  "defaultMode": "agent",
  "defaultThinkingLevel": "medium",
  "sandbox": { "enabled": false, "level": "none" },
  "compaction": { "enabled": true, "reserveTokens": 16384, "keepRecentTokens": 20000 }
}
```

或使用环境变量：
- `NIMCODE_PROVIDER` — 默认 Provider
- `NIMCODE_MODEL` — 默认模型
- `OPENAI_API_KEY` — OpenAI API 密钥
- `ANTHROPIC_API_KEY` — Anthropic API 密钥
- `DEEPSEEK_API_KEY` — DeepSeek API 密钥
- `GOOGLE_API_KEY` — Google Gemini API 密钥

## 使用

```bash
# 交互模式
./bin/nimcode

# 指定 Provider 和模型
./bin/nimcode -p deepseek -m deepseek-chat

# YOLO 模式（所有工具自动执行）
./bin/nimcode -M yolo

# 打印模式（非交互）
./bin/nimcode -P "解释这段代码"

# 继续最近的会话
./bin/nimcode -c

# 显示帮助
./bin/nimcode --help

# 显示版本
./bin/nimcode --version
```

## 内置工具

| 工具 | 说明 |
|------|------|
| `read` | 读取文件内容（支持文本和图片） |
| `write` | 写入文件 |
| `edit` | 精确文本替换编辑文件 |
| `bash` | 执行 shell 命令（支持沙箱） |
| `ls` | 列出目录内容 |
| `grep` | 正则搜索文件内容 |
| `find` | 按文件名模式查找 |
| `plan` | 发布或更新结构化任务计划 |
| `jobs` | 列出后台任务 |
| `kill` | 终止后台任务 |
| `cron` | 管理定时任务 |
| `spawn` | 生成子 Agent 并行处理 |
| `skill_ref` | 加载技能引用文件 |
| `memory_read` | 读取持久化记忆 |
| `memory_write` | 写入持久化记忆 |

## 模式

| 模式 | 说明 |
|------|------|
| `plan` | 只读模式，分析代码和创建计划 |
| `agent` | 默认模式，允许读写文件和执行命令 |
| `yolo` | 无限制模式，所有工具自动执行 |

## 交互命令

在交互模式下可使用：
- `clear` — 清除对话历史
- `exit` / `quit` — 退出
- `help` — 显示可用命令
- `mode` — 显示当前模式
- `provider` — 显示当前 Provider
- `model` — 显示当前模型
- `session` — 显示会话信息
- `sessions` — 列出最近会话
- `usage` — 显示上下文使用情况
- `mcp` — 显示 MCP 服务器状态
- `sandbox` — 显示沙箱状态
- `tools` — 列出可用工具

## 开发

```bash
# 编译
nim c src/nimcode.nim

# 运行测试
nim c -r tests/test_xxx.nim

# 清理构建产物
make clean
```

## 项目结构

```
src/
├── nimcode.nim          # CLI 入口
└── nimcode/
    ├── config/          # 配置和默认值
    ├── provider/        # Provider 抽象层
    ├── agent/           # Agent 循环和事件
    ├── tools/           # 内置工具
    ├── session/         # JSONL 会话存储
    ├── contextfiles/    # 上下文文件发现
    ├── context/         # Token 估算和上下文管理
    ├── skills/          # 技能加载
    ├── memory/          # 持久化记忆
    ├── mcp/             # MCP 客户端
    ├── cron/            # Cron 调度器
    ├── sandbox/         # 沙箱（bwrap）支持
    ├── a2a/             # Agent-to-Agent 协议
    ├── acp/             # Agent Client Protocol
    ├── hermes/          # Hermes 守护进程
    └── tui/             # 终端 UI
```

## 许可证

MIT
