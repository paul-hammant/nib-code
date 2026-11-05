# 0017 Codex 默认 WebSocket，续接状态可丢弃

Codex Responses 默认使用 Session 独占 WebSocket，以复用连接和已完成响应的前缀；显式 SSE 及握手/帧协议失败后的 Session 级 SSE 降级仍可用。v7 正式 bench 已验证这组配置，0.4.0 将二进制默认值对齐；具体实验数据留在相邻 `nib-speed-notes/`。连接错误、响应字段校验失败沿用 WS 重试，避免把一次内容错误误判成永久不兼容。

Zig 0.17 没有标准库 WS 客户端，最小 RFC 6455 帧层复用 `std.http.Client` 的 TCP、代理、TLS/证书和连接所有权。Session 同时只有一个主请求，不增加连接池、预热线程或服务器会话存储。只有同连接、前次完成、非 input 属性一致且历史以前次 input + 有序 output 为前缀时，才发送 previous_response_id 与增量 input；后台消息追加在后，waiting 元数据不上线。

日志始终保存完整历史及服务端有序输出，不从合并的展示文本重建前缀；这也保留交错 reasoning/commentary、多条消息及 custom/function 调用。取消、断线、压缩或 scope 变化后可安全丢弃续接状态，恢复/fork 不复制连接。代价是首次请求、重连和前缀变化仍发送完整历史；不以服务端缓存命中作正确性前提。

协议来源、限制和本地验证见 [Codex 传输](../codex.md#responses-websocket-传输)，逐 attempt 及全量原因见 [日志](../session-log.md#step-传输字段)。若实际代理/网关兼容性或降级成本抵消收益，重新考虑默认传输；`NIB_CODEX_TRANSPORT=sse` 可直接回退。
