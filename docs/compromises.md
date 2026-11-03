# 妥协登记表

原则见 [README.md](README.md#立足当下面向未来)。这里登记的每一项都是为当下做的妥协，不是设计本身。新增妥协先登记；删除条件满足时删掉代码，并在这里划掉。

## 模型补丁

提示词里的补丁集中在 `src/session.zig` 的 `patches`，设置 `NIB_PATCHES_OFF=<id,...|all>` 可以关闭（子会话继承环境变量）。验证方法：关闭一段时间，再用 `scripts/stats.py --since` 和开启时的同期数据对比观察信号。

| id / 名称 | 位置 | 原因 | 观察信号 | 删除条件 |
|---|---|---|---|---|
| `json-escape` | 系统提示 Writing scripts | 模型在写含反引号、`${`、反斜杠的文本时，常用模板字符串导致 SyntaxError 或内容被改写 | stats 错误分类 `js_syntax` | 关闭后 `js_syntax` 没有明显上升 |
| `no-shell-search` | 系统提示 Writing scripts | 模型习惯调用 rg，而 rg 不在用户环境中，exit 127 | stats 错误分类 `command_not_found` | 关闭后 `command_not_found` 没有明显上升 |
| reflect 只报有证据的问题 | `src/tui/reflect.md` | 担心模型为完成反思而凑问题；草稿会自动公开发布 | 自动提交的 issue 中被关闭为无效或重复的比例 | 门槛措辞进一步精简后，误报率不上升（只能改模板验证，无开关） |

## 实现妥协

| 名称 | 位置 | 原因 | 删除条件 |
|---|---|---|---|
| 子 agent 深度上限 1 | `src/tools.zig`（agent 仅根会话可用） | 没有成本预算机制时，防止递归派生失控 | 有按预算限制的机制后改为预算 |
| bash 超过 256 个 shell 词即拒绝 | `src/tools/policy.zig` | 检查器按词切分整条命令，不单独识别 heredoc 正文，无法检查过长命令 | 检查器能跳过 heredoc 正文、或改为流式检查 |

## 写死的策略

这些是用户的预算和偏好，现在写成了常量，应进入 `config.toml`。

| 名称 | 位置 | 当前值 | 删除条件 |
|---|---|---|---|
| llm 限额 | `src/tools/llm.zig` | 每进程 4 并发、每 Run 100 次、单次 256 KiB | 可在 config.toml 配置 |
| agent 并发 | `src/tools/agent.zig` | 每进程 4 个，全部工具 8 并发 | 可配置 |
| 每 Turn 最多 Step 数 | `src/session.zig` `max_steps` | 50 | 可配置 |
