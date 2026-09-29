# Dr.COM 哆点门户「认证相关」源码解读版

> **这份是什么**：门户认证相关源码的逐行中文解读，并逐条对应到本项目的实现函数。
> **适合谁读**：要改协议相关代码、或想搞清"每个参数到底从哪来"的人。
> **相关文档**：协议真值 [`../技术资料.md`](../技术资料.md) · 原始源码 [`../raw/`](../raw/) · 抓包证据 [`../captures/README.md`](../captures/README.md)

本目录是 [../raw/](../raw/) 里那次门户登录抓包的**认证相关部分**的逐行中文解读版。
原始 `raw/` 文件是**只读参考**，本目录只是把它们拆出来、重新排版、逐段加注释，方便对照
本项目实现（`../../CampusNet_AutoLogin/CampusNet.Common.ps1`）。

> ⚠️ 本目录**只读参考**，不参与运行。真正跑起来只依赖 `CampusNet_AutoLogin/` 下的脚本。
> 解读版里的账号/密码等均用**示例值**，不含真实凭据；如需分享原始资料请参照
> [`../captures/README.md`](../captures/README.md) 的安全说明。

---

## 1. 阅读顺序

| 顺序 | 文件 | 讲什么 | 主要来源（原始行号） |
| --- | --- | --- | --- |
| ① | [01-加解密.js](01-加解密.js) | **加解密**：XOR key 怎么来、逐字符 XOR 转 hex、以及"用不用加密"的分支 | `a41.js` 13-17 / 2338-2359 / 2433-2470 / 2598-2628 / 2676-2743；`a40.js` 6725-6733 |
| ② | [02-登录流程.js](02-登录流程.js) | **登录请求构造与响应处理**：`portal_login` 各种调用场景、callback 计数器、错误分支 | `a40.js` 2151-2316 / 3771-4072；`a41.js` 606-627 / 2486-2549 |
| ③ | [03-加载配置.js](03-加载配置.js) | **`page/loadConfig` 取页面配置**：参数表、哪些值走 base64、返回字段用途 | `a41.js` 461-604 |
| ④ | [04-登录页解读.md](04-登录页解读.md) | **门户入口页 `a79.htm`** 逐行解读 + "哆点参数"块与新旧接口的关系 | `a79.htm` 1-87（全部） |

建议先看 ④（入口页全局变量）→ ①（加解密）→ ③（loadConfig）→ ②（登录）。

---

## 2. 出处一览（本目录每个片段从哪来）

- `01-加解密.js`
  - `a41.js`：第 13-17 行（`page_data_encrypt` / `encryption_type` / `secret_key` 三个全局变量的声明）
  - `a41.js`：第 2338-2344 行（`getkey`）
  - `a41.js`：第 2345-2359 行（`enc_pwd`）
  - `a41.js`：第 2433-2470 行（`_jsonp` 里"是否加密 / 用哪个 key"的分支）
  - `a41.js`：第 2598-2628 行（`util.base64encode`）、第 2676-2743 行（`util.base64Encode`）
  - `a40.js`：第 6725-6733 行（WebAuthn `web_register` 里的同一套加密分支）
- `02-登录流程.js`
  - `a40.js`：第 2151-2189 行（`login.default_login`）
  - `a40.js`：第 2190-2316 行（`login.portal_login`）
  - `a40.js`：第 3771-3824 行（`login.login` 的 `login_method` 分发）
  - `a40.js`：第 3825-3846 / 3866-3879 / 3941-3972 行（含 `user_password` 的几处参数字面量）
  - `a41.js`：第 606-627 行（`checkStatus` 的 `online_list`）
  - `a41.js`：第 2360-2471 / 2478-2549 行（`_jsonp` 里 callback 生成、回显与 `operate === "portal_login"` 的错误处理）
- `03-加载配置.js`
  - `a41.js`：第 461-604 行（`getPageInfo`）
- `04-登录页解读.md`
  - `a79.htm`：第 1-87 行（全文）

