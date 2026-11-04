# Run 输出预算与条目

工具返回给 Run 内 JS 的数据不会为模型上下文而被截断。`read → JS 替换 → write` 仍然能原样处理完整的数据。`read` 的分页、grep/glob 的数量上限、fetch 的大小上限等，仍按各工具的显式约定执行。

## 模型看到什么

`src/session/output.zig` 为**整个 Run**生成最多 16 KiB 的 UTF-8 输出，包含标题、分隔符与省略标记。这也是 `run_end.output`、会话日志中的 tool content、下一次模型请求共用的文本；不是每次工具调用各有 16 KiB。

若用户设置了 `max_steps`，且剩余不多于 3 个 Step，Session 在上述格式化之后追加 `[N Steps left in this Turn]`。这行不占 16 KiB 预算，不会被截断；`run_end.output`、日志和下一次模型请求包含相同的完整文本。未设置上限时不追加。

输出较小时沿用原格式。需要截断时：

- 每次 `console.log/info/warn/error` 算一个条目，多个参数或多行文本仍是同一条。最终返回值／错误另算一条；成功时的 `undefined` 不占条目。
- 标题标出 `entry N of T` 和 `console/result/error`。短条目优先完整保留，其余正文平分剩余预算。长条目保留实际捕获到的头部和／或真实尾部，省略标记位于缺失位置；不会把捕获前缀的末端当作原始输出的尾部。
- 例如 `[entry 2 of 3 (console)]` 下的 `[25000 of 40000 bytes omitted]` 表示该条原始正文共 40000 字节，其中 25000 字节未展示；如果两数相等，整条正文被省略。标记中的字节数不含新增的标题或分隔符。
- console 的原始字节数是参数格式化、空格拼接并追加换行后的 UTF-8 字节数；结果／错误则按其序列化后的文本计算。UTF-8 修边造成的损失也计入省略字节数。

一次 console 打印整个结果数组仍只有一个条目。需要分别定位时，给每个结果单独打印标签；需要大量正文时，先在 JS 里过滤，或分成多个 Run 输出。

日志的 `tool_bytes` 统计宿主实际交给 JS 的工具结果 UTF-8 字节数（成功按序列化 JSON、错误按错误文本），不取决于 JS 是否使用或 await；未交回结果计 0，agent 只计父 Run 返回对象。`output_bytes` 则是交给模型的实际 tool result 字节数，包含 16 KiB 预算内的截断标记、错误、无输出提示与标签，以及预算外的剩余 Step 提示（若有），不是原始工具数据大小。

## 捕获上限

`src/sandbox/console.zig` 的 console 正文捕获上限为整个 Run 共用的 64 KiB：前 32 KiB 固定保留，后 32 KiB 是随输出更新的滚动尾部。单次超大调用与多次累计超限使用同一预算。UTF-8 边界修整只移除不完整字符，不额外占用正文预算；工具在 JS 内返回的数据不受影响。

调用明细也有界：不超过 64 次时全部记录；超过时保留前 32 次和最后 32 次，中间调用合并为一个范围，记录原始字节起止位置。例如 10000 次调用的中间范围为：

```text
[entries 33-9968 of 10000 (console)]
[19872 of 19872 bytes omitted]
```

范围中若仍有正文落在捕获的头部或尾部，会与其他条目一样参与展示预算分配；上例表示范围正文恰好全部省略。范围之后仍显示最后 32 次调用的明细，最终返回值／错误的编号继续按原始调用次数递增。正文、调用明细和格式化缓冲区的内存均不会随 console 调用次数无限增长。省略字节数同时包含捕获阶段和模型展示阶段的损失。

独立的 `nib js`、TUI `/js` 显示 sandbox 捕获的头尾，并在中间插入 `[console output truncated: N of T bytes omitted]`，其中 N 包含 UTF-8 修边损失。不套用模型侧 16 KiB 格式化；未超限时保持原输出。

## 工具返回的数据与显式上限

`read` 返回 `{ text, next_offset }`：按 offset/limit 原样返回请求的行，默认 2000 行，后续行起点单独放在 next_offset，EOF 时为 null；文件上限仍为 16 MiB。`bash` 的 `{ exit_code, output }` 中 output 原样返回，超过 16 MiB 报错并提示重定向到文件。工具自身明确约定的有界结果除外：grep 的文本/上下文行最多 500 字节，grep/glob 用 truncated 标记结果数量上限；fetch 的文本最多 1 MiB，返回 `{ url, status, content_type, text, truncated }`，truncated 明确表示正文不完整，提示不混入 text，下载超过 5 MiB 则报错。

搜索返回字段和 UTF-8 列定义见 [ADR 0012](adr/0012-search-and-fetch-tools.md)。

## Run 执行预算与取消

Run 的默认 5 分钟超时只累计 QuickJS 执行片段（初始脚本、Promise jobs、工具结果解析/resolve、返回值序列化和错误转换），不计算等待工具完成的时间，也不在每次 await 后重置预算。它用于中断 JS 死循环；bash/fetch/agent 的执行时限由各自工具负责。等待时仍每 20 ms 检查取消，Esc/SIGINT/SIGTERM 不受计时暂停影响。
