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
替换 OpenClash LOG_OUT 依赖
    ↓
执行官方转换
```

输出仍然写回输入 YAML。

未来 Provider 只要满足相同契约，就可以接入主构建流程。

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

## 7. DNS Profile

v0.1 提供两种模式。

### upstream

完全保留 Provider 生成的 DNS。

适合普通桌面 / 手机 / 通用 Mihomo 客户端，默认使用此模式。

### china_compat

将 resolver bootstrap 改为国内 IP / DoH，主要用于某些 OpenWrt / Nikki 环境里境外 DoH 出现 bootstrap 死锁的情况。

该模式只作为显式 Overlay，不应该偷偷修改所有构建结果。

## 8. 输出与发布

`dist/` 永远视为敏感产物目录，不提交 Git。

后续发布器计划采用：

```text
builds/<build-id>/mihomo.yaml
current -> builds/<build-id>
previous -> builds/<previous-build-id>
```

对客户端暴露稳定 URL：

```text
/sub/<token>/mihomo.yaml
```

只有新构建完整通过校验后才切换 `current`。
