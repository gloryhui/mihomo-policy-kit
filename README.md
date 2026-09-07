# mihomo-policy-kit

一个面向多设备、多客户端的 **Mihomo 策略编译与私有订阅生成工具**。

它不试图重新发明一套分流规则，而是把优秀的上游分流项目当作 Provider，再叠加你自己的规则、校验与发布流程，最终生成一份可直接被 Clash Party、Clash Verge Rev、Nikki、Clash Meta / ClashMi 等 Mihomo 客户端订阅的 `mihomo.yaml`。

> 当前阶段：**v0.2**。v0.1 已完成 Smart-Config-Kit **Normal / 非 Smart** 构建链路与真实客户端验收；
> v0.2 增加私有 HTTPS 订阅发布器（immutable builds / current / previous / rollback / 多 Token）。

## 为什么做这个项目

现实里的客户端往往很杂：

- Windows / macOS：Clash Party、Clash Verge Rev
- OpenWrt / iStoreOS：Nikki
- Android：Clash Meta、ClashMi 或其他 Mihomo 客户端
- 以后还可能接入 Stash、Loon、Surge、Shadowrocket、sing-box

如果每台设备都执行一遍覆写脚本，会很快进入“哪台机器到底用了哪版配置”的经典人类困境。

这个项目的目标是把流程集中起来：

```text
机场原始订阅
      ↓
Provider（当前：Smart-Config-Kit Normal）
      ↓
统一 Mihomo 配置
      ↓
自定义规则 Overlay
      ↓
DNS / 公共补丁
      ↓
结构校验 + mihomo -t
      ↓
dist/mihomo.yaml
      ↓
HTTPS 私有订阅（V0.2 已实现：publish / current / previous / rollback / Token）
      ↓
Clash Party / Clash Verge / Nikki / Android Mihomo ...
```

## 与 Smart-Config-Kit 的关系

本项目 **不是 Smart-Config-Kit 的 Fork**，也不复制它的规则体系。

Smart-Config-Kit 负责：

- 节点清洗与地区识别
- 区域策略组
- 业务策略组
- Rule Provider / fused rules
- DNS / Sniffer / Fallback

mihomo-policy-kit 负责：

- 获取机场原始订阅
- 调用不同 Provider 生成策略配置
- 添加用户自己的域名 / IP / CIDR 规则
- 用逻辑目标名隔离不同 Provider 的策略组命名差异
- 做结构校验、节点保护、Mihomo 校验
- 生成可发布的最终订阅
- 后续扩展多客户端输出

当前 Provider：

- `smart-config-kit`：使用 `OpenClash/OpenClash(mihomo).sh`，即 Normal / 非 Smart 版本

上游项目：<https://github.com/IvanSolis1989/Smart-Config-Kit>

## 当前支持

### 输入

- 本地 Mihomo YAML
- 远程机场订阅 URL（推荐通过 `MPK_SOURCE_URL` 环境变量注入）
- 自定义 `.list` 规则文件

### 输出

- `dist/mihomo.yaml`（仅 Mihomo YAML）
- V0.2 Publisher：`builds/<build-id>/mihomo.yaml`（immutable 版本）、共享 `current` / `previous` symlink 状态指针（`current` 的原子替换同时切换所有 token）、
  `/sub/<token>/mihomo.yaml` 稳定 HTTPS 订阅 URL（多 Token，可独立吊销）

### 当前主要兼容客户端

- Clash Party
- Clash Verge Rev
- Nikki
- Clash Meta / ClashMi 等 Mihomo 客户端

只要客户端能直接消费标准 Mihomo YAML，就属于当前目标范围。

## 开发环境

主要开发环境为 **Windows + PowerShell 7**。Bash Provider（Smart-Config-Kit 转换脚本）
需要 Bash 运行时，Windows 上请使用 Git Bash 或 WSL2。

依赖：

| 工具 | 用途 | 说明 |
| --- | --- | --- |
| Ruby 3.x | 构建 / Overlay / 测试 | 需要 `yaml`、`psych` |
| Bash 4+ | Provider wrapper | Git Bash 或 WSL2 |
| curl | 订阅下载 / 上游兜底下载 | Windows 10+ 自带 |
| mihomo | 可选：配置测试 | 存在时自动执行 `mihomo -t` |

> 注意：**Provider 仍然是 Bash 脚本**，不要为了“Windows 能跑”把它改写成 PowerShell。
> CLI 入口（Ruby）跨平台，Provider 实现保持 Bash，这是两个不同的关注点。

## 快速开始

### 1. 安装依赖

