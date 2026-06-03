# NimCode 开发路线图

## 当前状态 (v0.1.0) ✅ 已完成

- [x] 项目骨架 (nimble, 目录结构)
- [x] 配置模块 (settings.json 加载)
- [x] Provider 抽象和 OpenAI 兼容实现
- [x] Agent 循环 (系统提示、消息、流式响应)
- [x] 内置工具 (read, write, edit, bash, ls, grep, find)
- [x] CLI 入口 (交互式/非交互式)
- [x] 会话持久化 (JSONL)

---

## Phase 1: 核心增强 (v0.2.0)

### 1.1 上下文管理
- [ ] Token 估算 (`chars/4` 启发式)
- [ ] 上下文使用量跟踪
- [ ] 自动压缩 (当上下文超过阈值)
- [ ] 压缩摘要生成

**参考**: `/home/free/src/vibecoding/internal/context/context.go`

### 1.2 Context Files (AGENTS.md 支持)
- [ ] 自动发现 AGENTS.md, CLAUDE.md, .cursorrules
- [ ] 全局/父目录/项目三级加载
- [ ] 注入到系统提示

**参考**: `/home/free/src/vibecoding/internal/contextfiles/contextfiles.go`

### 1.3 多 Provider 支持
- [ ] Anthropic 兼容实现
- [ ] Google Gemini 兼容实现
- [ ] Provider 工厂模式
- [ ] 自动检测 API 类型

**参考**: `/home/free/src/vibecoding/internal/provider/anthropic/`

---

## Phase 2: 工具增强 (v0.3.0)

### 2.1 Plan 工具
- [ ] 结构化任务计划
- [ ] 步骤状态跟踪 (pending/running/done/failed)
- [ ] 可视化输出

**参考**: `/home/free/src/vibecoding/internal/tools/plan.go`

### 2.2 Jobs 管理
- [ ] 后台任务管理
- [ ] 任务状态查询 (jobs 工具)
- [ ] 任务终止 (kill 工具)

**参考**: `/home/free/src/vibecoding/internal/tools/jobmanager.go`

### 2.3 Skill Ref 工具
- [ ] 技能发现和加载
- [ ] 按需加载引用文件
- [ ] 技能上下文注入

**参考**: `/home/free/src/vibecoding/internal/skills/skills.go`

---

## Phase 3: 会话增强 (v0.4.0)

### 3.1 会话管理增强
- [ ] 会话列表和搜索
- [ ] 会话恢复 (按 ID/路径)
- [ ] 会话分支 (parent/child)
- [ ] 会话导出

**参考**: `/home/free/src/vibecoding/internal/session/session.go`

### 3.2 Memory (memory.md)
- [ ] 持久化记忆文件
- [ ] 自动提取关键信息
- [ ] 跨会话记忆

**参考**: VibeCoding 的 memory 模块

### 3.3 审批机制
- [ ] Agent 模式下的工具审批
- [ ] Bash 命令白名单/黑名单
- [ ] Write/Edit 确认

**参考**: `/home/free/src/vibecoding/internal/agent/agent.go` (NeedsApproval)

---

## Phase 4: 安全增强 (v0.5.0)

### 4.1 Sandbox 支持
- [ ] 无沙箱模式 (none)
- [ ] Bubblewrap 沙箱 (Linux)
- [ ] 路径限制和权限控制

**参考**: `/home/free/src/vibecoding/internal/sandbox/`

### 4.2 路径安全
- [ ] 工作目录限制
- [ ] 路径遍历防护
- [ ] 符号链接处理

**参考**: `/home/free/src/vibecoding/internal/tools/tool.go` (ResolvePath)

---

## Phase 5: 用户体验 (v0.6.0)

### 5.1 TUI 增强
- [ ] 彩色输出
- [ ] 进度指示器
- [ ] 工具执行可视化
- [ ] Diff 展示

**参考**: `/home/free/src/vibecoding/internal/tui/`

### 5.2 命令系统
- [ ] 斜杠命令 (/clear, /mode, /compact)
- [ ] 命令历史
- [ ] Tab 补全

**参考**: `/home/free/src/vibecoding/internal/tui/commands.go`

### 5.3 输出格式化
- [ ] Markdown 渲染
- [ ] 代码高亮
- [ ] 表格格式化

**参考**: `/home/free/src/vibecoding/internal/tui/formatters.go`

---

## Phase 6: 高级功能 (v0.7.0+)

### 6.1 HTTP Gateway
- [ ] OpenAI 兼容 API
- [ ] 会话管理
- [ ] 认证和安全

**参考**: `/home/free/src/vibecoding/internal/gateway/`

### 6.2 MCP 支持
- [ ] MCP 客户端
- [ ] 工具注册和调用
- [ ] 服务器管理

**参考**: `/home/free/src/vibecoding/internal/mcp/`

### 6.3 多 Agent
- [ ] 子 Agent 生成
- [ ] 任务分发
- [ ] 结果聚合

**参考**: `/home/free/src/vibecoding/internal/agent/subagent.go`

---

## 技术债务和改进

### 代码质量
- [ ] 单元测试覆盖
- [ ] 集成测试
- [ ] 文档注释完善
- [ ] 错误处理改进

### 性能
- [ ] 流式响应优化
- [ ] 内存使用优化
- [ ] 启动时间优化

### 可维护性
- [ ] 模块解耦
- [ ] 接口抽象
- [ ] 配置验证

---

## 优先级建议

### 高优先级 (立即实现)
1. **Context Files** — 用户体验关键
2. **Token 估算** — 防止上下文溢出
3. **多 Provider** — 扩展使用场景

### 中优先级 (近期实现)
4. **Plan 工具** — 提升规划能力
5. **Jobs 管理** — 后台任务支持
6. **审批机制** — 安全性增强

### 低优先级 (长期规划)
7. **TUI 增强** — 用户体验优化
8. **HTTP Gateway** — 服务化部署
9. **MCP 支持** — 生态集成

---

## 参考资源

- VibeCoding 源码: `/home/free/src/vibecoding/`
- Nim 标准库文档: https://nim-lang.org/docs/lib.html
- OpenAI API 文档: https://platform.openai.com/docs/api-reference
- Anthropic API 文档: https://docs.anthropic.com/claude/reference
