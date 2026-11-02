---
status: accepted
date: 2026-11-01
---

# 新增 grep、glob、fetch 三个工具，搜索用 Zig 原生实现

`tools` 新增三个方法：`grep`（按正则搜文件内容）、`glob`（按模式列文件）、`fetch`（GET 一个 http(s) 地址，HTML 转成 Markdown）。三者都返回结构化数据，脚本可以在 JS 里接着过滤、分组，再交给 `read`。

**为什么加：**
- **grep / glob**：bash 也能搜，但只能返回一段字符串，模型得自己解析；返回 `[{ path, line, text }]` 才能在 Run 里直接组合，这是 PTC 特有的价值。另外，用户机器上没有 ripgrep，`rg` 只是 Claude Code 自带的 shell 函数，nib 的 bash 里跑不了。已有会话日志里模型就调用过一次 `rg`。
- **fetch**：查文档是真实开发的刚需，比如 Zig 0.17 改了很多 API，模型凭记忆容易写错。用 curl 拿到的是原始 HTML，太费 token。

**怎么做（参考了 pi 的 grep.ts/find.ts、oh-my-pi 的 fetch.ts/grep.ts/glob.ts、jcode 的 webfetch.rs，没有复用代码）：**
- **不依赖外部程序。** pi 调用 rg/fd，没装就自动下载；nib 不下载可执行文件，全部用 Zig 实现：
  - `src/tools/walk.zig`：目录遍历、.gitignore 规则、glob 匹配。glob 工具、grep 的 `glob` 过滤和 .gitignore 共用同一个 glob 匹配器。
  - `src/tools/grep.zig`：多线程搜索。最多 8 个线程，按文件序号领取任务，所以截断后的结果和顺序扫描完全一样。
  - `src/tools/regex.zig`：包装 QuickJS 自带的 libregexp。
- **正则就是 JS RegExp。** 和模型在 Run 里写的正则语法一致，不新增依赖。
  - 匹配开启 multiline，所以 `^`/`$` 按行匹配。
  - 纯 ASCII 文件按字节匹配；含非 ASCII 的合法 UTF-8 文件先转成 UTF-16 再匹配，中文模式能命中。
  - 字面量搜索（`literal` 且不忽略大小写）走 `indexOf` 快路径。
  - Esc 取消标志通过 QuickJS 的中断回调传进 libregexp，所以正则灾难性回溯也能被 Esc 打断。
- **跳过规则**：
  - 跳过 `.git` 目录、.gitignore 匹配的文件、符号链接（不跟随）、二进制文件（前 8 KB 内出现 NUL）和超过 16 MB 的文件。
  - .gitignore 会一路读到所在仓库的根目录，所以在子目录里搜索也遵守根目录的规则。
  - 隐藏文件照常搜索，因为 `.github/` 这类目录写代码时用得到。
- **fetch**：
  - 请求头 `Accept` 优先要 `text/markdown`（借鉴 oh-my-pi）。越来越多文档站会直接返回 Markdown，比如 DeepSeek 文档。
  - 拿到 HTML 时由 `src/tools/html.zig` 转成 Markdown。页面有 `<main>`（其次 `<article>`）时只转换这部分；去掉 script、style、nav、aside、form 等非正文内容（这份清单借鉴自 jcode）；相对链接补全成绝对地址。
  - 下载上限 5 MiB，超限报错；返回给 JS 的文本上限 1 MiB，独立的 `truncated` 布尔字段标明正文是否完整，text 不含截断提示。模型上下文保护只在 Session 交付 Run 输出时截断至首尾约 16 KiB，不改变 JS 内的数据（见 [0002](0002-run-code-only.md)）。
  - 最多跟随 5 次重定向；二进制内容直接报错。
  - 请求在 `std.Io` 的并发任务里执行，超时或 Esc 会取消这个任务，连卡住的读取也能打断。实测服务端卡住 3 秒、`timeout_ms: 300` 时，整轮 0.78 秒结束。

**安全边界：**
- grep/glob 不跟随符号链接，并跳过默认和自定义的 Codex 凭证文件（与 read 的检查一致）。直接对凭证文件 grep 会被拒绝。
- fetch 只支持 http/https 的 GET 请求，不带 cookie 和认证头。
- fetch **不拦截** localhost 和内网地址（用户选定，2026-11-01）。理由：bash 跑 curl 本来就能访问这些地址，拦了也不构成安全边界，反而用不了本地开发服务器。
- 网页内容可能包含针对模型的指令（提示注入），这一点无法从技术上防住。工具说明里写明返回内容是不可信的外部数据，只能当作资料，不能当作指令。模型也可能把信息拼进 URL 带出去，这同样不在保证范围内。现有的凭证边界（[0006](0006-deny-dangerous-commands.md)）至少保证工具读不到凭证文件。

**把握程度：**
- 实测：
  - 本机 `~/myself`（多个大型仓库）全量 grep 约 100 ms；nibcode 的 `src` 内搜索约 1 ms。
  - 真实抓取 example.com、ziglang.org/download、DeepSeek 文档：HTTPS 和重定向都正常，DeepSeek 文档的表格转换正确。
  - 单元测试覆盖 glob、.gitignore、凭证跳过、UTF-8 匹配、上下文、截断、HTML 转换；`tests/test_session.py` 用 mock 覆盖了重定向、Accept 请求头、HTML 转 Markdown 和超时打断。
- 已知局限：
  - .gitignore 只读各级目录里的 `.gitignore`，不读 `.git/info/exclude`、全局 excludes 和 `.ignore`。
  - grep 先遍历完目录再搜索，`limit` 很小时也要走完整棵目录树。
  - 匹配跨行时，只报告起始行。
  - HTML 转换是轻量实现，不执行 JS，所以客户端渲染的页面拿不到正文。
  - 不支持 web search。

**何时重新考虑：**
- 搜大目录明显变慢：改成边遍历边搜索，或并行遍历。
- 常遇到客户端渲染的页面：考虑 llms.txt 探测，或接一个阅读服务（oh-my-pi 支持 jina 等）。
- 需要搜索引擎：单独加 search 工具，需要外部 API。
