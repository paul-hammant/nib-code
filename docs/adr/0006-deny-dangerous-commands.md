---
status: accepted
date: 2026-11-01
---

# 不审批，宿主侧直接拒绝危险命令

nib 不对 Tool 调用做逐次审批，也暂不做系统层沙箱（[0004](0004-two-layer-isolation.md) 暂缓）。但 bash 命令在执行前过一遍 `src/policy.zig`：命中危险类别的直接拒绝，错误返回给模型，提示"如确有必要，请用户自己执行"。不弹窗，不打断用户。

**拒绝的类别（用户选定，2026-11-01）：**
- 破坏性删除：对 `/`、`~`、`$HOME`、系统目录、`.`、`..` 的递归 `rm`；`mkfs`、`dd of=/dev/*`、`shred`、`wipefs`、分区工具。
- 提权和系统级：`sudo`、`su`、`doas`、`pkexec`、`shutdown`/`reboot` 等、`systemctl`；把下载内容交给 shell 执行（`curl … | sh`、`bash <(curl …)`、`sh -c "$(curl …)"`）。

**凭证边界：**
- `process.run` 在所有子进程启动前移除 `src/secrets.zig` 单一定义的常见 API key/token 环境变量，调用方提供环境也同样处理；保留普通环境变量。子会话通过 stdin JSON 接收 provider 配置，API key 不进入 argv 或子进程环境；Codex 配置不包含登录 token。
- bash 命令文本拒绝引用默认 `.codex`、`$CODEX_HOME` 和当前自定义凭证目录，覆盖通配符和递归扫描。read/edit/write 对默认及自定义凭证路径一律拒绝，并复用规范化路径识别符号链接；不会读取凭证内容后再过滤。
- 这些保护防止无意输出或破坏凭证，不是文件系统沙箱；变量拼接、任意脚本、其他进程读取和刻意绕过不在保证范围内。环境清理只覆盖维护的变量名单。

**明确不拦（用户选定）：** git 操作（包括 `push --force`、`reset --hard`），以及 edit/write 写入工作目录之外的路径。

**为什么：** 用户不想被审批打断，但不审批不等于放开危险操作。宿主侧拒绝既不打断，又能挡住最常见的灾难性误操作。

**把握程度：**
- 实测：`src/policy.zig` 的测试覆盖了拒绝和放行两个方向，例如 `rm -rf build`、`git push --force`、`curl … | jq` 放行；`bash -c 'rm -rf ~'`、`env FOO=1 rm -rf /`、`timeout 10 rm -rf /` 拒绝。
- 已知局限：这是对命令文本的模式匹配，**只防误操作，不防刻意绕过**，例如 `r''m -rf /`、变量拼接出的命令、脚本文件里的命令都检查不到。heredoc 正文里如果出现危险命令文本会被误判为要执行，这时模型可以改用 `write` 工具。

**何时重新考虑：**
- 出现误拦正常开发命令的情况：调整规则，并补上对应的放行测试；
- 出现规则没拦住的事故：评估是加规则，还是重启 [0004](0004-two-layer-isolation.md) 的系统层沙箱。
