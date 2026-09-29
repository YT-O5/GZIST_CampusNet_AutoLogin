# 📡 校园网认证资料库（源码 · 注释 · 抓包 · 协议）

> **这份是什么**：门户认证机制的全部资料索引：协议真值、门户源码原件、逐行注释解读、抓包证据。
> **适合谁读**：想知道"校园网到底怎么认证的"的人，以及要改协议相关代码的维护者。
> **相关文档**：协议真值 [`技术资料.md`](技术资料.md) · 源码解读 [`annotated/README.md`](annotated/README.md) · 抓包索引 [`captures/README.md`](captures/README.md)

> 它**不是运行所需文件**：脚本跑起来不依赖这里的任何内容。
> 它的用途是：**搞懂认证原理**、**改协议前查真值**、**门户升级后对照排查**。

---

## 🗺️ 先看这里：我想知道 X，该读哪份？

| 我想… | 去哪 |
| :--- | :--- |
| **了解认证协议本身**（接口、参数、编码、返回码） | [`技术资料.md`](技术资料.md) ← **协议真值的唯一来源** |
| **看懂门户源码怎么实现的**（逐行中文注释） | [`annotated/`](annotated/README.md) |
| **自己核对/复现**（抓包索引） | [`captures/`](captures/README.md) |
| **看门户源码原文**（未注释的原件） | [`raw/`](raw/) |
| **改脚本里的协议代码** | 先读 `技术资料.md`，再对照 `annotated/README.md` 的「源码 ↔ 本实现」对照表 |
| **门户升级后登不上了** | `技术资料.md` 的「§8 变化与风险提示」→ 重点查 `jsVersion` |

---

## 📂 目录内容

| 路径 | 是什么 | 大小 |
| :--- | :--- | :--- |
| [`技术资料.md`](技术资料.md) | **协议真值总汇**：完整 API 文档、HTTPS / IPv6 / 响应格式三个结论、以及 GET-only、callback、blacklist、门户能力清单等细节 | 约 570 行 |
| [`annotated/`](annotated/README.md) | 把门户源码里**与认证相关的片段**抽出来，清掉压缩注释、重排成可读代码，**逐行加中文注释** | 5 份 |
| [`raw/`](raw/) | 门户网页源码（浏览器"另存为"抓下来的）。**仅把里面的本机 IP/MAC 等个人标识换成了合成值**，其余逐字未动 | 5 个文件 |
| [`captures/`](captures/README.md) | 抓包索引。**5 份 HAR 已按隐私要求全部删除**，这里记录它们原本是什么、证明了什么、以及怎么自己重抓 | 0 份（已删） |

---

## 🧭 三条推荐阅读路线

### ① 想搞懂"校园网是怎么认证的"（推荐顺序）
1. [`技术资料.md`](技术资料.md) §1：先建立"有哪些接口、参数长什么样"的整体印象
2. [`annotated/README.md`](annotated/README.md)：看源码里这些参数是怎么拼出来的
3. [`annotated/01-加解密.js`](annotated/01-加解密.js)：重点看**参数混淆与 key 推导**（最容易看错的地方）
4. [`annotated/02-登录流程.js`](annotated/02-登录流程.js)：完整登录流程
5. [`captures/README.md`](captures/README.md)：拿真实抓包对照验证

### ② 只想排障（登不上 / 伪登录）
1. [`技术资料.md`](技术资料.md) §1.7 返回码速查：先对上门户说的是什么错
2. [`技术资料.md`](技术资料.md) §8 变化与风险提示：检查 `jsVersion`、AC IP、XOR key
3. 需要原始响应时看 [`captures/README.md`](captures/README.md)

### ③ 要改脚本里的协议代码
1. [`技术资料.md`](技术资料.md) §1：确认参数名/顺序/编码
2. [`annotated/README.md`](annotated/README.md) 的对照表：定位到本项目哪个函数
3. 改完跑 `npm test`（里面有 HAR 真实向量用例，改错会立刻红）

---

## 🔑 五个必须记住的结论

1. **XOR key 不是常量**，由客户端 IP 推导（`key = IP 各字符 ASCII 逐位异或`）。
   写死 key 会被门户回 `dr0001 code=403`。
2. **三个接口的编码规则各不相同**：`loadConfig` 用 base64；`online_list` 先 base64 再 XOR；`login` 明文再 XOR。
3. **响应是 JSONP**（`dr1003({...})`）且 `Content-Type` 报的是 `text/html`，不是 JSON。
4. **没有 HTTPS 认证、没有 IPv6 要求**（`enable_https=0`、`ipv6_state=0`）。
5. **认证全程是 GET**，密码放在 URL 查询串里：所以日志/截图/分享都要脱敏。

---

## 🔒 安全说明

- 本目录**所有抓包的账号密码字段均已替换为 `REDACTED`**（含 HAR 内 `queryString` 的 JSON 数组形式），可安全分享。
- 需要给别人对照时，**先按脱敏清单处理**再发（抓包原件已按隐私要求全部删除，见 [`captures/README.md`](captures/README.md)）（命名最统一）。
- **门户的参数混淆只是 XOR，不是加密**：重新抓包后若要入库，**务必先把 `user_account` / `user_password` 换成 `REDACTED`**。
- `raw/` 与 `annotated/` 里是门户的第三方前端代码，版权归 Dr.COM（Doctorcom）所有，仅作学习与排障参考。

---

## 🔗 相关文档（不在本目录）

| 想了解 | 去哪 |
| :--- | :--- |
| 怎么用这个脚本（面向普通用户） | [`../docs/使用说明.md`](../docs/使用说明.md) |
| 想改代码 / 接手维护 | [`../docs/维护指南.md`](../docs/维护指南.md) |
| 项目总览 | [`../README.md`](../README.md) |
