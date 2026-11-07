<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="nib" width="96">
  </picture>
</p>

<h1 align="center">nib</h1>

<p align="center"><a href="README.md">English</a> | 中文</p>

专注 coding 的小而美 agent，安静地和你一起写代码。

nib 以 Run 为工作单位：模型写一段 JavaScript，一步完成读取、修改和验证。

## 数据

与 Codex CLI 使用同一模型：

**快 12% · 费用低 44% · 请求少 32% · 20/20 通过**

**同时打开十个 agent：**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/bench-memory-dark.svg">
  <img src="docs/assets/bench-memory-light.svg" alt="十个空闲实例的总 RSS：nib 38 MB；pi 纯净版 1,134 MB；Codex CLI 1,164 MB；prime-agent 1,460 MB；Claude Code 1,750 MB；pi 日常扩展版 1,984 MB；dsh 5,459 MB。" width="880">
</picture>

5 MB 静态二进制 · 无运行时依赖。

*2026 年 11 月 · gpt-6.1-terra、medium · 对比 Codex CLI 0.166.0 共 20 次运行，按 API 价格计费 · 内存为空闲 TUI。*

[更多数据 →](docs/benchmarks.md)

## 安装

支持 Linux（x86_64、arm64）和 macOS（Apple 芯片）：

```sh
curl -fsSL https://raw.githubusercontent.com/yyydddkkk/nib-code/main/install.sh | sh
```

安装到 `~/.local/bin`，再跑一次即升级。`NIB_VERSION` 指定版本，`NIB_INSTALL_DIR` 更换目录。

从源码构建（Zig 0.17）：`zig build -Doptimize=ReleaseFast --prefix ~/.local`

## 使用

```sh
cd your-project
nib                          # 交互界面
nib ask '讲讲这个项目的入口'
nib -c                       # 继续本目录上次的会话
```

默认使用 Codex 登录；`/model` 可切换到 Claude、OpenAI、DeepSeek、Grok 或[自己的站点](docs/providers.md)。

Enter 发送，Shift+Enter 换行，Esc 取消。输入 `/` 查看指令：`/model`、`/effort`、`/undo`、`/tasks`、`/skills`、`/status`。`@` 补全文件路径。

项目约定写在 `AGENTS.md`，个人习惯写在 `~/.nib/AGENTS.md`。

## 一个 Run

```text
  Run · edit 2 files · bash
    src/grep.zig +38 −9 · src/tools.zig +2 −1
    read src/grep.zig · read src/tools.zig · grep src
    └─ b1 bash zig build test · 1s · completed ✓ exit 0

  1 Run · 2 steps · 41s · 6.6k tokens
```

每个脚本一个块：改了什么、读了什么、跑了什么。Ctrl+O 查看 diff、结果和脚本。

## 安全

nib 以你的权限运行模型写的代码。bash 会拒绝明显危险的命令，但这只是护栏，不是沙箱——开始前先提交。会话与工具结果记录在本机 `~/.nib/sessions`（权限 0600）；`NIB_RECORD=off` 关闭工具录制。

## 更多

[原则](docs/principles.md) · [文档](docs/README.md) · [Provider](docs/providers.md) · [配置](docs/config.md) · [版本说明](docs/releases/) · [MIT](LICENSE)
