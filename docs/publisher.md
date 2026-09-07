# Publisher（V0.2）

V0.2 把 V0.1 构建并校验通过的 `dist/mihomo.yaml` **安全发布为稳定的 HTTPS 订阅 URL**，
并提供版本留存（immutable builds）、current / previous 状态指针、一键回滚、多 Token
按设备/场景独立吊销能力。

## V0.1 build 与 V0.2 publish 的边界

- **build**（V0.1）：获取机场订阅 -> Provider 转换 -> Overlay -> 校验 -> 输出 `dist/mihomo.yaml`。
- **publish**（V0.2）：**只接受已经存在的、校验通过的 Mihomo YAML 产物**，把它发布为
  `builds/<build-id>/` immutable 版本，并原子切换 `current` / `previous`。

publish 不会重新构建或改写配置内容；发布前仍会做最小安全校验（存在、非空、YAML 可解析、
`proxies > 0` 或存在 `proxy-providers`、`proxy-groups` / `rules` 满足校验要求、本机存在
mihomo 时执行 `mihomo -t`）。任何发布失败都不会改变线上 current。

## 生产运行环境

- **生产发布运行目标：Linux**（VPS / NAS / Linux Server + Nginx）。
- Windows + PowerShell 7 仍是主要开发环境：Ruby 纯逻辑与单元测试可在 Windows 运行。
- Nginx / systemd 是 Linux 生产部署组件；Linux 上覆盖 Publisher 的共享 symlink 状态机与 token 视图；Windows 保留不依赖 symlink 权限的通用 Ruby 检查。

## publish root

默认 `./runtime`（已被 `.gitignore` 排除），可通过环境变量覆盖：

```text
MPK_PUBLISH_ROOT
MPK_PUBLIC_BASE_URL
```

生产部署推荐：

```text
/var/lib/mihomo-policy-kit
```

运行目录布局：

```text
<publish-root>/
  builds/<build-id>/mihomo.yaml + metadata.json   # immutable 版本；staging 后原子进入
  states/<state-id>/{state.json,current,previous} # immutable current/previous pair
  active -> states/<state-id>                     # 唯一公开 state pointer
  public/
    sub/<token>/ -> ../../active/current          # 稳定 token symlink，共享 active
  token-state/<fingerprint>.json                 # token 元数据（私有敏感，含完整 token 以便吊销）
```

- immutable state-set 同时保存 `current` / `previous`；`active` 是唯一公开 pointer，tmp symlink +
  rename 单点原子替换。所有 token 稳定指向 `active/current`，`current` 永远指向完整校验通过的 build。
- build 目录发布成功后视为 immutable（rollback 只切换状态指针，不重建/修改 builds）。
- YAML 与 metadata 会先完整写到隐藏 `.build-staging-*`，再一次性 rename 进入 `builds/<build-id>`；
  崩溃最多留下 staging，绝不会作为有效 build 出现在 `list_builds`。
- 任何真实 build、token、token metadata、发布状态都不会提交到公开仓库。

### build-id

格式：

```text
YYYYMMDDTHHMMSSZ-<sha256 前 12 hex>-<随机 4 位>
```

- UTC 时间可排序 / 可识别
- 内容 SHA256 摘要帮助识别重复发布
- 随机后缀避免同秒冲突
- 不含任何 Secret

## 命令行

```text
./bin/mpk publish <mihomo.yaml>     # 发布并原子切换 current/previous
./bin/mpk publisher status          # 查看 current / previous / builds / tokens
./bin/mpk rollback                  # 一键回滚（current/previous 互换）
./bin/mpk token create <name>       # 创建高熵 token，输出一次性完整订阅 URL
./bin/mpk token list                # 只显示 name + fingerprint，不打印完整 token
./bin/mpk token revoke <name>       # 吊销指定 token，不影响其他 token
```

等价 Ruby 入口：

```text
ruby scripts/publisher.rb <子命令>
```

环境变量：

