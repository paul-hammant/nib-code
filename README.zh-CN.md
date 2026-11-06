# nib

[English](README.md) | 中文

nib 是用 Zig 写的编码 agent，以 Run 为工作单位：一段 JavaScript 可以完成读取、修改和验证项目的一批工作。

## 安装与登录


需要 Zig 0.17。

```sh
git clone https://github.com/yyydddkkk/nib-code.git
cd nib-code
zig build -Doptimize=ReleaseFast --prefix ~/.local   # 安装到 ~/.local/bin/nib
nib --version
```



**Codex（默认）**：先用 `codex` 命令行完成 ChatGPT 登录，nib 会读取 `~/.codex/auth.json`，不需要 API key。默认模型 `gpt-6.1-sol`。详见 [docs/codex.md](docs/codex.md)。

**DeepSeek（Chat Completions）**：

```sh
NIB_PROVIDER=chat_completions DEEPSEEK_API_KEY=... nib
```

provider、模型和 effort 也可以写进 `~/.nib/config.toml`，见 [docs/config.md](docs/config.md)。

## 第一个请求

在项目目录运行：

```sh
nib
# 输入：解释这个项目的入口，先不要修改文件。
```

也可以一次性提问：

```sh
nib ask '解释这个项目的结构'
nib --help
```

Enter 发送，Shift+Enter 换行，Esc 取消。运行中可以继续发送要求，尚未送入模型的消息会标为 queued；取消后返回输入框。模型回复跟随你的语言，固定界面文字使用英文。

全局约定放在 `~/.nib/AGENTS.md`，项目约定放在项目根目录的 `AGENTS.md`。

## 如何读懂一个 Run

一个块对应一次脚本执行。下例的标题来自实际工具调用；次行列出文件改动和增删行数，之后是读取/搜索路径与命令结果。

```text
  Run · read ×3 · grep · edit 2 files · bash
    src/grep.zig +38 −9 · src/tools.zig +2 −1
    read src/grep.zig · read src/tools.zig · grep src
    └─ b1 bash zig build test · 1s · completed ✓ exit 0

  1 Run · 2 steps · 41s · 6.6k tokens · tool data 3.2MB → 18kB
```

`✓ exit 0` 只确认旁边的命令成功。子任务失败或超时会在 Run 标题提示；脚本正常返回不代表其中的验证都通过。后台 Run 显示 `Run · r3 running`，结果到达后更新原块。被取代的命令显示 superseded，不表示验证成败。

Ctrl+O 按 Changes / Result / Script 的顺序展开。结果可滚动查看；长 diff 明确标注 `Diff preview · 60 of … lines`。轮末统计只出现一次；底栏只保留模型与 context 百分比，详细计时和缓存看 `/status`。重试会移除失败尝试的正文，最终错误的 Details 也由 Ctrl+O 展开。

## 高级能力

- **代码驱动**：模型只有一个 `run` 入口，沙箱里的 `read`、`edit`、`write`、`grep`、`glob`、`fetch`、`bash` 可以在同一 Run 中并发、组合并过滤结果。工具数据完整交给 JS，进入模型上下文的展示预算见 [Run 输出](docs/run-output.md)。
- **纯模型调用**：`tools.llm` 不带工具与会话历史，适合并发分类、抽取和批量判断。
- **子 agent**：`tools.agent` 处理独立多步任务，失败作为数据返回，结果附带改动。`resume: "a1"` 接续同一个子任务，`fork: true` 从当前上下文分叉。
- **后台任务**：agent/bash 支持 `background: true`，长 Run 也可自动转后台；结果自动到达。长期进程可用 `detached: true`。`/tasks` 查看编号、状态和截止时间；`/stop <id>` 停止任务，可能保留部分改动。见 [TUI 任务管理](docs/tui-ux.md)。
- **撤销**：`/undo` 回退最近一轮的 edit/write 修改，包含子 agent，新建文件则删除；外部修改会使整轮撤销被拒绝。当前 TUI 实例保留最近 8 个有修改的 Turn，bash/脚本副作用不在范围内。快照超限或失败不阻止编辑，但该轮无法撤销。见 [撤销语义与限制](docs/undo.md)。
- **推理强度**：`/effort` 设置上限，模型可为下一步声明更低的 effort；Run 失败或用户插话后自动恢复。
- **日志与重放**：会话日志记录用量和耗时；`scripts/stats.py` 汇总统计；`nib replay` 离线重放工具录制，见 [重放](docs/replay.md)。
- **反思**：`/reflect` 复盘 harness，默认将 issue 草稿发布到公开仓库 `yyydddkkk/nib-code`。`NIB_ISSUE_REPO` 可指定仓库，设为 `off` 则只保存本地反思。帮助和菜单显示当前设置；见 [反思](docs/reflect.md)。

```sh
nib -c                         # 继续当前目录最近的会话
nib --resume <32位会话ID>       # 恢复指定会话
nib --effort high              # 本次进程的推理强度
nib ask --json '...'           # NDJSON 事件流
nib replay <会话ID> --all       # 离线重放
```

输入 `/` 查看按 Send / View / Session 分组的指令，`/help` 查看全部快捷键。用户消息带蓝色色条和适配终端主题的淡底色。鼠标拖选后松开即复制；按住左键滚动可跨屏选择。

当前版本 0.4.0，个人项目，仍在快速迭代。

## 安全


工具调用的结果默认录制在 `~/.nib/sessions/<id>.calls.jsonl`（权限 0600，只在本地），其中可能包含模型读过但没有回传的内容，比如 `.env`；不需要时设置 `NIB_RECORD=off`。

bash 有一层防误操作的检查：拒绝提权、关机、删除系统目录等命令，不读取 Codex 凭证。它是防止失误的护栏，不是安全沙箱，**nib 以你的用户权限运行模型生成的代码**。在重要的仓库上使用前，请确认工作区有提交或备份。

## 文档


- [docs/README.md](docs/README.md)：设计原则、决策记录（ADR）索引和暂缓的想法
- [docs/compromises.md](docs/compromises.md)：为当下做的妥协及其删除条件
- [docs/releases/](docs/releases/)：版本说明
- [AGENTS.md](AGENTS.md)：给参与开发的 agent 看的构建、测试命令和代码地图

## 许可证

[MIT](LICENSE)
