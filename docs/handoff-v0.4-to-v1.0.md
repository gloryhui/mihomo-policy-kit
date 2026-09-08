# V0.4 → V1.0 阶段交接文档（Handoff）

> 生成时间：2026-09-08（V0.4 批次 Sol Final Review PASS、PR #16 merge、Issue #15 / #4 关闭之后）
> 用途：为后续新的 Codex 会话 / V1.0 Roadmap 提供简洁、事实化、可恢复上下文的阶段交接。
> 事实核对基准：`main` 分支当前代码 + 本仓库文档 + GitHub Issue #1/#2/#3/#4/#15 + PR #16，不依赖旧会话记忆。

---

## 1. 当前版本状态

- **当前 main commit SHA**：`7c04e91f9516b5398064646234c41b5ecba11311`（`[V0.4] add multi-client output adapters`，PR #16 squash merge）
- **main 最新 CI**：run #49 Linux + Windows Green（Linux 实际执行官方 `sing-box v1.14.0 check -c`）
- **V0.1 DONE**：代码批次 Issue #7 / 验收批次 #9 关闭；PR #8 merge
- **V0.2 DONE**：Issue #2 关闭；批次 #11 / PR #12；squash merge `394bff9fb308061be47f676e7749bff58c845f3b`
- **V0.3 DONE**：Issue #3 关闭；批次 #13 / PR #14；squash merge `e8f9fff45ecfeb9159e74e4e727dfc196141dad0`
- **V0.4 DONE**：Issue #4 关闭；批次 #15（`[DONE][BATCH-V0.4]`）关闭；PR #16 merge 到 `7c04e91`
- **当前没有 START / RUNNING Batch**（GitHub 无 open Issue / open PR）
- **当前 Roadmap 已结束**（原定 V0.1 ～ V0.4 全部完成；未自动开启新 Roadmap）

---

## 2. 当前实际架构

```text
Source（机场订阅 URL 经 MPK_SOURCE_URL / 本地 YAML）
  -> Provider Manifest / Generic Runner
       -> Smart-Config-Kit（仅 Normal / oc-normal，禁止 Smart / LightGBM）
       -> ACL4SSR（官方 raw YAML payload: rule-provider 引用）
  -> Normalized Mihomo policy
  -> Provider-neutral Overlay（逻辑 target 映射、自定义规则最高优先级）
  -> Common patches（移除顶层 global-client-fingerprint、保留节点级 client-fingerprint、
     geodata-loader: memconservative）+ DNS Profile（upstream / china_compat）
  -> Validate（结构校验 + 节点数量保护；有 mihomo 时 mihomo -t）
  -> Output Adapter（OutputRegistry，固定五种）
       -> Mihomo（dist/mihomo.yaml）
       -> Stash（dist/stash.yaml）
       -> Loon（dist/loon.conf）
       -> Surge（dist/surge.conf）
       -> sing-box（dist/sing-box.json）
  -> Publisher（V0.2，见下）
```

**Publisher 边界（务必如实记录）**：

- Publisher 当前正式发布的**仍然只有 Mihomo YAML**（`/sub/<token>/mihomo.yaml`），
  immutable `builds/` + immutable `{current, previous}` state-set + 单一原子 `active` 指针 + 多 token。
- **不要暗示 Stash / Loon / Surge / sing-box 产物已拥有稳定 HTTPS Publisher URL**。
  本仓库没有任何代码、Issue 或文档证据表明其它产物已被 Publisher 发布。

架构分层原则：Provider 专有逻辑不回流 `scripts/build.rb`；Output 专有逻辑不污染 Provider / Overlay。

---

## 3. 已完成能力

### V0.1（#7 / #9）
- Smart-Config-Kit **Normal** Provider（`oc-normal` 校验，拒绝 Smart / LightGBM）
- real subscription build（`MPK_SOURCE_URL` 注入，日志脱敏为 `$MPK_SOURCE_URL`）
- 节点数量保护（source proxies > 0 → 转换后 0 则 hard fail）
- fingerprint 保留（移除顶层 `global-client-fingerprint`；节点自身 `client-fingerprint` 必须保留）
- `china_compat` DNS Profile（国内 bootstrap / DoH，删除境外 bootstrap 特例）
- custom rules 使用逻辑 target（`ai/global/us/hk/jp/sg/direct/reject/final`），最高优先级插入
- 离线 fixture E2E；真实客户端（Clash Party / Clash Verge Rev / Nikki）验收记录于 #9