| 变量 | 说明 |
| --- | --- |
| `MPK_PUBLISH_ROOT` | publish root，默认 `./runtime` |
| `MPK_PUBLIC_BASE_URL` | 用于 `token create` 输出完整订阅 URL，如 `https://sub.example.com` |
| `MPK_CONFIG` | 可选，复用 Overlay 校验的 config 文件 |

## publish / rollback 语义

- 第一次发布：建立 `current`，`previous` 不存在。
- 第二次发布：`current` = 新版本，`previous` = 旧版本。
- 发布相同内容（SHA256 相同）时幂等：不产生重复版本，不改变 current。
- 校验失败：current / previous 完全不变。
- `rollback`：`current` 与 `previous` 互换（A -> B -> rollback -> B/A 互换），再次
  rollback 可切回。rollback 只切换状态指针，不修改 builds 内容。
- 任何失败路径都不会让 current 指向半成品 / 缺失路径。

## Token 稳定 URL

稳定订阅 URL 固定为：

```text
https://<host>/sub/<token>/mihomo.yaml
```

- Token 使用 `SecureRandom`（CSPRNG）生成，至少 256 bit 随机熵，URL-safe，不使用可预测自增 ID。
- `public/sub/<完整 token>` 是稳定目录 symlink，指向 `../../active/current`：客户端 URL 中的高熵 token
  与文件系统公开路径完全一致，静态 Nginx 可直接命中。promotion / rollback 先完整构造 immutable
  `{current, previous}` state-set，再只原子替换一次 `active`，所以所有 token 同时读到旧或新完整配置。
- `token list` 默认只显示 name + fingerprint（SHA256 前 16 hex），不打印完整 token。
- `revoke <name>` 读取私有 token-state 拿到完整 token，删除对应的 `public/sub/<token>` 公开
  视图，不影响其他 token。
- 完整 token 只在 `token create` 的本地结果中一次性显示。
- `token-state/` 是私有敏感数据：其中记录完整 token（filesystem 视图管理需要精确吊销），
  必须与 `builds/` 同等对待，禁止提交仓库、禁止进入备份明文日志；丢失后只能重新 create。

## 安全（P0）

- **订阅 token 位于 URL path，属于 bearer secret**。
- Nginx 示例对 token-bearing location 关闭 access log（`access_log off`）与
  `log_not_found off`；无效 token 一律 404，不使用可枚举的详细错误。
- CDN / WAF / 上游反代 / 全局代理日志也可能记录完整 URI，部署者必须同样关闭或脱敏。
- 真实 build、token、metadata、发布状态不提交仓库。
- 普通 publish / status / rollback / exception 不输出完整 token。
- 测试使用 `example.invalid` 与固定假 token（`VERY_SECRET_PUBLISH_TOKEN_123`）。

## 部署

- Nginx HTTPS 静态发布示例：`deploy/nginx/mihomo-subscription.conf.example`
  （`nginx -t` 可用时做语法验证，无 nginx 时由确定性文本测试兜底）。
- systemd service + timer 示例：`deploy/systemd/mpk-publisher.service` / `.timer`
  （`MPK_SOURCE_URL` 等凭据放在权限受限 EnvironmentFile，建议 0600，unit 文件只含占位符）。
- cron 替代示例：`deploy/systemd/mpk-publisher.cron.example`。
- 正常发布只切 current，不需要 reload Nginx。

## backup / recovery

- 每个 build 目录是完整的、immutable 的版本；`builds/` 就是版本历史。
- 恢复任意历史版本：用 `MPK_PUBLISH_ROOT` 下对应 `builds/<build-id>/mihomo.yaml`
  作为 artifact 重新 `publish`，或直接改状态指针（谨慎）。
- 建议定期备份 `builds/`（版本历史）与 `token-state/`。`token-state/` 含完整 token，
  属于敏感数据：备份文件本身必须加密 / 限权；若丢失 token-state 需重新 create token
  并更新客户端。

## 尚未实现

- V0.3：Provider 兼容层（第二套分流方案）
- V0.4：多客户端输出（Stash / Loon / Surge / sing-box）
