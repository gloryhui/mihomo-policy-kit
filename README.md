# mihomo-policy-kit

一个面向多设备、多客户端的 **Mihomo 策略编译与私有订阅生成工具**。

它不试图重新发明一套分流规则，而是把优秀的上游分流项目当作 Provider，再叠加你自己的规则、校验与发布流程，最终生成一份可直接被 Clash Party、Clash Verge Rev、Nikki、Clash Meta / ClashMi 等 Mihomo 客户端订阅的 `mihomo.yaml`。

> 当前阶段：**v0.1 / MVP**。第一版只接入 Smart-Config-Kit 的 **Normal / 非 Smart** 版本，不使用 Mihomo Smart / LightGBM。

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
HTTPS 私有订阅
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
- 远程机场订阅 URL
- 自定义 `.list` 规则文件

### 输出

- `dist/mihomo.yaml`

### 当前主要兼容客户端

- Clash Party
- Clash Verge Rev
- Nikki
- Clash Meta / ClashMi 等 Mihomo 客户端

只要客户端能直接消费标准 Mihomo YAML，就属于当前目标范围。

## 快速开始

### 1. 依赖

Linux / macOS / WSL：

```bash
bash
ruby
curl
```

可选但强烈建议：

```bash
mihomo
```

如果存在 `mihomo`，构建结束会自动执行配置测试。

### 2. 准备配置

```bash
cp config/config.example.yaml config/config.yaml
cp rules/custom.example.list rules/custom.list
```

不要把机场真实订阅 URL 提交到公开仓库。

推荐使用环境变量：

```bash
export MPK_SOURCE_URL='https://your-airport.example/subscription/token'
```

### 3. 可选：提前下载 Smart-Config-Kit Normal 脚本

GitHub 慢的时候建议放本地：

```text
vendor/OpenClash(mihomo).sh
```

如果本地不存在，构建器才会自动从官方仓库下载。

### 4. 构建

```bash
./bin/mpk build
```

生成：

```text
dist/mihomo.yaml
```

### 5. 校验

```bash
./bin/mpk validate dist/mihomo.yaml
```

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

## 安全

**不要公开最终生成的 `dist/mihomo.yaml`。**

它可能包含：

- 节点服务器地址
- UUID / 密码
- Reality 参数
- 机场专属信息

推荐最终通过自建 HTTPS 服务 + 高熵 Token URL 发布，例如：

```text
https://sub.example.com/sub/<random-token>/mihomo.yaml
```

GitHub 公共仓库只放编译器、示例配置和规则模板，不放真实机场订阅与生成结果。

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
│   └── overlay.rb
├── providers/
│   └── smart-config-kit/
│       └── provider.sh
├── rules/
│   └── custom.example.list
├── scripts/
│   ├── build.rb
│   └── validate.rb
├── vendor/
│   └── .gitkeep
└── dist/
    └── .gitkeep
```

## 路线图

### v0.1

- [x] Smart-Config-Kit Normal Provider
- [x] 本地 Provider 脚本优先，GitHub 下载兜底
- [x] 自定义规则 Overlay
- [x] 逻辑策略组映射
- [x] 删除顶层 `global-client-fingerprint`
- [x] 节点数量保护
- [x] Mihomo 配置校验
- [ ] 私有 HTTPS 发布器
- [ ] 定时构建

### v0.2

- [ ] 构建历史 / current / previous
- [ ] 自动回滚
- [ ] 多 Token 订阅发布
- [ ] Provider 版本锁定
- [ ] GitHub Actions / 自建 CI

### v0.3+

- [ ] ACL4SSR Provider
- [ ] 其他社区分流 Provider
- [ ] Stash 输出
- [ ] Loon / Surge / Shadowrocket 输出
- [ ] sing-box 输出

## License

MIT。

Smart-Config-Kit 及其规则、脚本版权归其原作者和相应上游项目所有。本项目运行时调用上游产物，不将其源码作为本项目自身代码重新发布。
