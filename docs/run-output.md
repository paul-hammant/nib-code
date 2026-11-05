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

## 文件替换、会话版本与跨进程协调

`edit` / `write` 先把完整内容写入目标所在目录的随机 `.nib-*` 临时文件，再通过同目录 rename 原子替换目标；失败时清理临时文件。已有文件的权限位保留，路径中的符号链接会跟随到实际目标，链接本身不被替换。替换产生新 inode，因此会打断目标与其他硬链接的共享关系：其他硬链接仍指向旧内容。文件工具不执行 fsync；原子可见性不等于断电后的持久性保证。配置写回仍保留原有 fsync 行为。

会话按规范化后的实际路径记录最近观察到的 inode、size 和纳秒精度 mtime。成功的 `read`（包括只读一页）、`edit`、`write` 都更新这份状态。`write` 覆盖已有目标时对比当前文件与已记录版本；若已有外部改动则拒绝覆盖，要求先重新 `read`，基于新内容再写。尚未观察过的已有文件仍允许直接 `write`，目标不存在时按新建处理。`edit` 在锁内读取最新内容并匹配 old_text，不用旧的会话快照替换文件；成功后也更新版本。

`read` / `edit` / `write` 使用同一套跨进程 advisory lock：锁文件位于 `$NIB_HOME/locks/`（默认 `~/.nib/locks/`），文件名为目标规范路径的 SHA-256 十六进制摘要。同一 NIB_HOME 下，独立 nib 进程、子 agent 与相对路径／符号链接别名因此协调到同一把锁。`read` 也持锁，使返回内容与记录版本在参与协议的写入者之间保持一致。锁文件持久保留，释放时只解锁／关闭，不 unlink，避免等待者与后来者锁住不同 inode。等待锁时仍响应取消。

这些锁只协调遵守协议且共用 NIB_HOME 的文件工具；bash、用户编辑器与其他外部程序不会自动参与。版本检查能发现检查前已经发生的改动，但检查到 rename 之间仍可能被不合作的写入者抢先修改，因此不能提供对任意外部并发写入的绝对保护。需要保留外部结果时，先等待外部工作完成并重新读取，再修改文件。

本地端到端回归不需要 provider 或 key：构建后运行 `python3 tests/test_files.py`。测试使用临时 NIB_HOME，覆盖多进程高频 edit、路径别名／符号链接、过期 write 与重新读取、分页版本记录、权限／硬链接、锁等待取消和原子替换的并发读取。

## Run 执行预算与取消

顶层 Run Promise fulfill 或 reject 后都继续 drain：等待在途及排队工具完成，执行剩余 JS jobs，并接纳 continuation 新发起的工具调用，直到没有剩余工作。任意调用失败都不会取消其他调用（不只子 agent 失败）；顶层 reject 时，Run 最终仍报原始拒绝原因，不被后续完成或失败覆盖。因此 `Promise.all` 提前 reject 不代表并行副作用停止，失败的 Run 也可能继续写文件；前台 agent 仍需等待完成并计入用量，等待期间用户仍可按 Esc 取消。后台任务的跨 Run 生命周期见 [tool-delegation.md](tool-delegation.md)。

只有用户取消或 JS 执行超时才中止 Run 内工具；工具自身超时只终止该调用，不取消其他调用。中止时如有未完成调用，Run 输出保留一行：

```text
[stopped before completion: bash #0, agent #2]
```

这里的索引按该 Run 内全部工具调用的创建顺序从 0 开始，不是各工具独立编号，也不是后台任务 id；已交回 JS 的调用不列入，未交回的调用（包括仍在排队或已产生结果但尚未交回的调用）按创建顺序列出。这行最多 4 KiB；清单过长时用 `..., N more` 明示剩余调用数，为错误和 console 保留空间。整行预留模型侧 16 KiB 输出预算，不会被正文截断，用于区分报错前已完成的副作用与可能留下半成品的调用。普通 fulfill/reject 的 drain 完成不会产生这行。

Run 的默认 5 分钟超时只累计 QuickJS 执行片段（初始脚本、Promise jobs、工具结果解析/resolve、返回值序列化和错误转换），不计算等待工具完成（包括 `tools.sleep`）的时间，也不在每次 await 后重置预算。它用于中断 JS 死循环；bash/fetch/agent 的执行时限由各自工具负责。等待时仍以不超过 20 ms 的间隔检查取消，Esc/SIGINT/SIGTERM 不受计时暂停影响。

## Run 内延时与轮询

`await tools.sleep(ms)` 返回 `null`；`ms` 必须是 `0..2147483647` 的整数（毫秒）。缺少参数、非数字、非有限值、小数或越界值都会使 Promise reject，不做类型转换。`0` 也走异步调度。

延时由 sandbox 原生事件循环计时器完成，不启动进程或线程，也不占工具并发槽；优先用它代替 `bash` 执行 `sleep` 或 JS 忙等。等待本身不调用模型、不产生 token 用量，但仍增加 Run 的墙钟耗时；JS 执行预算在等待期间暂停，轮询中的 JS 执行仍累计，read/fetch 等调用仍有各自成本。