> 行号以 **本仓库当前 `raw/` 文件**为准。注意：`raw/` 里的文件名已换成可读名
> （`a40.js` / `a41.js` / `a75.js` / `a79.htm` / `b80.css`），
> 原名里带的 `?v=_1790040366852`、`?version=…` 只是浏览器的缓存破坏参数，与内容无关。

---

## 3. 「门户源码 ↔ 本项目实现」对照表

本项目实现文件：`CampusNet_AutoLogin/CampusNet.Common.ps1`（路径相对本目录为 `../../CampusNet_AutoLogin/CampusNet.Common.ps1`）。

| 门户源码（本目录解读） | 门户里的名字 | 本项目实现（PowerShell） | 说明 |
| --- | --- | --- | --- |
| `01` · `a41.js` 2338-2344 | `util.getkey(ip)` | `Get-DrappallKey` | 都把 IP 字符串逐字符 ASCII 码 XOR 成一个字节当 key |
| `01` · `a41.js` 2345-2359 | `util.enc_pwd(s,key)` | `ConvertTo-DrappallValue` | 逐字符 XOR key → 2 位小写 hex；本项目另有 `ConvertFrom-DrappallValue` 反向解码 |
| `01` · `a41.js` 2433-2470 | `_jsonp` 加密分支 | `New-DrappallLoginUrl`（内部用 `Get-DrappallKey` + `ConvertTo-DrappallValue`） | 决定"哪些请求加密、用 ip 还是 secret_key"；本项目只实现 ip 分支（本校园网 `encryption_type='0'`） |
| `02` · `a40.js` 3825-3846 | `login.login_portal` 的 `data` 字面量 | `New-DrappallLoginUrl` 的 `$fields`（1478-1535 行） | 参数名/顺序/取值一一对应 |
| `02` · `a40.js` 2190-2316 | `login.portal_login` | `New-DrappallLoginUrl` + `Send-CampusLoginRequest` | 拼 URL、发请求、判 `result` |
| `02` · `a41.js` 606-627 | `checkStatus` 的 `online_list` | （本项目未直接调用；见 `Get-PortalProbeUrls` 等探针逻辑） | 在线列表接口 |
| `02` · `a41.js` 1063 / 2426 / 2478 | `util.increment()` / `callbackName` / `window[callbackName]` | `New-DrappallLoginUrl -Callback`（默认 `dr1003`） | callback 计数器与回显 |
| `03` · `a41.js` 461-604 | `getPageInfo`（`page/loadConfig`） | `New-DrappallLoadConfigUrl` + `Get-DrappallPageIndex` | 取 `program_index` / `page_index` / `page_name` |
| `02/03` 通用 | `util._jsonp` 的响应体 | `ConvertFrom-PortalResponse` | 解析 `dr1003({...})` / `dr0001({...})`，判 `result` / `ret_code` / `msg` |
| `02` 通用 | `login.login` 的协议分发 | `Send-CampusLoginRequest -Protocol auto/drappall/legacy` | 协议策略链：先哆点 v4，再回退旧 801 |

---

## 4. 与「已确认事实」的对照 / 冲突说明

下列各点已用**源码 + 抓包**双重核对；**冲突处以源码与抓包为准**。

1. **✅ 一致：XOR 规则。** `a41.js` 2338-2359 的 `getkey`/`enc_pwd` 与"每字符 XOR key → 2 位小写 hex、
   key = IP 字符串各字符 ASCII 码逐位异或"完全吻合。实测 `10.20.30.40 → 0x2A` 也复核通过。

2. **✅ 一致：`page/loadConfig` 用 URL 编码的 base64，不做 XOR。** `a41.js` 2438 行明确把
   含 `page/loadConfig` 的 url 排除在加密分支外；抓包实测其 `callback=dr1001`（明文）、
   `wlan_user_ip=MTAuMjAuMzAuNDA%3D`（base64 又被 `encodeURIComponent` 变成 `%3D`）。