```powershell
pwsh --version   # PowerShell 7+
ruby --version   # Ruby 3.x
bash --version   # Git Bash / WSL2
```

### 2. 准备配置

```powershell
Copy-Item config/config.example.yaml config/config.yaml
```

不要把机场真实订阅 URL 提交到公开仓库。

推荐使用环境变量：

```powershell
$env:MPK_SOURCE_URL = 'https://your-airport.example/subscription/token'
```

### 3. 可选：提前下载 Smart-Config-Kit Normal 脚本

GitHub 慢的时候建议放本地：

```text
vendor/OpenClash(mihomo).sh
```

如果本地不存在，构建器才会自动从官方仓库下载。

> 只允许 **Normal / 非 Smart** 版本（`oc-normal`）。`VERSION_TAG` 不含 `oc-normal`
> 的上游脚本会被拒绝，避免误用 Smart / LightGBM。

### 4. 构建

```powershell
ruby scripts/build.rb config/config.yaml [upstream|china_compat]
```

或通过 CLI：

```powershell
bash bin/mpk build config/config.yaml [upstream|china_compat]
```

生成：

```text
dist/mihomo.yaml
```

构建日志会记录 `source proxies`、`provider 后 proxies`、`final proxies` 数量，
并执行结构校验；若本机存在 `mihomo`，会自动运行 `mihomo -t -f dist/mihomo.yaml`。

### 5. 校验

```powershell
ruby scripts/validate.rb dist/mihomo.yaml
```

### 6. 诊断

```powershell
bash bin/mpk doctor
```

### 7. 发布（V0.2）

把构建并校验通过的 `dist/mihomo.yaml` 发布为稳定 HTTPS 订阅：

```powershell
# publish root（默认 ./runtime，已被 gitignore）
$env:MPK_PUBLISH_ROOT = 'F:\git\mihomo-policy-kit\runtime'

# 发布（原子切换 current/previous；校验失败不会改变 current）
bash bin/mpk publish dist/mihomo.yaml

# 查看状态
bash bin/mpk publisher status

# 回滚（current/previous 互换）
bash bin/mpk rollback
```

多设备 Token 稳定 URL（token 公开视图是原子替换的稳定 symlink，生产部署以 Linux + Nginx 为目标；Windows 仅运行不依赖 symlink 的通用检查）：

```powershell
# 一次性输出完整订阅 URL
$env:MPK_PUBLIC_BASE_URL = 'https://sub.example.com'
bash bin/mpk token create phone
bash bin/mpk token list       # 只显示 name + fingerprint
bash bin/mpk token revoke phone
```

详细说明见 `docs/publisher.md`；Nginx HTTPS 示例见 `deploy/nginx/`，systemd / cron
部署见 `deploy/systemd/`。

> **Token 是 bearer secret**：`/sub/<token>/mihomo.yaml` 中的 token 必须走 HTTPS，
> Nginx access log 不得记录该 URI（示例已关闭）。

## 自定义规则

`rules/custom.list`：

```text
# AI
DOMAIN-SUFFIX,experientiallabs.ai,ai
DOMAIN,api.example.com,ai

# 指定美国策略
DOMAIN-SUFFIX,example-us.com,us

# IP / CIDR
IP-CIDR,8.8.8.8/32,global,no-resolve
IP-CIDR,192.168.0.0/16,direct,no-resolve

# 拦截
DOMAIN-SUFFIX,ads.example.com,reject
```

这里的最后一个目标不是直接写 `🤖 AI 服务`、`🇺🇸 美国节点`，而是逻辑目标：

```text
ai
us
hk
sg
jp
global
direct
reject
```

Smart-Config-Kit Provider 会把它们映射为实际策略组，例如：

```text
ai     -> 🤖 AI 服务
us     -> 🇺🇸 美国节点
global -> 🌍 全球节点
direct -> DIRECT
reject -> REJECT
```

以后接入其他分流项目时，只需要换映射，不需要重写你的规则。

自定义规则会插入到最终 `rules` 的**最前面**，因此优先级最高；逻辑 target 映射后
必须指向真实存在的策略组或 Mihomo 内建动作（`DIRECT` / `REJECT` / `REJECT-DROP` / `PASS`），
否则构建失败。

## 公共补丁

构建时会自动应用以下公共补丁（可在 `config/config.yaml` 中关闭）：

- 删除顶层 `global-client-fingerprint`（避免机场指纹覆盖客户端设置）
- **保留**每个节点自身的 `client-fingerprint`（禁止粗暴递归删除）
- 设置 `geodata-loader: memconservative`（降低低内存设备加载 GeoIP 数据的内存开销）

