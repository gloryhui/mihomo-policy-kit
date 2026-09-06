# AGENTS.md

本仓库采用 **Batch Issue 驱动 + Codex 执行 + ChatGPT Sol 复核** 的开发方式。

目标很简单：Sol 先把当前阶段需要做的工作按顺序整理进一个 `[START]` Issue，Codex 只读这个启动 Issue，在同一个开发分支里按顺序完成全部工作，最后提交一个总 PR。不要再为每个小步骤开一堆 Issue / PR，把项目管理做成人类迷宫。

## 角色

- **Pipeline Manager / Reviewer：ChatGPT GPT-5.6 Sol**
  - 检查 main、Issues、PR、CI
  - 决定当前批次范围和执行顺序
  - 创建一个 `[START]` Batch Issue
  - 最终统一 Review 总 PR
- **Executor：本地 Codex**
  - 读取当前 `[START]` Batch Issue
  - 在指定分支上按 Issue 中的步骤连续开发
  - 自主处理普通实现细节
  - 补测试、跑 CI
  - 最后只提交一个总 PR
  - 不自行改变 Roadmap，不自行 merge

## 当前唯一开发入口

当存在一个明确的 `[START]` Issue 时，它就是当前批次的执行入口。

Codex 开始前必须阅读：

1. `AGENTS.md`
2. 当前 `[START]` Issue 全文
3. `README.md`
4. `docs/architecture.md`
5. 与当前批次相关的现有 Issue / PR

**批次执行期间不要使用 `scripts/codex-next.*` 逐条领取任务。** 这些脚本保留用于未来需要恢复单任务模式时使用，但当前批次以 `[START]` Issue 为准。

## Batch Issue 状态

启动 Issue 只使用下面几个状态：

```text
[START]   -> 已排好工作，可以开始
[RUNNING] -> Codex 正在连续执行整个批次
[REVIEW]  -> 总 PR 已提交，等待 Sol 统一复核
[BLOCKED] -> 存在真正阻塞，需要人工决策
[DONE]    -> 总 PR 已通过并合并
```

不要给批次中的每个小步骤再创建状态 Issue。

Roadmap / Epic Issue，例如 V0.1、V0.2、V0.3、V0.4，只作为阶段目标和背景资料，不作为 Codex 的直接任务队列。

## Codex 执行协议

拿到 `[START]` Issue 后：

1. 将启动 Issue 标题从 `[START]` 改为 `[RUNNING]`。
2. 使用启动 Issue 指定的分支；如果分支已存在，继续该分支，不另建重复分支。
3. 严格按启动 Issue 中的编号顺序执行工作。
4. 每完成一项就在启动 Issue 的 checklist 中勾选对应项目，或者在本地记录进度后统一更新。
5. 普通实现细节自行判断，不要每一步都停下来问。
6. 新增逻辑必须补测试；Bug 修复必须尽量增加回归测试。
7. 不做与当前批次无关的重构。
8. 所有步骤完成后统一跑完整测试和 CI。
9. 只创建一个总 PR，PR 必须引用启动 Issue以及相关 Epic/Task Issue。
10. 将启动 Issue 改为 `[REVIEW]`，然后停止，等待 Sol 统一复核。
11. 不自行 merge，不自行关闭 Roadmap Issue，不自行开始下一批次。

## Windows 开发约定

当前主开发环境是 Windows + PowerShell 7。

- Git、`gh`、Ruby 测试应能从 PowerShell 直接执行。
- Provider 本身仍是 Bash；真实 Provider 执行可以使用 Git Bash 或 WSL2。
- 不要为了“纯 Windows”把 Bash Provider 改写成 PowerShell。
- PowerShell / Ruby 新增代码要考虑 Windows 路径、UTF-8、中文、CRLF/LF 和 native command 行为。
- 如果功能声明支持 Windows，必须有 Windows CI 或明确的本地验证依据，不能只在 Ubuntu 上跑 `pwsh` 就宣布胜利。

## 安全红线

本仓库是公开仓库。严禁提交或输出：

- 真实机场订阅 URL / Token
- 节点 UUID、密码、私钥
- 生成后的 `dist/mihomo.yaml`
- 私有 HTTPS 发布 Token
- API Key / Cookie / Authorization Header
- 任何个人或内部代理凭据

真实订阅只能通过环境变量（当前为 `MPK_SOURCE_URL`）或本地被 `.gitignore` 排除的文件注入。

日志、异常、测试输出、PR、Issue、Actions 同样不得泄漏这些信息。

## 当前架构红线

除非当前 Batch Issue 明确要求，不得改变：

- Smart-Config-Kit 作为外部 Provider，而不是复制其规则源码
- V0.1 只使用 Normal / 非 Smart 版本
- 自定义规则使用逻辑 target，不直接绑定上游中文策略组名
- 顶层 `global-client-fingerprint` 可移除，但节点自身 `client-fingerprint` 必须保留
- `geodata-loader` 使用 `memconservative`
- Provider 转换后必须有节点数量保护
- 自定义规则 Overlay 必须保持高优先级
- 有 `mihomo` 时必须执行 `mihomo -t`
- 最终产物不得提交进公开仓库

## BLOCKED 的定义

只有下面情况才进入 `[BLOCKED]`：

- 需要用户提供真实 Secret / 外部账号信息
- 验收条件互相矛盾
- 必须改变架构红线才能继续
- 外部依赖长期不可用且没有合理降级方案
- 继续操作可能造成数据破坏或 Secret 泄漏

进入 BLOCKED 后，在启动 Issue 评论中写清：

- 卡在哪里
- 已验证什么
- 脱敏后的错误
- 需要哪项决策

不要偷偷降低验收标准。

## 完成标准

一个 Batch 只有同时满足以下条件才算完成：

- 启动 Issue 的全部代码类验收项完成
- 新增/修改测试通过
- GitHub Actions CI 通过
- 总 PR 内容与启动 Issue 一致
- Sol Review 通过
- PR 合并
- 启动 Issue 标记为 `[DONE]` / 关闭

原则：**一个批次，一个分支，一个总 PR，一次统一 Review。**
