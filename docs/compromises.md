# 妥协登记表

原则见 [README.md](README.md#立足当下面向未来)。这里登记的每一项都是为当下做的妥协，不是设计本身。新增妥协先登记；删除条件满足时删掉代码，并在这里划掉。

## 模型补丁

提示词里的补丁集中在 `src/session.zig` 的 `patches`，设置 `NIB_PATCHES_OFF=<id,...|all>` 可以关闭（子会话继承环境变量）。验证方法：关闭一段时间，再用 `scripts/stats.py --since` 和开启时的同期数据对比观察信号。

| id / 名称 | 位置 | 原因 | 观察信号 | 删除条件 |
|---|---|---|---|---|
| `json-escape` | 系统提示 Writing scripts | 模型在写含反引号、`${`、反斜杠的文本时，常用模板字符串导致 SyntaxError 或内容被改写 | stats 错误分类 `js_syntax` | 关闭后 `js_syntax` 没有明显上升 |
| `no-shell-search` | 系统提示 Writing scripts | 最初因 rg 未安装、调用报 127 而加；2026-11-03 已安装 ripgrep，现在只剩"推荐结构化结果、跳过凭证文件"这层理由 | bash 中 rg/grep 的使用次数、Run 内解析文本出错的次数、tools.grep 使用量 | 关闭后模型能在 rg 与 tools.grep 间合理选择，且解析出错没有明显上升；删除时把 tools.grep 的优势作为事实写进说明 |
| reflect 只报有证据的问题 | `src/tui/reflect.md` | 担心模型为完成反思而凑问题；草稿会自动公开发布 | 自动提交的 issue 中被关闭为无效或重复的比例 | 门槛措辞进一步精简后，误报率不上升（只能改模板验证，无开关） |

## 实现妥协

| 名称 | 位置 | 原因 | 删除条件 |
|---|---|---|---|
| 子 agent 深度上限 1 | `src/tools.zig`（agent 仅根会话可用） | 没有成本预算机制时，防止递归派生失控 | 有按预算限制的机制后改为预算 |
| 流式响应空闲超时通过替换 HTTP 连接底层 reader 的 Io vtable 实现 | `src/provider/idle.zig` | `std.http.Client` 没有读取超时；替换 `connection.stream_reader.io` 依赖标准库内部结构，升级 Zig 时可能失效 | 标准库 HTTP 客户端支持读取超时或截止时间 |
| bash 命令部分超过 256 个 shell 词即拒绝 | `src/tools/policy.zig` | 检查器用固定缓冲区存放命令部分的词；heredoc 正文已不计入 | 检查器不再需要固定缓冲区 |

## 写死的策略

这些是用户的预算和偏好，现在写成了常量，应进入 `config.toml`。

llm/agent 的并发、调用次数、输入大小和 Step 上限已于 2026-11-03 改为可配置，见 [config.md](config.md#limits)。sandbox 内全部工具最多 8 并发仍属于线程调度实现。

| 名称 | 位置 | 当前值 | 删除条件 |
|---|---|---|---|
| 后台 bash 同时运行上限，超出即 reject | `src/tools/background.zig`（复用 `sandbox.tool_concurrency`） | 8 | 移入 `[limits]` |
| 工具录制的单条结果上限；calls 文件没有总量上限或轮转 | `src/sandbox/record.zig` | 1 MiB | 有存储预算与清理配置后移入配置 |
