# 0018 Codex custom Run 复用现有执行与历史

Codex 默认让模型直接输出 JavaScript custom 工具 input，减少 function JSON 字符串的转义负担；Chat Completions 保持 function。grammar 仅约束外层形式，不验证 JS，也不保证延迟或语法错误率。仅在完整 output_item.done 后把源码规范化为内部 `{code}`，复用 Sandbox、Session、录制及 replay，不增加第二种执行器。

保留已有一次性 effort 调度和用户上限，以可选首行 `// @run: {"effort":"low"}` 表达；该行原样留在源码和日志。失败或尚未完成的后台 Run 不应用降档。采用一个 custom 工具和显式 `NIB_CODEX_RUN_TOOL=function` 回退，避免让模型同时选择两种等价入口。

历史逐调用保留 custom/function 类型和原始参数，结果按各自类型配对；切换配置不转换旧历史、不丢失旧 effort 或加密 reasoning。工具定义变化仍可能失去部分缓存，恢复也始终使用完整历史和新连接。线上参数计时分别按原始 JS input / JSON arguments 字节计算，不能用内部规范化 JSON 长度直接比较。

配置、协议与错误诊断见 [Codex custom Run](../codex.md#custom-run-工具)。真实端点与本地 mock 已覆盖 custom 往返和 WS 增量；若服务端兼容性或脚本错误增加，可回退 function，仍保留已保存调用的原始类型。
