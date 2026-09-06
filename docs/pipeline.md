# 开发流水线

mihomo-policy-kit 当前采用 **一个启动 Issue + 一个开发分支 + 一个总 PR** 的批次开发方式。

我们不再把一个小阶段拆成十几个状态 Issue。项目规模还没大到需要给自己造一套 Jira 赝品。

## 流程

```text
Sol 检查 main / Issues / PR / CI
        ↓
确定当前阶段边界与前后依赖
        ↓
创建一个 [START] Batch Issue
        ↓
Codex 读取启动 Issue
        ↓
Issue -> [RUNNING]
        ↓
在一个分支中按顺序连续开发
        ↓
每一步补测试、局部验证
        ↓
整个批次完整回归
        ↓
创建一个总 PR
        ↓
Issue -> [REVIEW]
        ↓
Sol 统一 Review + CI
     ┌──┴──┐
   需修改   通过
     ↓       ↓
 原分支返工  Merge
              ↓
        Issue -> [DONE]
              ↓
        Sol 安排下一 Batch
```

## GitHub 是唯一事实源

新开 ChatGPT / Codex 会话以后，不应该依赖旧聊天才能继续。

GitHub 中必须能恢复：

- 当前 Roadmap / Epic
- 当前 `[START]` / `[RUNNING]` / `[REVIEW]` Batch Issue
- Batch Issue 中的执行顺序和验收项
- 当前开发分支
- 当前总 PR
- CI 状态
- BLOCKED 原因

聊天只用于讨论，不作为流水线状态存储。

## Roadmap 顺序

当前 Roadmap 顺序固定为：

```text
V0.1 可靠完成 Mihomo + Smart-Config-Kit Normal 构建链路
  ↓
V0.2 私有 HTTPS 发布、current/previous、rollback
  ↓
V0.3 Provider 接口稳定化并接入第二 Provider
  ↓
V0.4 非 Mihomo 多客户端输出
```

不要把 V0.2/V0.3/V0.4 塞进 V0.1 的代码 PR。

## Batch Issue 的写法

每个启动 Issue 必须包含：

- 当前基线 main SHA / 需要继承的已有分支或 PR
- 本批次明确目标
- 不做什么
- 1..N 的严格执行顺序
- 每一步验收条件
- 测试要求
- 最终 PR 要求
- BLOCKED 条件

Codex 不自行重新排序，也不自行增加下一阶段功能。

## 分支与 PR

一个 Batch 只使用一个开发分支，例如：

```text
codex/batch-v0.1
```

整个 Batch 最后只提交一个总 PR：

```text
codex/batch-v0.1 -> main
```

PR Body 至少包含：

```markdown
Refs #<START_ISSUE>
Refs #<相关 Epic / Task>

## 批次完成内容
- ...

## 测试
- ... ✅

## 未完成 / 人工验收
- ...
```

不要为 Batch 中每一步再开 PR。

## Windows 主开发环境

当前主要开发环境：

```text
Windows
PowerShell 7+
Git for Windows
gh CLI
Ruby 3.x
Git Bash 或 WSL2（用于 Bash Provider）
```

CI 至少应覆盖：

- Linux：Ruby、Bash、Provider/构建相关测试
- Windows：PowerShell 与 Windows 下的 Ruby 通用逻辑测试

是否下载真实 Mihomo Core、是否执行联网集成测试，由具体 Batch Issue 决定，不默认把 Secret 放进 GitHub Actions。

## Reviewer 统一检查项

总 PR Review 时重点检查：

- Scope 是否与启动 Issue 一致
- Provider 边界是否仍然清晰
- Smart-Config-Kit 是否仍为 Normal / 非 Smart
- 自定义规则是否保持最高优先级
- 逻辑 target 是否没有泄漏 Provider 专有命名
- `global-client-fingerprint` 是否只删除顶层
- 节点级 `client-fingerprint` 是否保留
- `geodata-loader: memconservative` 是否稳定存在
- proxies 节点保护是否有效
- DNS upstream / china_compat 是否符合约定
- Secret 是否可能进入日志、异常、Actions、PR、fixture
- Windows 与 Linux 测试是否与实际支持范围一致
- 是否出现当前 Batch 不需要的过度重构

## 失败处理

如果普通测试失败，Codex自行修复并继续。

只有真正阻塞才将启动 Issue改为：

```text
[BLOCKED]
```

并写明：

- 阻塞点
- 已验证内容
- 脱敏错误
- 需要的人工决策

解决后继续原分支，不新开重复批次。
