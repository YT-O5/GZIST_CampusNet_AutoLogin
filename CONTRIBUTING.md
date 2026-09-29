# 贡献指南（CONTRIBUTING）

> **这份是什么**：改这个项目前必须知道的规矩：提交前跑什么、什么绝不能提交、代码与文档风格。
> **适合谁读**：想提 PR 或在自己 fork 上改代码的人。
> **相关文档**：维护交接 [`docs/维护指南.md`](docs/维护指南.md) · 协议真值 [`Campus Network source code/技术资料.md`](Campus%20Network%20source%20code/技术资料.md)

感谢你有兴趣改进这个脚本。它是给广州理工学院师生用的校园网自动登录工具，
**稳定性 > 功能多**。请先读完本文再动手。

---

## 一、提交前必须做的事

```powershell
# 1) 语法自检（项目内置，改完 .ps1 必跑）
npm run check

# 2) 单元测试（npm test 会先自动跑一遍语法自检）
npm test

# 3) 确认没把凭据带进仓库（把尖括号换成你自己的真实值再跑）
git status --short
git diff --cached | findstr /I "<你的学号> <你的密码>"    # 应无输出
```

三条全绿再提 PR。

---

## 二、绝对不要提交的东西

| 文件 | 原因 |
| :--- | :--- |
| `CampusNet_AutoLogin/CampusNet_Config.json` | 含你的账号与密码密文 |
| `CampusNet_AutoLogin/*Log*.txt` / `*.log` | 运行日志里会带学号 |
| `Campus Network source code/captures/*.har` | 抓包含**可还原**的账号密码（XOR 不是加密）；只有 `*redacted*.har` 例外 |

> ⚠️ `Campus Network source code/raw/`（门户源码原件）、`annotated/`（注释解读版）与 `技术资料.md`
> 是**有意入库**的，**不要**给它们加忽略规则。

以上都已在 `.gitignore` 里。**改 `.gitignore` 前先想清楚**：漏一条就可能把凭据提交上去。

需要分享抓包时，只发脱敏版 `*.redacted.har`（账号密码字段为 `REDACTED`）。

---

## 三、代码风格

1. **逻辑一律写在 `CampusNet_AutoLogin/CampusNet.Common.ps1`**；
   `CampusNet_Login.ps1` / `CampusNet_Silent.ps1` 只负责参数解析与交互。
2. **新函数要写注释块**，格式照抄现有函数（作用 / 入参 / 返回 / 流程 / 调用方 / 坑）。
3. **`.ps1` 必须存成 UTF-8 with BOM**。无 BOM 时 Windows PowerShell 5.1 会按 ANSI 读，
   中文注释会变乱码并引发语法错误。
4. **`.bat` 必须纯 ASCII + CRLF**（见 `.gitattributes`）。
5. 兼容 **Windows PowerShell 5.1**（随系统自带那个），别用 PS 7 专有语法。
6. 打日志/上屏前，**凡 URL 里含密码一律过 `Get-MaskedUrl`**。

---

## 四、改协议相关代码要特别小心

门户参数用 **逐字符 XOR + 十六进制** 混淆，而且 **key 由本机 IP 推导**（不是常量）。

- 改 `Get-DrappallKey` / `ConvertTo-DrappallValue` 前，先看
  `tests/CampusNet.Common.Tests.ps1` 里的 **HAR 真实向量** 用例：它们会用真实抓包的值断言，
  改错会立刻变红。
- 加新协议时，参考 `Send-CampusLoginRequest` 的策略链写法：
  **响应不可识别就换下一种**，凭证类错误**不重试**（避免把账号刷到锁定）。

---

## 五、必须守住的一条底线

> **`result:1`（服务器说成功）≠ 能上网。**

判定登录成功**只能**以 `Wait-CampusInternet` 的真实联网校验为准。
这是本项目历史上"伪登录"问题的根治方式，**请不要把它改回去**。

---

## 六、文档改动

### 6.1 命名规则（新增文档请照这个来）

| 类型 | 规则 | 例子 |
| --- | --- | --- |
| GitHub 特殊文件 | **保持英文原名**（改了 GitHub 就不认，仓库首页 / 目录首页会失效） | `README.md`（各目录首页）、`CHANGELOG.md`、`CONTRIBUTING.md`、`LICENSE`、`NOTICE` |
| 其它内容文档 | **中文规范名**：不用全角括号，不带"（优化版）"这类版本尾巴 | `docs/使用说明.md`、`docs/维护指南.md`、`Campus Network source code/技术资料.md` |
| 带序号的解读文件 | 中文名 + 保留两位数字前缀（数字用来固定阅读顺序） | `Campus Network source code/annotated/01-加解密.js` |
| 脚本 / 配置 / 代码 | **一律英文**，不改名 | `CampusNet_Login.ps1`、`CampusNet_Config.example.json` |

判断标准一句话：**这个名字会被 GitHub 特殊对待吗？** 会 → 英文；不会 → 中文。

### 6.2 各文档的定位（改之前先看清该写在哪）

- 面向用户（怎么装、怎么上手）：`README.md`（第一部分是完整上手流程，第二部分是参考资料）
- 面向用户（出情况怎么查）：`docs/使用说明.md`（按处境查的手册）
- 面向维护者（改代码看这份）：`docs/维护指南.md`
- 协议真值（**唯一来源**）：`Campus Network source code/技术资料.md`
- 源码注释解读与「源码 ↔ 实现」对照：`Campus Network source code/annotated/README.md`

⚠️ **协议细节只写在「协议真值」那一份里**；其它文档一律只做摘要 + 链接过去，避免同一件事写两处、改一处漏一处。

### 6.3 其它约定

- 每份文档开头保留统一的三行头部：这份是什么 / 适合谁读 / 相关文档。
- 术语统一：正文说「门户」不写 Portal、说「抓包」不写 HAR。
  **例外（照抄不动）**：门户原文与内部码（如响应里的 `Portal协议认证成功！`）、
  URL 与参数名（`/eportal/portal/login`、`c=Portal`）、本项目标识符
  （`Get-PortalProbeUrls`、`OpenPortalOnFailure`）、以及文件名与格式名（`*.har`、`HAR 抓包`）。
- 改动行为时请同步更新 `CHANGELOG.md`（`Added` / `Changed` / `Fixed` / `Security` 分类）。

---


## 七、提交钩子（pre-commit）

仓库自带 `.githooks/pre-commit`：提交前检查暂存区，**拒绝 `CampusNet_Config.json`、`*.har`、
`logs/`、日志文件、`.saz`/`.pcap` 等**：因为 `.gitignore` 拦不住 `git add -f`。

克隆后请执行一次（本地配置，不随仓库分发）：

    git config core.hooksPath .githooks
## 八、许可

提交即表示你同意以 **MIT License** 授权你的贡献（见 [`LICENSE`](LICENSE)）。