### V0.2（#11）
- immutable builds（`builds/<build-id>/`，staging 后原子进入）
- state-set（immutable `{current, previous}` 对）+ 单一原子 `active` 指针
- 一键 rollback（只切状态指针，不重建 / 修改 builds）
- 多 token 稳定 URL `/sub/<token>/mihomo.yaml`，可独立吊销
- Nginx HTTPS 静态发布示例（token URI access log 关闭）
- secret-safe logging（token 不进普通日志 / 异常 / CI）
- Publisher fault / crash / staging / secret 回归 + Linux integration

### V0.3（#13）
- Provider Manifest 最小契约（id / format / runner / group_map）
- Generic Provider Runner（Bash + Ruby runner）
- Smart-Config-Kit 迁入通用契约，零行为回归
- ACL4SSR 第二 Provider（官方 raw YAML rule-provider 引用，规则正文不复制进仓库）
- 双 Provider 离线 E2E 与同一份逻辑 target 复用

### V0.4（#15）
- Mihomo / Stash / Loon / Surge / sing-box Output Adapter registry
- 严格 capability failure：不支持协议 / 规则 / group 能力 hard fail
- 无 silent node drop、无静默 DIRECT fallback
- pre-promotion validation：全部 render + validate + staged candidate core check 通过后才 promotion，失败不覆盖已有 good artifact
- Linux CI 官方 pinned `sing-box v1.14.0 check -c`（固定 SHA-256 校验后执行）
- Windows CI（adapter registry / fixture 纯 Ruby + Publisher 通用逻辑）

---

## 4. 当前明确能力边界

- **`actual_ios_client: unconfirmed`**：无可靠证据证明用户实际使用 Stash / Loon / Surge 中哪一个；不得把任一客户端伪称为已确认。
- **Publisher 只发布 Mihomo YAML**（见 §2），其它产物无稳定 HTTPS URL。
- **Stash / Loon / Surge**：目前依赖 deterministic parser + required-section + reference-integrity **结构校验**，非官方客户端运行时验收；文档中已明确这一限制。
- **sing-box V0.4 支持边界**（有官方 `sing-box check` 兜底）：
  - 代理：`ss` / `vmess`(TCP) / `trojan`(TCP)
  - 组：仅 `select` → selector
  - 规则：`DOMAIN*` / `IP-CIDR*` / `MATCH`；`GEOIP` 明确拒绝
  - `REJECT` 规则 → 原生 `action: reject`；**不生成**已移除的 `block` outbound
- **sing-box hostname server 当前 hard fail**：sing-box 1.14 对域名 `server` 要求 resolver，V0.4 不转换 DNS / `domain_resolver`，因此只接受 IP-literal `server`。
- **协议能力（按实际 adapter 代码 `SUPPORTED_PROXIES` 记录）**：
  - Stash：`ss` / `vmess` / `trojan` / **`vless`**；规则支持 `RULE-SET`
  - Loon / Surge：`ss` / `vmess` / `trojan`（group 支持 `select` / `url-test` / `fallback`）；**`vless` 明确拒绝**
  - sing-box：`ss` / `vmess`(TCP) / `trojan`(TCP)；**`vless` 明确拒绝**
  - **`mieru`**：所有非 Mihomo adapter 明确拒绝
- **未支持即 hard fail，不静默降级**：不要把尚未支持的能力写成已支持。

---

## 5. 生产现状

**明确区分「代码完成」与「生产部署完成」。**

当前 Roadmap（V0.1 ～ V0.4）**代码层已完成并通过 CI / Sol Review / merge**，但以下生产事项在仓库中**没有证据表明已完成**，全部标记：

> **NOT YET VERIFIED IN PRODUCTION**

- Linux production deployment
- real HTTPS Publisher（线上域名 / 证书 / Nginx 实跑）
- real `MPK_SOURCE_URL` 通过环境变量注入并持续构建
- systemd timer / cron 无人值守运行
- continuous real-device acceptance（真实客户端持续验收）
- rollback drill（真实回滚演练）
- token revoke drill（真实吊销演练）
- upstream drift detection（上游 Provider 变更漂移检测）

