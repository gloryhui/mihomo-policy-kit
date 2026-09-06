# 开发流水线

mihomo-policy-kit 使用 GitHub Issue 作为任务队列，GitHub PR 作为交付物，GitHub Actions 作为自动验证。

目标不是造一套复杂项目管理系统，而是让“设计 / 执行 / 审查”明确分离。

## 流程

```text
Sol 检查 main / PR / CI
        ↓
Sol 拆分一个小任务
        ↓
创建 [READY] Issue
        ↓
本地 Codex 领取
        ↓
Issue -> [DOING]
        ↓
实现 + 测试
        ↓
创建 PR
        ↓
Issue -> [REVIEW]
        ↓
Sol Review + CI
     ┌──┴──┐
   需修改   通过
     ↓       ↓
 Codex返工   合并
             ↓
        Issue -> [DONE]
             ↓
        Sol 创建下一 [READY]
```

## 为什么一次只开放一个 READY

当前项目仍处在早期架构阶段。Provider、Overlay、发布器、多客户端输出之间存在依赖关系。

因此默认保持：

```text
READY <= 1
DOING <= 1
```

允许存在多个 `[REVIEW]` 只用于返工或特殊情况，但正常情况下也应保持单线推进。

这样可以确保后一任务是在前一任务已经验证后的代码基线上设计，而不是并行制造几个互相冲突的未来。

## Epic 与 Task

Roadmap 使用 Epic Issue，例如：

```text
[V0.1] 真实机场订阅端到端验证
[V0.2] 私有 HTTPS 订阅发布器
[V0.3] 第二 Provider
[V0.4] 多客户端输出
```

Epic 不能直接作为 Codex 的日常领取任务。

Sol 应将 Epic 拆成较小 Task，例如：

```text
[READY][V0.1-T01] 增加离线端到端构建 Fixture 与集成测试
[READY][V0.1-T02] 真实订阅构建与敏感信息保护验证
[READY][V0.1-T03] Clash Party / Verge / Nikki 客户端兼容验证
```

每个 Task 应尽量满足：

- 1 个明确目的
- 可独立测试
- 不依赖人工猜测验收结果
- 修改范围可控
- 完成后 main 比之前更可信

## Pipeline Manager 检查项

每次安排新任务前，Sol 检查：

1. `main` 最新提交和 CI 是否正常。
2. 是否有 `[DOING]` Issue。
3. 是否有 `[REVIEW]` Issue 与关联 PR。
4. PR 是否存在未解决 Review 意见。
5. 当前 Epic 的剩余验收项。
6. 下一任务是否依赖尚未合并的代码。
7. 是否涉及敏感数据泄漏风险。

只有当前任务完成后才创建下一 `[READY]`。

## Codex 工作入口

```bash
./scripts/codex-next.sh
```

脚本只负责找到下一任务，不负责自动改 Issue 状态或自动执行 Codex。

Codex 读取到任务后必须遵守根目录 `AGENTS.md`。

## PR 要求

PR 标题建议：

```text
[V0.1-T01] add offline end-to-end build test
```

PR Body 至少包含：

```markdown
Refs #5

## 变更
- ...

## 测试
- `ruby ...` ✅
- `./bin/mpk doctor` ✅

## 风险 / 未完成
- ...
```

不要在 PR、Issue、Actions 日志中输出真实订阅 URL 或节点凭据。

## Review 规则

Sol Review 重点不只看“能不能跑”，还检查：

- 是否破坏 Provider 边界
- 是否把 Smart-Config-Kit 专有逻辑泄漏进通用层
- 是否影响逻辑 target 抽象
- 是否可能把 proxies 清空
- 是否破坏 rule 优先级
- 是否破坏节点级 `client-fingerprint`
- 是否有隐私 / Token 泄漏
- 是否有必要测试
- 是否为了当前任务做了过度重构

## 失败处理

如果 Codex 无法完成：

```text
[DOING] -> [BLOCKED]
```

并在 Issue 评论中记录：

- 卡在哪里
- 已验证什么
- 错误日志（脱敏）
- 需要哪项决策

不要为了“把 Issue 做完”而偷偷改变验收标准。