3. **❌ 冲突（重要）：`online_list` 在抓包里是走 XOR 的，不是"URL 编码的 base64"。**
   - 任务给的"已确认事实"说 `page/loadConfig` **与** `online_list` 都用 URL 编码 base64；
   - 但源码 `a41.js` 2434-2439 的加密条件是"`page_data_encrypt==1` 且 url 含 `eportal/portal`
     且不含 `wifidog/disconnect` 且 **不含 `page/loadConfig`**"。`online_list` 的 url 是
     `.../eportal/portal/online_list`，**满足**该条件 → 会被 XOR；
   - 抓包实测也证明如此（该抓包已按隐私要求移除）：当时那份抓包里
     `online_list?...&wlan_user_ip=677e6b5f67406b5f67506b5f646e6b17&...&callback=4e581b1a1a18`，
     其中 `677e6b5f...6b17` = `XOR0x2A(base64("10.20.30.40"))`，`4e581b1a1a18` = `XOR0x2A("dr1002")`
     （这里的 `0x2A` 就是 `10.20.30.40` 推出来的 key）。
   - **结论**：**只有 `page/loadConfig` 例外**（明文 + URL 编码 base64）；`online_list` 与
     `portal/login` 一样走 XOR。本 README 以源码与抓包为准。

4. **✅ 一致：尾部 `encrypt=1&v=<随机>&lang=zh` 不参与混淆。** `_jsonp` 里 `arr['encrypt']=1` 在
   加密循环**之后**才写入，`v`、`lang` 由 `formatParams` 在**最后**追加，都不经 `enc_pwd`。

5. **✅ 一致：callback 形如 `dr1003` 递增、响应回显同一 callback。** `util.increment()` 从 `num=1000`
   起 `++`，所以第一个是 `dr1001`。抓包序列：`dr1001`（loadConfig）→ `dr1002`（online_list）→
   `dr1003`（login）。详见 `02-登录流程.js`。

6. **⚠️ 补充（"已确认事实"没提）：callback 参数值本身也被 XOR。** 因为 `callback` 也在
   `params.data` 里，会进加密循环，所以线上看到的是 `callback=445211101013`（=`XOR0x20("dr1003")`，按默认 key 0x20 演示）
   而**不是** `dr1003`。同理 `operate` 线上是 `504f5254414c7f4c4f47494e`（=`XOR0x20("portal_login")`）。

7. **⚠️ 补充：`jsVersion` 有两个值。** `a40.js` 第 8622 行 `var jsVersion='4.5.1'` 在文件**末尾**才赋值；
   所以先跑的 `loadConfig` 用的是 `4.X` 兜底，后跑的 `login` 用的是 `4.5.1`（抓包实测一致）。

8. **⚠️ 补充：`online_list` 请求带 `program_index` / `page_index`。** 由 `_jsonp`（`a41.js` 2400-2402）
   统一注入 `params.data['program_index']=page.name`、`params.data['page_index']=page.index`，
   所以**除了 loadConfig 之外**每个 `eportal/portal/*` 请求都会带上这两个值。

9. **⚠️ 补充：`business_type` / `terminal_type` 等取的是本机推导值，不是常量。**
   `a40.js` 2198-2212 里 `terminal_type=term.type`、`business_type=term.business_type`；
   抓包里恰好都是 `1`。本项目把 `business_type` 写死 `'1'`、`terminal_type` 写死 `'1'`，
   在 PC 端有线场景下与抓包一致。

---

## 5. 抓包真值 / 协议参数表

**不在本文重复**：完整的请求行、参数表、编码规则与返回码已收敛到单一来源：

👉 **[`../技术资料.md`](../技术资料.md) §1 完整 API 文档**

本文只负责"源码 ↔ 本实现"的对照（见上一节），参数本身以 `技术资料.md` 为准。

---

## 6. 需要"从抓包推断 / 源码未体现"的点（本目录会在对应片段再标一次）

- `a79.htm` 的 `ss1="001122334455"`、`mip="010020030040"`：在 `a41.js` 里**没有被读取**
  （`grep` 无引用），语义**源码未体现**，本解读按"残留/内核预留变量"标注，不臆测具体含义。
- `a79.htm` 的 `aolno=18842`、`timet=1790571057`：仅与门户自身统计/防缓存相关，认证链路未使用。
- `ss2` / `ss3` / `ss6` 等会话字段的实际生成端在内核（AC），前端只读取。