仓库提供的是：`deploy/nginx/*.example`、`deploy/systemd/*`（service / timer / cron 示例）、
`scripts/smoke_test.ps1`（人工执行入口）。示例不等于已部署。禁止脑补这些事项已完成。

---

## 6. 下一阶段建议（仅建议，不创建 Issue）

**建议下一 Roadmap：`V1.0 Production Deployment & Unattended Operation`**

建议范围：

```text
01  Linux production deployment baseline
02  HTTPS Publisher production rollout
03  systemd timer / cron unattended build
04  build change detection
05  build / publish status summary
06  upstream drift detection
07  real Mihomo client soak test
08  rollback / token revoke disaster drill
09  v1.0.0 release / docs closeout
```

- V1.0 是否正式采用该范围，**由 Pipeline Manager 决定**。
- **Codex 不得自行启动**，不得自行创建 V1.0 Issue / Roadmap。
- 历史遗留的未勾选项（README 中 V0.2 `Provider 版本锁定`、`GitHub Actions / 自建 CI 发布`；V0.3+ `其它社区分流 Provider`、`Shadowrocket 输出`）同样由 Pipeline Manager 决定是否并入 V1.0。

---

## 7. 架构红线（保留并总结）

- **GitHub 是事实源**：Issues / PR / CI 决定批次状态；Codex 不自造任务、不自 merge。
- Smart-Config-Kit 只用 **Normal / oc-normal**；**不允许 Smart / LightGBM**（`VERSION_TAG` 校验拒绝）。
- Provider-specific logic 不回流 `scripts/build.rb`；Output-specific logic 不污染 Provider / Overlay。
- custom rules 继续使用逻辑 target（`ai/global/us/hk/jp/sg/direct/reject/final`），不直接绑定上游中文策略组名。
- source proxies > 0 → transformed 0 必须 **hard fail**（节点数量保护）。
- 顶层 `global-client-fingerprint` 可移除；节点自身 `client-fingerprint` **必须保留**。
- `geodata-loader: memconservative`。
- unsupported capability **hard fail**（错误只含 capability 名，不含敏感字段）。
- **no silent DIRECT fallback**；不静默丢节点。
- failed build **不覆盖 good artifact**（先全部 render/validate/core-check 再 promotion）。
- **Publisher atomic state semantics 不得倒退**（current/previous + active 原子指针 + rollback）。

---

## 8. 安全红线（严禁）

- 真实机场订阅 URL / Token
- 节点 UUID、password、private key、Reality secret
- Authorization header / Cookie / API Key
- 生成后的 `dist/mihomo.yaml`（及任何生成产物）
- runtime publisher secrets（`runtime/`：builds / token-state / 完整 token）

只允许 sanitized fixtures（`127.0.0.x`、`example.invalid`、`fake-password-*`、全零 UUID、
`VERY_SECRET_*_TOKEN` 仅用于断言错误消息不含 secret）。日志 / 异常 / Issue / PR / CI 同样不得泄漏。

---

## 9. 如何恢复（未来 Codex 启动流程）

```bash
git fetch origin
git switch main
git pull origin main
git status
```

然后读取：

```text
AGENTS.md
docs/handoff-v0.4-to-v1.0.md
README.md
docs/architecture.md
```

再读取 GitHub 当前**唯一**的 `[START][BATCH-*]` Issue（如有），并按其指定分支 / 步骤执行。

**如果没有 START：不要自行创造任务。**

---

## 10. 最终动作记录

本交接文档由 Codex 在本会话执行：

- 已 `git fetch origin` + `git switch main` + `git pull origin main` + `git status`（clean）
- 已确认：PR #16 MERGED、Issue #15 `[DONE]` closed、Issue #4 `[DONE]` closed、main CI Green（run #49）
- 已核对代码 / 文档 / Issue 事实后生成本文档
- 仅提交本份文档，commit message：`docs: add v0.4 to v1.0 handoff`
- 未创建 V1.0 Issue、未建新 branch、未开 PR、未修改代码、未开始生产部署、未开始下一 Roadmap
