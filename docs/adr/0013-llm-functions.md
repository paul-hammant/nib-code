---
status: accepted
date: 2026-11-03
---

# tools.llm：轻量的单步 map 单元

Run 可用 `await tools.llm({ prompt, input, schema, model, effort })` 返回 `{ text, data, usage }`。它在当前进程由宿主调用 provider，一次请求一次回答，无工具、不带会话历史或项目指令。input 与 prompt 分开；model/effort 默认继承当前配置。它适合 `Promise.all(items.map(input => tools.llm({prompt: "Classify", input})))` 这样的批量判断、分类和抽取。

**为什么单独命名：** agent 是“去做事”：独立子进程、多步、带工具，可以调查或修改代码。llm 是“算一个值”：无需启动子进程、加载完整 agent 提示词或进入工具循环，补上 agent 对小型 map 任务过重的空缺。分开命名让调用者和模型直接看见能力与副作用边界，不靠一个模式参数切换语义。纯函数指执行边界，并不承诺模型确定性或零额度消耗。

**请求与结果：** 固定的短 system，不拼接 AGENTS.md；Codex 用原生 `text.format`（`json_schema`、strict），Chat Completions 用 `response_format.json_object` 加 schema 提示约束。schema 按原样提交，仍受服务端子集限制（如 Codex strict 对象需要 additionalProperties:false 和完整 required）；宿主只检查 JSON 可解析，不做完整 schema 校验；失败附解析错误重试一次，再失败则 reject，附最多 512 字节的原始输出片段。没有 schema 时 data 为 null。临时错误与主会话共用 provider 重试/退避；缓存 key 为 `<session_id>:llm`。用量与 agent 汇入同一个 Turn 累计路径，包含 JSON 修复请求；取消复用 provider 的可中断 I/O 路径。

**为什么限额保守：** Codex 消耗用户自己的订阅额度。一个短 map 容易放大成数百个并发请求，在确认成本与限流行为前先设同进程 4 个并发、每 Run 100 次调用、单次 prompt + 序列化 input 合计 256 KiB。超并发排队，排队不计请求时限；次数与字节超限直接 reject，不静默截断。常量集中在 `src/tools/llm.zig`；子 agent 同样有 llm，每个进程分别限流。provider 现有超时策略不变，Run 的 JS 执行预算不包含网络等待。

**为什么仍不跨 Run 保留状态：** 进程内变量或持久模型句柄无法从日志完整恢复，会破坏 `--resume` 的一致性；还会增加以后的流式执行、推测预取对隐藏状态顺序的依赖。Run 继续是无状态 map/组合单元，中间结果写 JSON 文件即可，沿用 [0003](0003-stateless-runs.md)。

**把握与重新考虑：** 两线路仅用本地 mock 验证请求格式、并发、JSON 修复、用量和取消，不把 mock 的延迟当成真实模型性能。在真实批量任务证明限额过紧、连接开销明显或需要更强结果保证时，再评估额度预算、连接复用或完整 schema 校验；暂不引入有状态会话句柄。
