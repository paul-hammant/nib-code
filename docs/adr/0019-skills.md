# 0019: Skill index and on-demand reading

## Decision

While reading AGENTS.md, new Sessions scan fixed global and project skill directories. Only skills individually enabled by the user in global `[skills]` configuration append a name, description, and absolute-path index to system. The model matches task descriptions and reads SKILL.md through existing `tools.read`; relative resource paths resolve against the skill directory. Resumed Sessions retain their original system.

## Reasons and tradeoffs

Reuse existing file tools and Session mechanisms, adding no tools or concepts beyond skills, only global `[skills]` switches. Skills default to off: nib stays restrained and unselected content stays outside model context. Omit the index entirely when no skills are enabled; otherwise pay context costs only for descriptions and paths, without automatic model requests or body loading. Project skills override global ones so project conventions take priority.

Parse only needed frontmatter fields, without a full YAML library, package management, or ignore files. `/skills` lists discoveries; on/off subcommands reuse atomic configuration writes, avoiding another interactive selector. Switches affect new Sessions only. Defer skill-execution slash commands; models read enabled skills according to the task. Log skip reasons; the status page shows counts only.
