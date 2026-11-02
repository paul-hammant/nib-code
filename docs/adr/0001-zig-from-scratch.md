---
status: accepted
date: 2026-11-01
---

# Zig，从零开始

nibcode 用 Zig（当前 0.17.0）从零实现。pi、jcode、prime-agent、DeepSeek Harness 只作为设计参考，不复用代码。

**为什么：** 三个本地参考项目都不是 Zig（pi 是 TS，jcode 和 prime-agent 是 Rust），"二次开发"实际等于重写；而且它们的体量（jcode 约 93 万行、prime-agent 约 62 万行，2026-11-01 用 `wc -l` 统计源码）与"必要的极简"相反。选 Zig 是为了：C 互操作几乎无成本（QuickJS、未来可能的 tree-sitter）、单个静态二进制、按回合使用 arena 的内存模型、启动快、内存小。

**把握程度：**
- 实测：QuickJS-ng 只需编 4 个 C 文件即可链接；libvaxis 主分支支持 0.17；`nib js` 平均 1.6 ms、峰值 RSS 3.7 MB（见 [docs/README.md](../README.md) 度量表）。
- 已知代价（实测）：std 变动快。仅 0.17 一个版本就碰到 `Allocator.dupeZ` 改名为 `dupeSentinel`，以及 translate-c 无法翻译 QuickJS 的复合字面量宏（`JS_UNDEFINED`）。
- 推测：性能优势主要体现在启动、内存和多 agent 并行；单个任务的耗时由模型延迟主导，语言选择影响有限。

**何时重新考虑：**
- 跟进 Zig 版本升级的成本，持续超过写功能本身的成本；
- 关键能力在 Zig 生态里长期缺失且无法用 C 库补上（例如需要 HTTP/2，而 `std.http` 不支持）。
