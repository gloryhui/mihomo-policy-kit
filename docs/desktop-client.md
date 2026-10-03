# 桌面管理客户端（V0.6）

MPK Console 使用 Tauri 2 / Rust / Vue 3 / TypeScript，在 Windows 和 macOS 上连接已有的 MPK Web 控制台服务。它复用订阅源、节点池、构建配置和发布页面；Ruby API、Provider、SQLite 和 Publisher 仍运行在服务器。

第一版不运行本地代理核心，不切换系统代理，不提供自动更新或托盘。现有浏览器控制台和 CLI 可以继续使用。

## 安装与使用

GitHub Actions 的 **Desktop** workflow 在每次 PR / main 更新时上传安装包：Windows 的 NSIS setup.exe，macOS 的 DMG。进入成功运行的 Artifacts 下载对应系统包，解压后安装。

这些包暂未做 Windows 代码签名或 Apple 签名/公证。操作系统可能限制运行；项目不宣称已经通过签名验证。macOS CI 打包运行器的原生架构，当前不提供 universal 包；请确认包的架构适合你的设备。

打开客户端后输入：

1. 服务器 HTTPS 根地址，例如 `https://example.com:8215`。不要填写 `/admin/`、API 路径、Token、query 或账号。
2. 现有 Nginx Basic Auth 用户名、密码。
3. 如果服务使用自签名证书或私有 CA，从可信渠道取得其 **公开 PEM 证书**（.crt / .pem），展开证书设置并导入。不要导入私钥。

客户端验证证书信任链、有效期和主机名；导入证书不会关闭 TLS 校验。IP 访问的证书需要对应 IP 的 Subject Alternative Name。换域名后应更新服务器公开地址及匹配证书。

连接成功后可以管理订阅、筛选节点、构建并发布。所有 Profile 仍共用一个 Publisher current，发布会更新全部设备 Token。刷新仍是手动操作。

地址和用户名保存在客户端本地偏好中；密码和证书只留在本次进程内存，退出/断开后重新连接需要输入。请求正在完成时，内存中的凭据可能保留至请求结束，但其响应在连接改变后会被丢弃。断开连接不会撤销服务器已经接受的构建/发布操作。

## NPS 和自签名服务

NPS 使用 TCP 转发到服务器 HTTPS 端口，让 TLS 原样穿过。客户端填写最终外部 HTTPS 地址。服务器的 `MPK_PUBLIC_BASE_URL` 必须匹配最终地址，公开证书也要匹配其域名或 IP。

不要填写远程 HTTP 地址；仅 `localhost` / loopback IP 的 HTTP 服务用于本机开发。客户端原生 HTTP 通道不会使用环境变量中的代理，且不会跟随 HTTP 重定向。服务器应直接提供 `/api/v1/health`，不能将 API 重定向到另一个主机。

连接失败时检查地址、用户名密码、证书及服务器 V0.5 API 是否可用。客户端返回安全错误摘要，不回显底层错误里的认证信息、URL query 或远端响应正文。

## 开发和打包

安装 Node 22.12+、Rust stable、Tauri 的本机系统依赖。Windows 需要 Visual Studio C++ Build Tools 和 WebView2；macOS 需要 Xcode Command Line Tools。详见 [Tauri 官方依赖说明](https://v2.tauri.app/start/prerequisites/)。

```powershell
npm --prefix web ci
npm --prefix web run desktop:dev
```

开发服务使用端口 5173，先停止占用此端口的普通 Web Vite 服务。桌面模式使用 Hash Router 和相对静态资源；浏览器模式继续使用 `/admin/`。

```powershell
# 在 Windows 打包
npm --prefix web run desktop:build:windows
# 在 macOS 打包
npm --prefix web run desktop:build:macos
```

产物位于 `desktop/src-tauri/target/release/bundle/`，不要提交生成物。

```powershell
cargo test --manifest-path desktop/src-tauri/Cargo.toml --no-default-features --locked
cargo clippy --manifest-path desktop/src-tauri/Cargo.toml --no-default-features --locked -- -D warnings
npm --prefix web run lint
npm --prefix web run typecheck
npm --prefix web run test
```

Rust 客户端只允许既有管理 API 的路径和方法，设置连接/操作超时及请求/响应大小上限。凭据只发给已配置的服务器，不跟随重定向；远程 HTML 不会进入桌面 WebView。内置页面没有文件系统或 shell 的原生权限。测试只使用本机假数据和即时生成的测试证书，不提交私钥或真实订阅。