### 两套 DNS Profile

`config/config.yaml` 的 `patches.dns_profile`：

| 值 | 行为 | 适用 |
| --- | --- | --- |
| `upstream`（默认） | **完全保留** Smart-Config-Kit 生成的 DNS，不做任何覆盖 | 通用桌面 / 手机 / 大部分 Mihomo 客户端 |
| `china_compat` | 使用国内 bootstrap / DoH（223.5.5.5 / 119.29.29.29 等），删除境外 bootstrap 特例（jsdelivr / github / fastly 等） | 部分 OpenWrt / Nikki 中境外 DoH bootstrap 死锁的环境 |

`china_compat` 是显式选择，不会偷偷修改所有构建结果。

## 安全

**不要公开最终生成的 `dist/mihomo.yaml`。** 它可能包含节点服务器地址、UUID / 密码、
Reality 参数等机场专属信息。

### Secret 注入

- 真实订阅 URL 通过环境变量 `MPK_SOURCE_URL` 注入（build.rb 从该变量读取）
- 构建日志中 URL 一律显示为 `$MPK_SOURCE_URL` 占位符，**绝不打印真实值**
- 下载失败异常也不包含真实 URL / Token
- 真实输出位于 gitignored 的 `dist/`

### 禁止提交

- 真实机场订阅 URL / Token
- 节点 UUID、密码、私钥
- 生成后的 `dist/mihomo.yaml`
- 私有 HTTPS 发布 Token
- Publisher runtime（`runtime/`：builds / current / previous / token-state / public token tree）

V0.2 安全要点：

- 订阅 token 位于 URL path，是 bearer secret；Nginx access log 必须关闭
  （示例 `deploy/nginx/mihomo-subscription.conf.example` 已配置 `access_log off` + `log_not_found off`）
- 客户端 URL 中的完整高熵 token 与文件系统公开路径一致（`public/sub/<token>/`），静态 Nginx 可直接命中
- 完整 token 只在 `token create` 一次性输出；`token list` 只显示 fingerprint
- `token-state/` 是私有敏感数据（含完整 token，用于精确吊销），禁止提交仓库，备份须加密限权
- 生产发布目标为 Linux + Nginx；HTTPS 是必需条件

### 本地真实订阅 Smoke Test

```powershell
$env:MPK_SOURCE_URL = 'https://your-airport.example/subscription/token'
pwsh -File scripts/smoke_test.ps1
```

脚本会：
- 从 `MPK_SOURCE_URL` 读取真实订阅（日志不打印 URL）
- 分别执行 `upstream` 与 `china_compat` 两套构建，并保留两份明确命名产物：
  - `dist/mihomo.yaml`（upstream）
  - `dist/mihomo-china-compat.yaml`（china_compat）
- 记录 source / provider / final 的 proxies 数量
- 本机有 `mihomo` 时执行 `mihomo -t`
- 产物写入 gitignored 的 `dist/`

> 不要在 GitHub Actions 中配置真实机场 Secret。

## Provider 可靠性

`providers/smart-config-kit/provider.sh` 是 Provider wrapper，行为：

1. 优先使用本地 `vendor/OpenClash(mihomo).sh`，不存在才从官方仓库下载
2. 校验 `VERSION_TAG` 必须包含 `oc-normal`，否则拒绝执行
3. 兼容上游对 `/usr/share/openclash/log.sh` 的运行时依赖（替换为内置 `LOG_OUT`）
4. Provider 执行失败时构建失败，不会误报成功
5. 转换后节点数量为 0 且源节点 > 0 时，构建失败（节点保护）

测试见 `test/providers/test_smart_config_kit.sh`（离线 fixture，不依赖真实机场与网络）。

## 测试

```powershell
# Ruby 单元测试（Overlay / BuildHelpers / Publisher）
ruby test/test_overlay.rb
ruby test/test_build_helpers.rb
ruby test/publisher/test_build_id.rb
ruby test/publisher/test_token.rb
ruby test/publisher/test_publisher.rb
ruby test/publisher/test_publisher_secret.rb
ruby test/publisher/test_publisher_fault_injection.rb
ruby test/publisher/test_publisher_crash_recovery.rb
ruby test/publisher/test_publisher_staging_atomicity.rb
ruby test/publisher/test_nginx_example.rb

# Publisher integration（真实 token URL / 共享 current 原子指针；Linux 运行）
ruby test/publisher/test_publisher_integration.rb

# Provider wrapper 离线测试（需要 bash）
bash test/providers/test_smart_config_kit.sh

# 离线端到端构建测试（需要 bash，使用 fixture 不走网络）
ruby test/test_e2e_offline.rb
```

