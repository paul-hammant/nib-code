# 用户目录与配置

`NIB_HOME` 指定 nib 的用户目录，未设置时用 `$HOME/.nib`：

```text
~/.nib/
  AGENTS.md       全局指令
  config.toml     非秘密运行配置，可不创建
  sessions/       <32位小写十六进制ID>.jsonl 会话日志
```

不读取 XDG 配置或数据目录，也不搜索或自动迁移旧文件。需要保留旧指令、会话时，由用户自行放入新目录。`NIB_HOME` 不改变 Codex 凭证位置：仍读取 `$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`。

新会话按基础指令、`$NIB_HOME/AGENTS.md`、项目 `AGENTS.md` 的顺序拼接 system。项目目录从 cwd 向上取第一个 `.git` 标记所在目录，没有则用 cwd；恢复会话沿用日志内的 system。暂不读取项目级 `config.toml`，项目约定仍写在 `AGENTS.md`。

## config.toml

```toml
# 顶层键；均可省略
provider = "codex"
effort = "high"

[codex]
model = "gpt-6.1-sol"
base_url = "https://chatgpt.com/backend-api"
context_window = 500000

[chat_completions]
model = "deepseek-flash"
base_url = "https://api.deepseek.com"
context_window = 1000000
```

只使用当前 provider 的段落；切换 provider 不需要改写另一段。默认 provider 为 `codex`，其他默认值见上例；Codex 窗口随模型变化，未知模型需要显式提供 `context_window` 或 `NIB_CONTEXT_WINDOW`。

这是无额外依赖的 TOML 子集：支持空行、`#` 注释、单行双引号字符串（支持 `\"`、`\\`、`\n` 转义）、十进制整数（可带符号、下划线分组）和 true/false 布尔值；当前配置键只使用字符串和正整数，布尔值会报告类型错误。仅接受顶层 `provider`、`effort` 和 `[codex]` / `[chat_completions]` 下的 `model`、`base_url`、`context_window`。不支持数组、嵌套表、多行字符串等完整 TOML 语法；未知键、重复键/段落和格式错误会报配置文件路径与行号，不静默忽略。

配置文件不存秘密，也不接受 API key、token、密码或凭证字段。Chat Completions 的 key 使用 `NIB_API_KEY` / `DEEPSEEK_API_KEY`；Codex 使用现有登录文件。不要把秘密放进 URL。

## 覆盖优先级

从高到低：

1. CLI `--effort <level>`（TUI 启动和 `ask` 都支持）。
2. 环境变量：`NIB_PROVIDER`、`NIB_MODEL`、`NIB_BASE_URL`、`NIB_CONTEXT_WINDOW`、`NIB_THINKING`、`NIB_REASONING_EFFORT`。
3. `$NIB_HOME/config.toml`。
4. 内置默认值。

环境中设置 thinking 或 effort 时，不采用文件 effort。`NIB_THINKING=off` 优先于环境 effort；显式 CLI effort 又覆盖两者。未指定任何推理配置时使用服务端默认。CLI `--effort default` 清除本进程的 thinking/effort 覆盖，不修改文件。

子会话通过匿名 stdin 管道继承父会话的有效 provider/模型配置，跳过配置文件读取，不会因文件在中途变化而采用另一套配置；Codex 凭证仍由各进程独立读取。

## effort 持久化

`default|off|none|minimal|low|medium|high|xhigh|max` 可用于 `--effort` 或 TUI `/effort`；具体支持档位由模型/服务端决定。

- `nib --effort high`、`nib ask --effort high ...`：仅本进程生效，不写文件。
- TUI `/effort`：查询当前请求配置，不写文件。
- TUI `/effort high`：空闲时切换，后续 Turn 生效，并将顶层 `effort` 原子保存至 `config.toml`；只更新该值，保留其他配置行和注释，不把环境变量或有效配置整体序列化回文件。
- TUI `/effort default`：清除本进程 thinking/effort 覆盖，并移除文件顶层 `effort`，保留其余内容。下次启动仍按正常优先级解析，环境覆盖可能再次生效。

当前有效配置由子会话继承；摘要使用独立的最低推理策略。恢复会话采用本次启动的有效配置，但 provider 和 Codex 模型需符合日志的恢复边界，见 [codex.md](codex.md)。

写回先读入并校验当前文件，再按字节范围仅替换 effort 的值（删除键时保留同行注释）；缺失时插在第一个小节前的顶层末尾。完整内容写入同目录临时文件、sync 后 rename 替换，失败时清理临时文件，原文件不被部分覆盖。保存失败会在对话区提示，不撤销本次 effort 设置。没有跨进程锁：多个 nib 或外部编辑器同时保存时仍可能后写覆盖先写。配置文件上限为 1 MiB；不提供自动迁移和项目级配置。