例如轮询本地服务的 HTTP 状态，最多检查 10 次，相邻检查之间等待 1 秒；非 200 状态重试，连接等错误仍会 reject 并终止 Run：

```js
let ready = false;
for (let attempt = 0; attempt < 10; attempt++) {
  const result = await tools.fetch({url: "http://127.0.0.1:8080/health"});
  if (result.status === 200) {
    ready = true;
    break;
  }
  if (attempt < 9) await tools.sleep(1000);
}
if (!ready) throw new Error("service not ready after 10 checks");
console.log("service ready");
```

与其他已调度工具一样，正常结束 Run 前会排空待完成的 sleep，即使没有 `await`；它不是跨 Run 的后台任务。用户取消或 JS 执行超时时会及时丢弃未到期计时器，不等延时结束；顶层 Promise reject 时，已发出的工具调用继续排空，但未到期的计时器直接丢弃（计时器本身没有副作用，它的后续逻辑尚未开始）；取消检查沿用上述不超过 20 ms 的间隔。sleep 走标准工具计时、结果字节统计和录制/重放路径；重放按录制结果结算，不实际等待，见 [replay.md](replay.md)。

## 长 Run 自动转后台

模型发起的 Run 超过 `[limits].run_background_after_ms`（默认 10000 ms）且沙箱仍在等待工具或 sleep 时，整个 Run 自动转后台，分配会话级 `r1…` ID。当前 Step 收到明确的“仍在执行、稍后投递最终输出、只做确实独立的工作、不要轮询或重跑”通知。它是成功登记的通知，不代表脚本执行成功。连续执行的 JS 不在中途转后台，仍受 JS 执行预算限制；工具等待和主线程轮询以约 20 ms 为粒度。

原 Sandbox、Promise、工具参数与结果保持原样：`const r = await tools.bash(...); if (r.exit_code) ...` 的 continuation 仍收到完整 `{exit_code,output}`，不会收到任务 ID。顶层 fulfill/reject 的 drain、JS 执行预算、工具超时和输出捕获上限均保持原语义。阈值之前与之后的 console 一起捕获，只在最终结果中展示一次；提前通知不展示部分 console。

后台 Run 使用自己的取消标记、llm 调用限额、changes、计时和录制缓冲；Session 的 agent 并发、后台 bash 并发、任务 ID、文件观察状态和用量仍共享。最多同时有 8 个自动后台 Run，独立于后台 bash 的 8 个上限；达到上限时新 Run 保持前台等待，不失败、不排队转后台。每个 Sandbox 仍最多同时执行 8 个工具。后台 Run 本身不消耗额外 Step，之后的主模型请求仍逐次消耗 Step。

结束后用同一个 `session/output.zig` 格式化器生成最多 16 KiB 的最终输出，通过 Inbox 插入 `[background run rN finished]` 后接完整格式化输出的 user 消息；来源前缀是预算外的信封。通知和最终输出各展示一次。没有独立工作时，模型应以极短、无工具调用的回复结束当前 Step。该回复保留在历史中并标记 `waiting:true`，作为 notice 展示，不作为最终答案；Session 在本地等待 Inbox，不额外请求模型，结果送达后自动继续下一 Step。普通后台任务同样适用；detached bash 不触发等待。等待期间仍可取消或接收用户插话。Step 上限收尾先等结果送达，不额外请求模型。Esc/SIGINT/SIGTERM、Turn 失败、Session 退出或切换都会取消并 join Run 及其工具，bash 按原有进程组规则清理；SIGKILL 无法执行清理。`tools.stop({id:"r1"})` 也可停止另一个后台 Run，仍投递取消结果；不能停止当前 Run 自己。取消不会回滚已发生的 edit/write 或 shell 副作用。

后台 Run 的所有成功 edit/write（含转后台之前）只归属该 Run，最终结果事件与日志的 `completion.changes` 保存按操作累计的计数和 diff；临时通知不提前领取 changes。TUI 在后台结果中显示输出与这些改动，恢复也能显示；子 agent 的调用结果同样汇总这些改动。bash 的改动继续不计入 changes。

多个 Run 共享 cwd，可能同时使用或修改文件。file_state 的互斥锁保证状态表安全，路径锁串行化单次 read/edit/write，write 能发现当前会话最近观察之后的外部改动；但会话内别的 Run 的 read/write 会更新同一观察状态，因此它不是每个脚本独立的乐观事务，也不能检测所有 Run 间语义冲突。bash 更不参与文件锁。等待时只做独立工作（审阅 diff、修改无关文档、准备下一步），不要改动后台 Run 可能使用的文件；收到结果后重新 read 再修改。

进程退出后不恢复 JS 堆或重启命令，未送达任务按原后台机制恢复为 lost；已经提交的结果不重复投递。离线 replay 不重现墙钟切换：按原 Step/Run 定位录制，重放完整脚本，比较最终输出。最终结果尚未提交时，不把提前通知当成脚本的期望输出。
