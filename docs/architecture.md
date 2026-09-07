# Architecture

## 1. 目标

mihomo-policy-kit 不把某一个分流项目写死在主程序里，而是把整个流程拆成四层：

```text
Source -> Provider -> Overlay -> Output
```

其中：

- **Source**：机场原始订阅
- **Provider**：Smart-Config-Kit、ACL4SSR 或未来其他分流方案
- **Overlay**：用户自定义规则、DNS 与公共补丁
- **Output**：Mihomo / Stash / Surge / Loon / sing-box 等客户端产物

v0.1 只实现：

```text
Mihomo Source
  -> Smart-Config-Kit Normal
  -> Custom Overlay
  -> Mihomo YAML
```

## 2. 为什么不 Fork Smart-Config-Kit

Smart-Config-Kit 自身已经有清晰的规则源、业务组、区域组和多端生成体系。我们的需求是在它之外增加：

- 私有机场订阅输入
- 用户自己的高优先级规则
- 多 Provider 兼容
- 构建校验
- 私有订阅发布

如果直接长期 Fork，上游每次更新都需要手工合并数千行脚本，而我们的功能又大多属于外层能力。

因此当前设计是：

1. 下载或读取官方 `OpenClash(mihomo).sh`
2. 只移除它对 OpenClash 日志函数的运行时依赖
3. 直接对临时机场 YAML 执行上游转换
4. 转换完成后再执行本项目 Overlay

## 3. Provider 接口

当前 Provider：

```text
providers/smart-config-kit/provider.sh
```

输入：

```text
一个可写的 Mihomo YAML 文件路径
```

行为：

```text
读取官方 Normal 脚本
    ↓
本地 vendor 优先
    ↓
不存在则 GitHub 下载
    ↓
确认 VERSION_TAG 为 oc-normal
    ↓
替换 OpenClash LOG_OUT 依赖（任意行位置均可兼容）
    ↓
执行官方转换
```

输出仍然写回输入 YAML。

**限制**：v0.1 只允许 `oc-normal`（Normal / 非 Smart）版本；`mihomo-smart` 与
LightGBM 版本会在 `VERSION_TAG` 校验阶段被拒绝。

未来 Provider 只要满足相同契约，就可以接入主构建流程。

## 3.1 Windows 执行

Provider 是 Bash 脚本，Windows 上需要 Git Bash 或 WSL2 提供 `bash`。

Ruby 构建层在 Windows 上调用 Bash 时：

- 会把 Windows 路径（`F:\...` / `C:/...`）转换为当前 Bash 可解析的 POSIX 路径
  （优先 `wslpath`，其次 `cygpath`；两者都不可用则原样返回并给出明确错误）
- 通过 `bash -c` 内联环境变量传递本地上游路径，避免跨进程 env 传递在
  Windows -> WSL 场景下丢失
- Bash 完全缺失时，Provider 阶段应给出明确错误，而不是难懂的堆栈

不要把 Bash Provider 改写成 PowerShell。

## 4. 逻辑策略目标

用户规则不应该绑定 Provider 的真实策略组名字。

错误的长期设计：

```text
DOMAIN-SUFFIX,example.com,🤖 AI 服务
```

推荐：

```text
DOMAIN-SUFFIX,example.com,ai
```

然后由：

```text
config/groups.smart-config-kit.yaml
```

映射：

```text
ai -> 🤖 AI 服务
```

如果未来接入另一套 Provider：

```text
ai -> AI
```

用户自己的规则不需要修改。

## 5. Overlay 顺序

自定义规则会插入到最终 `rules` 最前面：

```text
Custom Rules
    ↓
Provider Rules
    ↓
MATCH / Final
```

Mihomo 使用首条命中规则，因此用户规则拥有最高优先级。

自定义规则中的逻辑 target 必须能映射到真实策略组或 Mihomo 内建动作，
否则构建失败（`unknown logical target` / `required target missing`）。

## 6. 节点保护

构建器会记录原始订阅节点数量。

如果：

```text
source proxies > 0
```

而 Provider 转换后：

```text
proxies == 0
```

构建立刻失败，不生成新订阅。

这用于防止 YAML 工具差异、上游变化或转换异常导致整份节点池被清空。

## 7. 公共补丁

### 7.1 client-fingerprint

- 删除顶层 `global-client-fingerprint`（可配置关闭）
- **保留**每个节点自身的 `client-fingerprint`
- 禁止粗暴递归删除整个文档的 fingerprint 字段

