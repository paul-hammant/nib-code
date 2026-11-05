# speed-v8：先同步受影响的引用，再验证

基于 speed-v7（63661bd），仅补充通用工程习惯，不识别特定任务、语言、命令或目录结构。依据是 final-B-notest 中遗漏工具列表断言、输出格式旧期望及新测试期望写错，以及 final-A-default 中对应的验证返工；这些是已有批次的观察，不是 speed-v8 的效果测量。

system 新增原文，位于现有全量验证顺序提示之前：

```text
- After changing externally visible behavior (names, signatures, output formats, lists/registries, config or error text), search for affected callers, test assertions, fixtures and docs; update them together before validation.
- Cross-check each expected value in new tests against the actual implementation, including when tests cannot be run.
```

第一条用可观察的变化限定搜索范围，明确包含调用方、断言、fixture 和文档，避免只改实现便开始验证。第二条要求逐项核对期望值，不能运行测试时仍可通过阅读实现完成。保留原有必要验证及失败后修复、复验的要求，不增加工具、配置或宿主机制。工具表不变；现有 system 渲染测试补充两条提示的断言。新会话采用新提示，恢复会话仍沿用日志中的原 system。

speed-v8 沿用 speed-v7 的 ReleaseFast、WebSocket、custom Run、16 KiB 展示预算及关闭 reasoning summary 的配置；独立临时 clone 构建，来源与摘要记录在 nib-bench 的 bins/speed-v8.json。

验证：`zig build`、`zig build test --summary all`（429/429）、`zig fmt --check src build.zig` 均通过；AGENTS.md 列出的 16 个 Python mock 端到端脚本全部通过。首次检查发现会话压缩 fixture 的 6144 窗口无法容纳增长后的 system；调整为 7168 窗口、6400 字节填充及对应的半窗口上限 3584，整个 test_session.py 复验通过，仍断言单次压缩和恢复消息一致。其他 15 个脚本的通过结果沿用。

改动文件为 src/session/prompt.zig、tests/test_session.py 和本文。未调用真实付费模型；mock/fake 验证不证明任务通过率或速度收益。
