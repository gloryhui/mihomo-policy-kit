# 本地三订阅配置生成

入口：`bash scripts/generate-personal-config.sh`。

脚本直接请求三个机场的 HTTPS 订阅，不读取、更新或切换任何客户端订阅，不依赖 Clash Party 的覆写或 Sub-Store。生成后自己导入任意支持 Mihomo YAML 的软件。该入口目前在 macOS 验证；不声明 Windows 支持。

这是个人专用扩展，入口仍是个人目录中的双击脚本。源码接入 V0.6 的共享 `BuildPipeline`，复用外部 Provider、Overlay、输出和校验能力；不向 Web/桌面新增三合一入口，不改数据库、默认 Profile 或主产品路线。

依赖 Ruby 3 或更新版本、Bash、curl 和标准 Mihomo 内核。`MPK_RUBY` 可以指定 Ruby，`MPK_MIHOMO` 可以指定内核。Mihomo 必须存在，因为 zodaccyes 的第二次下载需要启动短暂的独立代理内核；生成后也必须通过 `mihomo -t`。

## 私有输入和输出

真实订阅设置必须保存在仓库目录之外，不能因为某个目录被 Git 忽略就把地址留在仓库里。`config/personal-sources.example.json` 只包含虚构地址，可以公开。

macOS 默认读取 `/Volumes/1TB/个人工具/mihomo-policy-kit/订阅地址.txt`，每行填写 `ssone=地址`、`tnt=地址`、`zodaccyes=地址`。该文本文件所在目录需要有 `runtime/local-policy/bin/mihomo` 和可选的 `runtime/local-policy/geodata`。其他系统默认读取 `${XDG_CONFIG_HOME:-~/.config}/mihomo-policy-kit/sources.json`。也可通过 `MPK_SOURCES_FILE` 或第一个命令行参数指定仓库外的设置文件；JSON 格式仍可用于自定义参数。设置文件权限应为 `0600`，父目录为 `0700`。

可选 `userAgent`、`authToken` 字段放在相应的 source 内；可选顶层 `geodata_dir` 指向已有 geodata 缓存目录。生成的 `dist/` 仍被 Git 忽略，禁止提交包含节点凭据的成品。

```bash
bash scripts/generate-personal-config.sh
# 或显式指定输入、输出（相对当前工作目录）
bash scripts/generate-personal-config.sh "/Volumes/1TB/个人工具/mihomo-policy-kit/订阅地址.txt" "$HOME/Downloads/mihomo-personal.yaml"
```

默认输出 `~/Downloads/mihomo-personal.yaml`，权限为 `0600`，包含节点密码等私密信息。生成期间所有原始订阅只保存在 `0700` 临时目录，结束后清除。下载或校验失败返回非零并保留上一份输出，不会用缓存冒充“最新”。同一私有配置文件的并发生成会被锁拒绝。

订阅下载遇到临时网络错误最多重试两次；仍失败时保留旧成品。

zodaccyes 每次都先直接获取订阅专用节点，再通过该订阅自身的专用节点第二次拉取完整订阅。两个专用节点按顺序尝试，独立内核只监听 `127.0.0.1`，不开 TUN、不改变系统代理，结束后退出。默认使用操作系统正常路由；如有明确的网络需求，可通过 `MPK_OUTBOUND_INTERFACE=en0` 指定出站接口。脚本不调用客户端更新接口，也不会自动开启任何客户端。

## 当前策略

- ssone、tnt 删除明确标记 **≥3x** 的节点，保留未标倍率的普通节点；Lv1/Lv4 是会员等级，不是倍率。
- 普通业务和地区组只有 ssone+tnt，保留全部可用地区。
- zodaccyes 只允许明确 **1倍** 且位于指定 AI 清单的节点，订阅专用节点不会进入成品。
- Anthropic、OpenAI、Grok、其他 AI 兜底使用指定清单中剩下的 TNT 美国 AI 加速节点和 zodaccyes 1倍节点。Gemini 在同一清单基础上再排除香港，没有通往普通组、DIRECT 或香港节点的选择入口。
- 列表中的 TNT 3x 和 zodaccyes 2倍节点按严格倍率要求删除。日本等未列入 AI 清单的 zodaccyes 节点不会自动扩入。
- 上游旧 AI 组被五个新组替换。四类具体 AI 规则优先，其他 AI 兜底在后，上游其他分流继续保留。

脚本调用现有 Smart-Config-Kit **Normal** Provider，规则源码仍在外部上游，不复制进本仓库。优先用 `vendor/OpenClash(mihomo).sh`，不存在则从官方源获取。五类 AI 分流引用 MetaCubeX/meta-rules-dat 官方规则集合，客户端可正常刷新规则；机场原始订阅只有重新运行本脚本才刷新。

输出是完整配置，包含上游的分流组、DNS、嗅探、rule-providers 和 rules，不需要叠加旧覆写。它仍需网络下载/更新公共规则和 geodata，不是离线规则包。策略隔离适用于 `rule` 模式；客户端的“全局模式”会绕过分流。

成品默认本地代理入口为 `127.0.0.1:7890`，DNS 监听 `127.0.0.1:7874`；客户端可以使用自己的端口设置。

生成包含倍率校验、AI allowlist 校验、普通组到 zodaccyes 的传递引用检查、Gemini 排港、节点数量保护、节点指纹保留及内核配置校验。延迟测速不能证明 AI 服务解锁，实际使用以服务响应为准。

## 开发验证

```bash
ruby test/test_personal_policy.rb
bundle exec ruby test/test_three_source_integration.rb
```

如提交本次开发改动，可使用：

```text
feat: integrate personal three-source script with V0.6 build pipeline

Co-authored-by: Codex <codex@openai.com>
```