### 7.2 geodata-loader

默认设置 `geodata-loader: memconservative`，降低低内存设备加载 GeoIP 数据时的
内存开销。可在 `config/config.yaml` 的 `patches.geodata_loader` 中改为
`standard` 或 `upstream`（`upstream` 表示完全保留 Provider 的值）。

## 8. DNS Profile

v0.1 提供两种模式。

### upstream

完全保留 Provider 生成的 DNS。

适合普通桌面 / 手机 / 通用 Mihomo 客户端，默认使用此模式。

### china_compat

将 resolver bootstrap 改为国内 IP / DoH（223.5.5.5 / 119.29.29.29 / 120.53.53.53），
并删除 `nameserver-policy` 中以下境外 bootstrap 特例（存在才删）：

- `geosite:geolocation-!cn`
- `+.jsdelivr.net`
- `+.github.com`
- `+.githubusercontent.com`
- `+.githubassets.com`
- `+.fastly.net`

主要用于某些 OpenWrt / Nikki 环境里境外 DoH 出现 bootstrap 死锁的情况。

该模式只作为显式 Overlay，不应该偷偷修改所有构建结果；其他与 DNS 无关的字段
（例如 `enhanced-mode`、未列入删除名单的 policy）会被保留。

## 9. 输出与发布

`dist/` 永远视为敏感产物目录，不提交 Git。

v0.1 输出：

```text
dist/mihomo.yaml
```

V0.2 已实现 Publisher（见 `docs/publisher.md`）：

```text
builds/<build-id>/mihomo.yaml + metadata.json   # immutable 版本
current/mihomo.yaml                            # 当前成功版本视图
previous/mihomo.yaml                           # 切换前版本视图
public/sub/<token>/ -> ../../current           # token 视图（目录 symlink，名 = 完整 token）
token-state/<fingerprint>.json                 # token 元数据（私有敏感，含完整 token）
```

对客户端暴露稳定 URL：

```text
/sub/<token>/mihomo.yaml
```

- 只有新构建完整通过校验后才切换 `current`。
- 发布失败 / 校验失败 / rollback 失败都不会让 current 指向半成品。
- 多 token 通过目录 symlink 跟随统一 current，promotion / rollback 对所有 token 一致。
- 生产运行目标是 Linux + Nginx；Windows 只跑 Ruby 纯逻辑 / 单元测试。

## 10. 安全

- 真实订阅 URL 只通过 `MPK_SOURCE_URL` 环境变量注入
- 构建日志与异常消息不打印真实 URL / Token
- 公开仓库不提交 `dist/`、`vendor/` 上游脚本、`config/config.yaml`、`rules/custom.list`
- V0.2：订阅 token 是 bearer secret，位于 URL path；Nginx access log 不得记录
  token-bearing URI（`access_log off` + `log_not_found off`）
- V0.2：publish root（`runtime/`）全部被 `.gitignore` 排除，build / token /
  发布状态不进入公开仓库
- V0.2：完整 token 只在 `token create` 一次性输出；`token list` 只显示 fingerprint

## 11. 测试策略

- Ruby 单元测试：`test/test_overlay.rb`、`test/test_build_helpers.rb`
- Publisher 纯逻辑：`test/publisher/test_build_id.rb`、`test/publisher/test_token.rb`
- Publisher 主流程：`test/publisher/test_publisher.rb`（publish / rollback / 幂等 / 失败路径）
- Secret 回归：`test/publisher/test_publisher_secret.rb`（`VERY_SECRET_PUBLISH_TOKEN_123`）
- 故障注入 / 崩溃自愈回归：`test/publisher/test_publisher_fault_injection.rb`、
  `test/publisher/test_publisher_crash_recovery.rb`（promote/rollback 失败不破坏 current/previous）
- Nginx 示例确定性文本回归：`test/publisher/test_nginx_example.rb`
- Publisher Linux 集成：`test/publisher/test_publisher_integration.rb`（symlink / atomic rename / 真实 token URL 路径）
- Provider wrapper 离线测试：`test/providers/test_smart_config_kit.sh`（fake upstream，不出网）
- 离线端到端：`test/test_e2e_offline.rb`（fixture -> provider -> overlay -> validate -> output）
- 真实订阅 smoke：`scripts/smoke_test.ps1`（人工执行，不进入 CI）
