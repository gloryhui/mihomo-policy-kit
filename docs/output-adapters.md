# Output adapters（V0.4）

`actual_ios_client: unconfirmed`。仓库没有可靠证据证明用户实际使用 Stash、Loon 或 Surge 中的哪一个；本批次因此实现三者的独立 adapter，但不把任何一个称为“已确认的用户客户端”。

## 共同模型与严格模式

Provider、Overlay 和统一验证先生成一份标准 Mihomo policy。Output Adapter 只读取这份已验证 policy，并为每个客户端生成独立文件：

```text
Mihomo policy -> adapter render + structural validate -> staged candidate -> recoverable atomic promotion
```

默认是严格模式：不能无损表达的代理、`proxy-providers`、策略组或规则类型会让对应 adapter 失败；错误只说明 capability 名称，不打印 password、UUID、token 或完整节点字段。所有选中 outputs 会先 render/validate 完毕，再开始写文件，所以转换失败不会覆盖已存在的成功 artifact。

同一份 `rules/custom.list` 继续使用 `ai`、`global`、`us`、`hk`、`jp`、`sg`、`direct`、`reject`、`final` 等逻辑 target。Overlay 先将它们解析为 Provider 的真实策略组，adapter 不读取或改写用户规则文件。

## Capability matrix

| Output | File | Current V0.4 conversion scope | Structural validation | Explicitly not converted |
| --- | --- | --- | --- | --- |
| Mihomo | `dist/mihomo.yaml` | Original validated policy | YAML + `mihomo -t` when installed | None; existing behavior remains |
| Stash | `dist/stash.yaml` | Clash-compatible YAML: `ss` / `vmess` / `trojan` / `vless`, groups, rule providers and `RULE-SET` | YAML, required sections and references | DNS/TUN host settings |
| Loon | `dist/loon.conf` | `ss`, VMess TCP/WS, Trojan TCP/WS; `select` / `url-test` / `fallback`; direct rules | Required INI sections, FINAL and reference checks | `proxy-providers`, `RULE-SET`, VLESS and Mieru; DNS/TUN |
| Surge | `dist/surge.conf` | `ss`, VMess TCP/WS, Trojan TCP/WS; `select` / `url-test` / `fallback`; direct rules | Required INI sections, FINAL and reference checks | `proxy-providers`, `RULE-SET`, VLESS and Mieru; DNS/TUN |
| sing-box | `dist/sing-box.json` | `ss`, VMess TCP, Trojan TCP -> outbounds/selectors/route; only `select` groups become selectors | JSON parse and outbound/route reference integrity | `proxy-providers`, `RULE-SET`, non-`select` group types, VMess WS/HTTP transport, Trojan WS/HTTP, VLESS, Mieru, `GEOIP`, Clash rule options such as `no-resolve`, `REJECT-DROP`; DNS/TUN/inbounds |

The Stash adapter produces a native YAML policy rather than relabeling a file; Stash documents YAML configuration and Clash-compatible remote proxy/rule providers. [Stash configuration format](https://stash.wiki/en/configuration/example-config), [Stash remote proxy sets](https://stash.wiki/en/proxy-protocols/proxy-providers), [Stash rule sets](https://stash.wiki/en/rules/rule-set)

Loon uses an INI-style profile with `[Proxy]`, `[Proxy Group]`, and `[Rule]`; its documentation lists Shadowsocks, VMess, VLESS and Trojan capability. The adapter intentionally implements only the lossless subset stated above. [Loon node formats](https://nsloon.app/en/docs/Node/)

Surge profiles use `[Proxy]`, `[Proxy Group]`, and `[Rule]`; its documented SS, VMess and Trojan formats are the basis for the generated lines. [Surge profile format](https://manual.nssurge.com/profile/format.html), [SS](https://manual.nssurge.com/policies/shadowsocks.html), [VMess](https://manual.nssurge.com/policies/vmess.html), [Trojan](https://manual.nssurge.com/policies/trojan.html)

sing-box output is standard JSON. Selectors contain outbound tags, and route rules target selector/direct/block outbounds. The current upstream route schema is used for structural output; `sing-box check` is not bundled into CI, so this repository does not claim official runtime validation. [selector](https://sing-box.sagernet.org/configuration/outbound/selector/), [route](https://sing-box.sagernet.org/configuration/route/), [route rules](https://sing-box.sagernet.org/configuration/route/rule/)

`vless` is deliberately rejected by Loon/Surge/sing-box adapters in this release even where a client has VLESS support: translating Reality/XTLS and transport details without a complete implementation would be a silent downgrade. `mieru` is rejected by every non-Mihomo adapter. sing-box also rejects its deprecated `GEOIP` rule, Clash-only rule options, and non-`select` proxy group types rather than generating a configuration that current sing-box versions may not honor. Loon/Surge proxy groups support `select` / `url-test` / `fallback` only. Future expansion must add a complete protocol conversion and fixture tests before widening this matrix.

## Proxy group parameters（严格边界）

`url-test` / `fallback` 组的行为参数只映射到目标客户端**当前官方明确支持且语义对应**的字段；Mihomo 的 group key 不会原样复制。未知或当前无等价实现的字段一律 hard fail，绝不静默丢弃或伪造等价语义。

| Client | `url-test` 支持 | `fallback` 支持 | 明确 hard fail |
| --- | --- | --- | --- |
| Loon | `url` / `interval` / `tolerance` | `url` / `interval` | `lazy`（Loon 无等价项） |
| Surge | `interval` / `tolerance` | `interval` | group-level `url`（当前 Surge 的 group line `url=` 无效果，测试 URL 应来自 policy `test-url` 或全局 `proxy-test-url` / `internet-test-url`）；`lazy`（无已证明等价项） |

`select` 组只允许 `name` / `type` / `proxies`。任何不在上表白名单内的 group 字段都会让对应 adapter 失败，错误只列出 capability 名称，不打印敏感值。

## Selecting outputs

Old configurations remain Mihomo-only. Add `outputs` to opt into other artifacts:

```yaml
outputs:
  - mihomo
  - stash
  - loon
  - surge
  - sing-box

output:
  mihomo: ./dist/mihomo.yaml
  stash: ./dist/stash.yaml
  loon: ./dist/loon.conf
  surge: ./dist/surge.conf
  sing-box: ./dist/sing-box.json
```

`output` paths are optional; these are also the defaults. `bin/mpk build`'s legacy third output-path argument still overrides only `output.mihomo` for compatibility.

V0.2 Publisher remains a Mihomo YAML publisher. It does not create stable HTTPS URLs for Stash, Loon, Surge, or sing-box artifacts in this batch.
