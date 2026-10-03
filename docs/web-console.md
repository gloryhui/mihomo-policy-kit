# Web 控制台（V0.5）

控制台把日常流程集中在浏览器：**添加订阅源 → 刷新 → 筛选节点 → 构建 → 发布 → 复制设备订阅地址**。
现有 CLI 可以独立使用。控制台管理订阅和配置；流量仍由 Clash Party、Clash Verge Rev、Nikki 等设备客户端处理。

## 本机开发 / 试用

依赖 Ruby 3.2+（推荐 Ruby 3.3）、Node.js 22.12+、Ruby native extension 编译工具；Smart-Config-Kit 还需要 Bash。
Windows RubyInstaller 需要安装 MSYS2 / DevKit；只有 Ruby 可执行文件的安装可能无法编译 Puma/nio4r。
也可以在 WSL2 中运行 Ruby API，在 Windows 上运行前端。ACL4SSR Provider 使用 Ruby，可避免 Provider 的 Bash 依赖。

仓库根目录安装后端依赖：

```powershell
bundle install
# 为本次试用生成随机 master key，不打印值；重启时必须继续使用同一把 key。
$env:MPK_MASTER_KEY = ruby -rsecurerandom -e 'print SecureRandom.hex(32)'
ruby scripts/web.rb
```

另开一个 PowerShell，安装并启动前端：

```powershell
npm --prefix web ci
npm --prefix web run dev
```

浏览器打开 `http://127.0.0.1:5173/admin/`。Vite 通过同源 `/api/` 转发到 `127.0.0.1:9292`。
开发默认使用 gitignored `runtime/mpk.db` 与 `runtime/cache/profile-builds/`，不需要真实机场订阅即可导入脱敏 fixture 验证。
master key 只在服务环境变量中传入，不写入数据库或仓库；丢失 key 后，已有源和节点无法解密。生产需在外部安全存储中持久保存它。

Windows 可验证 Source/节点/Profile/API/构建；正式 Publisher 依赖 Linux symlink 原子语义，推荐在 Linux 部署。

## 操作步骤

1. **订阅源**：添加名称和 HTTPS 订阅地址，或导入本地 Mihomo YAML / base64 URI 列表。地址和文件内容均加密保存，列表只显示已配置。
2. 给不同源设置不同 `name_prefix`，例如 `主源 | ` 和 `备用 | `，防止重名。倍率可设为 `1` / `2`，留空表示不限；未知倍率可保留或排除。
3. 点击 **刷新**，获取节点。刷新失败保留旧库存；本次未再出现的节点标记不可用，保留选择历史。MVP 采用手动刷新，`refresh_interval` 为保留设置，尚未自动调度。
4. **构建配置**：新建 Profile，关联一个或多个源，选 Smart-Config-Kit Normal / ACL4SSR、上游 DNS / 国内兼容 DNS。
5. **节点池**：先选 Profile，再筛选、分页、批量设置自动/强制保留/排除。选择只影响该 Profile。自动遵循源启用状态、可用性和倍率规则；include 可越过源启用/倍率限制，exclude 始终排除，不可用节点始终不入选。
6. **构建配置 → 构建**：先过滤、合并，再调用现有 Provider / Overlay / 校验 / Output。构建独立留存，不覆盖以前成功的文件；有 `mihomo` 时执行 `mihomo -t`。本批次 Web 构建仅输出 Mihomo YAML。
7. **发布**：选择一个成功 Build 发布。Publisher 保留 current/previous，支持回滚。设备 Token 地址仅在创建时显示一次；复制到客户端，后续更新不必换地址。

**多个 Profile 共用一个 Publisher current**：发布任何 Profile 的 Build 会更新所有设备 Token 的配置。Profile 不代表各自独立的订阅频道；不要据此为不同设备发布不同内容。
普通 build/refresh 请求同步完成，页面显示操作状态，服务按锁串行执行写操作。构建可能需要等待上游下载，API 不提供实时日志。

## Linux 正式部署

使用能访问订阅源、GitHub/rule-provider 的 Linux VPS、家庭服务器或 NAS Linux 环境。需要域名、HTTPS 证书、Ruby/Bash/curl、Nginx；推荐安装 `mihomo` 做核心验证。
应用代码放 `/opt/mihomo-policy-kit`；私有数据放 `/var/lib/mihomo-policy-kit`。部署依赖与静态资源：

```bash
bundle install
npm --prefix web ci
npm --prefix web run typecheck
npm --prefix web run build
```

