# Custom Rules

## 1. 设计目标

自定义规则属于用户自己的配置，不应该写进主脚本，也不应该为了加一个域名重新构建 Provider 代码。

mihomo-policy-kit v0.1 使用简单 `.list` 文件：

```text
rules/custom.list
```

文件不存在时，默认只警告并继续构建。

## 2. 基本格式

语法沿用 Mihomo classical rule 的常见三段结构，但最后的策略目标使用逻辑名。

```text
TYPE,VALUE,TARGET[,OPTIONS...]
```

例如：

```text
DOMAIN-SUFFIX,experientiallabs.ai,ai
DOMAIN,api.example.com,ai
IP-CIDR,8.8.8.8/32,global,no-resolve
IP-CIDR,192.168.0.0/16,direct,no-resolve
```

构建后会变成：

```text
DOMAIN-SUFFIX,experientiallabs.ai,🤖 AI 服务
DOMAIN,api.example.com,🤖 AI 服务
IP-CIDR,8.8.8.8/32,🌍 全球节点,no-resolve
IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
```

## 3. 当前支持的规则类型

v0.1 重点支持常见简单规则：

```text
DOMAIN
DOMAIN-SUFFIX
DOMAIN-KEYWORD
DOMAIN-REGEX
GEOSITE
GEOIP
IP-ASN
IP-CIDR
IP-CIDR6
SRC-IP-CIDR
SRC-IP-CIDR6
SRC-PORT
DST-PORT
IN-PORT
PROCESS-NAME
PROCESS-PATH
PROCESS-NAME-REGEX
PROCESS-PATH-REGEX
RULE-SET
NETWORK
MATCH
```

复杂逻辑规则例如 `AND` / `OR` / `NOT` 暂不在 v0.1 的简易 `.list` 编译器里处理，后续会增加结构化 YAML 规则格式。

## 4. 逻辑目标

常用目标：

```text
ai
us
hk
sg
jp
global
direct
reject
google
youtube
netflix
international
cn
final
```

完整映射见：

```text
config/groups.smart-config-kit.yaml
```

## 5. 优先级

所有用户自定义规则会放到 Provider 规则之前。

例如：

```text
DOMAIN-SUFFIX,example.com,us
```

即使 Smart-Config-Kit 原规则会把 `example.com` 分到其他业务组，只要这条规则先命中，就会优先进入美国节点组。

所以 `custom.list` 相当于用户自己的最高优先级 Overlay。

## 6. 多文件

可以在 `config/config.yaml` 中指定多个文件：

```yaml
custom_rules:
  files:
    - ./rules/10-ai.list
    - ./rules/20-direct.list
    - ./rules/30-us.list
    - ./rules/90-reject.list
```

按照数组顺序合并，越靠前优先级越高。

推荐后续按用途拆分，而不是把所有规则都塞进一个几千行文件。

## 7. 安全建议

公开仓库里只提交：

```text
custom.example.list
```

真实的私有域名、内部 IP、公司网段等可以放进被 `.gitignore` 排除的：

```text
rules/custom.list
rules/private-*.list
```

这样仓库可以公开，实际部署规则仍然保持私有。
