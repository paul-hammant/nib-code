# Skills

New Sessions scan in this order, looking only one level deep for `<name>/SKILL.md` in each directory; later skills override earlier skills with the same name:

1. `~/.agents/skills`
2. `$NIB_HOME/skills` (default `~/.nib/skills`)
3. `<project>/.agents/skills`
4. `<project>/.nib/skills`

project uses the same root as the project AGENTS.md. Symlink directories are supported; hidden directories and loose Markdown files are ignored.

SKILL.md uses the [Agent Skills](https://agentskills.io/specification) format:

```markdown
---
name: example
description: Describe when to use this skill.
---
Put specific instructions in the body.
```

name defaults to the directory name; description must be nonempty and supports plain, single-quoted, double-quoted, `|`, and `>` block text, retaining at most 1024 characters. Only files up to 64 KiB are read; other YAML fields are ignored. `disable-model-invocation: true` excludes the skill from the model index.

All skills are disabled by default. Enable each in `$NIB_HOME/config.toml`:

```toml
[skills]
example = true
```

Only `true` enables a skill; `false` or absence disables it. Enabled entries without corresponding files are excluded from the index; `/status` shows the missing count. `/skills` lists all discovered skills, sources, switches, and short descriptions; `/skills on <name>` and `/skills off <name>` atomically update global configuration, preserving other content. Skills with model invocation disabled cannot be enabled.

Switches affect new Sessions only; the current Session's system is unchanged. `/status`'s `Skills: N on · M found` shows counts from Session creation.

After AGENTS.md, system appends a name-sorted index only of user-enabled skills. For matching tasks, the model loads full instructions with `tools.read`, resolving relative paths against the skill directory. With no enabled skills (even if skills exist on disk), no prompt text or model calls are added. Each enabled skill's description enters every new Session's system prompt, so it costs index tokens even when unused.

Resumed Sessions retain their original system without rediscovering skills; file changes affect new Sessions only. `/status` shows enabled, discovered, and skipped counts; reasons are recorded in the Session log's `skills.skipped`, not the conversation.
