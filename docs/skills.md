# Skills

新会话按以下顺序扫描，每个目录只找一层 `<name>/SKILL.md`，同名技能后者覆盖前者：

1. `~/.agents/skills`
2. `$NIB_HOME/skills`（默认 `~/.nib/skills`）
3. `<project>/.agents/skills`
4. `<project>/.nib/skills`

project 与项目 AGENTS.md 使用同一个根目录。支持符号链接目录，忽略隐藏目录和散放的 Markdown 文件。

SKILL.md 使用 [Agent Skills](https://agentskills.io/specification) 格式：

```markdown
---
name: example
description: Describe when to use this skill.
---
具体指令写在正文中。
```

name 缺省时取目录名；description 必须非空，支持普通、单引号、双引号、`|` 和 `>` 块文本，最多保留 1024 个字符。只读取最多 64 KiB 的文件；其他 YAML 字段忽略。`disable-model-invocation: true` 将该技能排除在模型索引外。

技能默认全部关闭。在 `$NIB_HOME/config.toml` 逐个启用：

```toml
[skills]
example = true
```

只有 `true` 表示启用，`false` 或缺省表示关闭；没有对应文件的启用项不进入索引，`/status` 显示 missing 数量。`/skills` 列出所有发现的技能、来源、开关及简短描述；`/skills on <name>` 和 `/skills off <name>` 原子写回全局配置并保留其他内容。禁用模型调用的技能不可启用。

切换只作用于新会话，当前会话的 system 不变。`/status` 的 `Skills: N on · M found` 显示本会话创建时的计数。

system 在 AGENTS.md 后仅为用户已启用的技能附加按名称排序的索引，模型遇到匹配任务时自行用 `tools.read` 加载全文，相对路径以技能目录为基准。没有启用的技能时（即使磁盘上有技能）不增加任何提示文字，也不增加模型调用；每个已启用技能的描述都会加入每个新会话的 system prompt，因此即使未使用也有索引 token 成本。

恢复会话沿用原始 system，不重新发现技能；修改文件只影响新会话。`/status` 显示启用、发现和跳过数量，原因记录在会话日志的 `skills.skipped`，不写入对话。
