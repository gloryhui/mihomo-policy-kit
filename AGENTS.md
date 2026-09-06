# AGENTS.md

本仓库采用 **Issue 驱动 + Codex 执行 + ChatGPT Sol 审查** 的流水线。

任何自动编码 Agent 在开始工作前，必须先阅读本文件、目标 Issue、README.md 与相关设计文档。

## 角色

- **Pipeline Manager / Reviewer**：ChatGPT GPT-5.6 Sol
  - 检查仓库、PR、CI
  - 拆分下一步任务
  - 创建 `[READY]` Issue
  - 审查 `[REVIEW]` PR
  - 决定是否进入下一任务
- **Executor**：本地 Codex
  - 只领取一个 `[READY]` Issue
  - 实现、测试、提交 PR
  - 不自行扩展项目范围
  - 不自行合并 PR

## Issue 状态机

任务 Issue 标题必须使用以下状态之一：

```text
[READY]  -> 可领取
[DOING]  -> Codex 正在执行
[REVIEW] -> 已提交 PR，等待 Sol 审查
[BLOCKED] -> 存在阻塞，需要人工/架构决策
[DONE]   -> 已完成并合并
```

Epic / Roadmap Issue（例如 V0.1、V0.2）不要求使用上述前缀；实际开发必须拆成可独立验收的 Task Issue。

## Codex 领取任务

每次只领取 **一个** 最早的 `[READY]` Issue：

```bash
gh issue list \
  --repo gloryhui/mihomo-policy-kit \
  --state open \
  --search '"[READY]" in:title' \
  --limit 20 \
  --json number,title,url,createdAt
```

也可以运行：

```bash
./scripts/codex-next.sh
```

如果没有 `[READY]` Issue：**停止，不要自行找活。**

## Codex 执行协议

领取后：

1. 阅读目标 Issue 全文及引用的 Epic。
2. 将 Issue 标题的 `[READY]` 改为 `[DOING]`。
3. 从最新 `main` 创建分支：

```text
codex/issue-<number>-<short-name>
```

4. 严格按 Issue 的范围和验收条件开发。
5. 不修改与任务无关的代码。
6. 新增逻辑必须补测试。
7. 执行仓库现有测试与校验。
8. 推送分支并创建 PR，PR Body 必须包含：
   - `Closes #<issue>` 或 `Refs #<issue>`
   - 修改摘要
   - 测试命令与结果
   - 风险/未解决问题
9. 将 Issue 标题从 `[DOING]` 改为 `[REVIEW]`。
10. 停止。不要领取下一个任务，不要自行合并 PR。

## Review 后返工

如果 Sol 在 PR 中提出修改：

- Issue 保持 `[REVIEW]`
- Codex 只处理该 PR 的 Review 意见
- 修改后重新跑测试并 push
- 不新建重复 PR
- 不领取新任务

## 安全红线

本仓库是公开仓库。严禁提交：

- 真实机场订阅 URL / Token
- 节点 UUID、密码、私钥
- 生成后的 `dist/mihomo.yaml`
- 私有 HTTPS 发布 Token
- 任何个人或内部代理凭据

真实订阅只能通过环境变量（当前为 `MPK_SOURCE_URL`）或本地被 `.gitignore` 排除的文件注入。

## 当前架构红线

除非 Issue 明确要求，不得改变：

- Smart-Config-Kit 作为外部 Provider，而不是复制其规则源码
- V0.1 只使用 Normal / 非 Smart 版本
- 自定义规则使用逻辑 target，不直接绑定上游中文策略组名
- 顶层 `global-client-fingerprint` 可移除，但节点自身 `client-fingerprint` 必须保留
- Provider 转换后必须有节点数量保护
- 自定义规则 Overlay 必须保持优先级
- 有 `mihomo` 时必须执行 `mihomo -t`
- 最终产物不得提交进公开仓库

## 完成标准

一个 Task 只有同时满足以下条件才算完成：

- Issue 验收项满足
- 新增/修改测试通过
- GitHub Actions CI 通过
- Sol Review 通过
- PR 合并
- Task Issue 标记为 `[DONE]` / 关闭

流水线的原则很简单：**一次只让一个任务进入开发，避免几个 Agent 同时“顺手优化”到最后谁也不知道项目为什么长成这样。**