CI（`.github/workflows/ci.yml`）包含：

- **Linux**：Ruby 语法 + 单元测试（含 Publisher）、Bash 语法、Provider fixture 测试、离线 E2E、
  Publisher integration（原子 active 指针 / token URL）、Nginx 语法（有 nginx 时 `nginx -t`）、doctor
- **Windows**：PowerShell 语法 + task-picker 回归、Ruby 通用逻辑测试（含 Publisher 纯逻辑）

## 项目结构

```text
mihomo-policy-kit/
├── bin/
│   └── mpk
├── config/
│   ├── config.example.yaml
│   └── groups.smart-config-kit.yaml
├── docs/
│   ├── architecture.md
│   └── custom-rules.md
├── lib/
│   ├── build_helpers.rb
│   ├── overlay.rb
│   └── publisher/
│       ├── build_id.rb
│       ├── runtime.rb
│       ├── token.rb
│       ├── validator.rb
│       └── publisher.rb
├── providers/
│   └── smart-config-kit/
│       └── provider.sh
├── rules/
│   └── custom.example.list
├── deploy/
│   ├── nginx/
│   │   ├── mihomo-subscription.conf.example
│   │   └── robots.txt.example
│   └── systemd/
│       ├── mpk-publisher.service
│       ├── mpk-publisher.timer
│       └── mpk-publisher.cron.example
├── scripts/
│   ├── build.rb
│   ├── validate.rb
│   ├── publisher.rb
│   ├── smoke_test.ps1
│   ├── codex-next.ps1
│   └── codex-next.sh
├── test/
│   ├── test_overlay.rb
│   ├── test_build_helpers.rb
│   ├── test_e2e_offline.rb
│   ├── publisher/
│   │   ├── test_build_id.rb
│   │   ├── test_token.rb
│   │   ├── test_publisher.rb
│   │   ├── test_publisher_secret.rb
│   │   ├── test_publisher_fault_injection.rb
│   │   ├── test_publisher_crash_recovery.rb
│   │   ├── test_publisher_staging_atomicity.rb
│   │   ├── test_publisher_integration.rb
│   │   ├── test_nginx_example.rb
│   │   └── fixtures/
│   └── providers/
│       ├── test_smart_config_kit.sh
│       └── fixtures/
├── vendor/
│   └── .gitkeep
├── dist/
│   └── .gitkeep
└── runtime/
    └── .gitkeep   # Publisher 运行目录（gitignored，builds/current/previous/token-state 不入库）
```

## 路线图

### v0.1

- [x] Smart-Config-Kit Normal Provider
- [x] 本地 Provider 脚本优先，GitHub 下载兜底
- [x] 自定义规则 Overlay
- [x] 逻辑策略组映射
- [x] 删除顶层 `global-client-fingerprint`，保留节点级 fingerprint
- [x] `geodata-loader: memconservative`
- [x] 两套 DNS Profile（upstream / china_compat）
- [x] 节点数量保护
- [x] Mihomo 配置校验
- [x] 离线端到端 fixture 测试
- [x] Windows / Ruby 跨平台命令发现
- [x] 真实订阅 smoke 入口

### v0.2

- [x] 私有 HTTPS 订阅发布器（Publisher：publish / status / rollback / token）
- [x] immutable builds + current / previous 状态指针
- [x] 一键回滚（只切换状态指针，不改 builds）
- [x] 多 Token 稳定 URL（`/sub/<token>/mihomo.yaml`），可独立吊销
- [x] Secret 安全（token 不进日志 / Nginx access log 关闭）
- [x] Nginx HTTPS 静态发布示例
- [x] systemd timer / cron 自动 build -> publish 示例
- [x] Publisher Linux 集成测试 + Windows Ruby 纯逻辑测试
- [ ] Provider 版本锁定
- [ ] GitHub Actions / 自建 CI 发布

### v0.3+

- [ ] ACL4SSR Provider
- [ ] 其他社区分流 Provider
- [ ] Stash 输出
- [ ] Loon / Surge / Shadowrocket 输出
- [ ] sing-box 输出

> 注意：Stash / Loon / Surge / sing-box 等多客户端输出属于后续阶段（#4），v0.1 只输出 Mihomo YAML。

## License

MIT。

Smart-Config-Kit 及其规则、脚本版权归其原作者和相应上游项目所有。本项目运行时调用上游产物，不将其源码作为本项目自身代码重新发布。
