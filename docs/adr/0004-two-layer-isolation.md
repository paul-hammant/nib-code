---
status: deferred
date: 2026-11-01
---

# 两层隔离

**暂缓（2026-11-01）：** 用户决定系统层沙箱暂时不做，改为宿主侧拒绝危险命令，见 [0006](0006-deny-dangerous-commands.md)。语言层隔离已实现并保留。以下是当初的方案，留作将来参考。

隔离分两层：语言层，Sandbox 里除 Tool 外没有任何宿主能力；系统层，bash 和文件类 Tool 在 Linux 上用 Landlock + bwrap 限制。先只支持 Linux。

**为什么：** 只要有 bash 这个 Tool，语言层隔离就挡不住任何事，系统层不可省。反过来，语言层让 Sandbox 只能通过 Tool 影响外界，而每次 Tool 调用都经过校验、写日志，这让审计和将来可能的限制策略有了唯一的关口。

**不做审批：** 用户决定不需要逐次审批 Tool 调用（2026-11-01）。安全只靠这两层隔离和日志。

**参考：** DeepSeek Harness 依赖系统层沙箱（Linux 上 bwrap + Landlock），并明确否定 `node:vm` 作为安全边界（**二手**：第三方博客，未核实）。它否定 `node:vm` 的理由，是 vm 与 Node 共享全部系统能力；这一点不适用于不加载 quickjs-libc 的 QuickJS。

**把握程度：**
- 实测：语言层。`src/sandbox.zig` 中的测试确认 `require/process/std/os/fetch` 均不存在。
- 未实现：系统层。Landlock 与 bwrap 的具体组合、对网络的限制方式、在用户机器上的可用性都还没验证。

**何时重新考虑：**
- 目标机器上 bwrap 或 Landlock 普遍不可用；
- 系统层限制导致常见开发任务（构建、测试、包管理）频繁失败，需要重新划定边界。