创建 `mpk` 系统用户并赋予私有数据目录写权限、应用目录读权限。Nginx worker 加入 `mpk` 组以读取公开订阅和穿过数据根目录（目录 `0750`，公开配置 `0640`）；
SQLite 文件固定 `0600`，token-state/ 应额外限权 `0700`。服务使用 `UMask=0027` 以兼容 Nginx 读取 public/ 指向的 builds/。
不要通过全目录 `chmod 777` 解决权限问题。为 `/etc/mihomo-policy-kit/web.env` 设置 root 所有和 `0600`，仅写外部配置：

```text
RACK_ENV=production
MPK_EXTERNAL_AUTH=nginx
MPK_PUBLIC_BASE_URL=https://example.invalid
MPK_DATA_ROOT=/var/lib/mihomo-policy-kit
MPK_DB_PATH=/var/lib/mihomo-policy-kit/mpk.db
MPK_PUBLISH_ROOT=/var/lib/mihomo-policy-kit
MPK_WEB_PORT=9292
MPK_MASTER_KEY=<在服务端生成并安全保存的32字节hex或base64 key>
```

部署时替换所有示例占位值。使用 `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'` 在私有服务器生成 master key，不把输出贴到 Issue/PR/日志。
用 `htpasswd` 创建 `/etc/nginx/mpk.htpasswd`，配置证书，再按
[`deploy/nginx/mpk-web-console.conf.example`](../deploy/nginx/mpk-web-console.conf.example) 安装 Nginx server 配置。
认证保护 `/admin/` 和 `/api/`；`/sub/` 使用高熵 Token，不加 Basic Auth，不记录访问 URI。
Puma 固定只监听 `127.0.0.1`，生产还要求来自认证反代的身份头；Nginx 必须覆盖客户端身份头。
不要直接开放 API 端口，或把整个数据根目录设为 web root。写 API 需要同源请求和 `X-MPK-Request: 1`，拒绝跨站表单。

安装 [`deploy/systemd/mpk-web.service.example`](../deploy/systemd/mpk-web.service.example) 为 service，检查 Ruby 可执行路径与 Bundler gem 安装路径适用于 `mpk` 用户，再执行：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mpk-web
sudo nginx -t
sudo systemctl reload nginx
```

浏览器打开 `https://你的域名/admin/`，使用 Nginx 管理密码登录。常规发布 / 回滚无需 reload Nginx。
示例不会自动修改宿主机 Nginx、申请证书或部署服务。

## API、存储与兼容性

API 前缀 `/api/v1/`，包括 dashboard、health、sources CRUD/refresh、nodes 查询/selection、profiles CRUD/build、builds、publisher status/publish/rollback/tokens。
错误统一为 `{ "error": { "code": "...", "message": "安全摘要" } }`，失败详情不回显输入或底层异常。
Node 查询支持 `profile_id/q/source_id/region/max_multiplier/unknown_multiplier/available/page/per_page`，每页最多 200。
单节点或批量选择必须提供 `profile_id` 和 `selection`，批量最多 200 个节点；验证全部通过后事务写入。

Sequel migration 版本管理 SQLite schema，启用 foreign_keys、WAL、5000ms busy timeout；AES-256-GCM 加密原始源内容和节点 proxy JSON。
UI DTO 使用字段白名单，不返回密码、UUID、私钥或加密密文；URL 不回显。稳定 fingerprint 忽略 name、包含核心连接与协议字段，按 Source 隔离。
库存仅接受可实体化的 proxies，不递归获取 unresolved proxy-providers；格式错误或部分不支持 URI 使刷新整体失败。
旧 CLI 的 `source:` 行为保持兼容；Web 和 CLI 共用 `BuildPipeline` / Provider / Overlay / Output / Publisher。
也可通过 `ruby scripts/control.rb sources|refresh <id>|profiles|build <id>` 操作同一个控制面（使用相同环境变量）。

CLI Publisher 和 Web Publisher 使用相同 `MPK_PUBLISH_ROOT` 时共享正式状态。MVP 部署应安排单一发布执行者，避免外部 CLI/timer 与 Web 同时切换 Publisher。
SQLite 中不保存 current/previous 或完整发布 Token。备份用 SQLite online backup 工具，并备份 Publisher 私有目录及独立保管的 master key；整个备份都属于敏感数据。
进程意外退出可能留有 `running` Build 记录；它不会出现在可发布列表，重试会创建新的独立记录。

## 验证

```text
ruby test/test_control_plane.rb
ruby test/test_web_api.rb
ruby test/test_web_publisher.rb   # Linux filesystem integration
npm --prefix web run lint
npm --prefix web run typecheck
npm --prefix web run test
npm --prefix web run build
```

Windows CI 覆盖通用控制面与 API，Linux CI 覆盖 Publisher 文件系统和既有 Provider/E2E。所有测试只使用假数据，不需要真实订阅 Secret。
