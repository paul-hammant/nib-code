# 工具录制与离线 Run 重放

`nib replay` 在新 QuickJS 沙箱里重跑会话中保存的 JavaScript，用录制的工具返回值替代真实工具。它适合检查 Run 的控制流、结果处理、输出格式和第一次调用分歧；不请求 provider，不运行模型，也不重新执行 read、grep、bash、fetch、write、llm 或 agent。

## 使用

```sh
# ID 为完整的 32 位小写十六进制会话 ID
nib replay <session_id> --run 1:0
nib replay <session_id> --run 1:0 --json
nib replay <session_id> --all --json
nib replay <session_id> --run 1:0 --script diagnose.js --json
```

`--run <step>:<run>` 的两个数字使用不同基数：

- `step`：整个会话中 assistant **Step 的 1-based 序号**，包括无 Run 的最终回答；跨 Turn、恢复会话继续计数。它不是每个 Turn 从 1 重置的 `turn_step`，也不是 JSONL 行号。压缩或修复日志重写的保留消息不再计作新 Step。
- `run`：该 assistant 消息的 `tool_calls` **0-based 数组索引**，不是 Run 内工具的调用序号。

例如首个 assistant Step 有两个 Run，分别是 `1:0` 和 `1:1`；下一 Step 是最终回答，恢复后的新 Turn 首个 Run 就是 `3:0`。

`--run` 和 `--all` 二选一；`--script` 只与 `--run` 一起使用。重放仅依赖 `NIB_HOME` 定位日志，不需要 API key 或可用 provider。默认用户目录见 [config.md](config.md)。

### 严格重放

不带 `--script` 时运行主日志内保存的原始 Run 代码。每个工具调用按创建顺序匹配录制的 `index`、工具名和 JSON 参数；参数按结构比较，对象键顺序不重要，数组顺序重要。工具 Promise 按录制的 `seq` 顺序兑现或拒绝，复现并发代码观察到的结算顺序，而不是原来的墙钟耗时。第一次不匹配记录为 `divergence`，不继续尝试真实工具。

`tools.sleep(ms)` 也按标准工具调用录制参数、返回值或拒绝；重放使用录制结果，不启动真实计时器、不等待指定毫秒数。它不会推进重放中固定的 `Date.now()`，因此轮询应有次数上限，不要只依赖墙钟截止时间。

完成后，按正常 Run 输出规则格式化结果，并与主日志里对应的 tool 消息逐字节比较。调用匹配但最终输出不同也会报告分歧；因此 `match` 不只是“工具参数相同”。

### 诊断脚本

`--script diagnose.js` 用文件里的代码替换原 Run，仍在离线沙箱运行。工具按**工具名 + JSON 参数**查找该 Run 的录制值，命中可重复使用，不要求遵循原调用顺序，也不消耗条目。相同参数出现多次时使用首先找到的条目；脚本模式不用于还原原始竞态。

未命中返回 rejected Promise，错误文本含 `not recorded`；可以用 `try/catch` 检查，不会回退到真实文件、命令或网络访问。例如：

```js
const first = await tools.read({path: "sample.txt"});
console.log(first.text);
try {
  await tools.read({path: "not-in-this-recording.txt"});
} catch (e) {
  console.log(e.message);
}
```

脚本改变了程序，输出不与原 Run 作等价判断，`match` 为 `null`。

## 文件与格式

录制默认开启，`NIB_RECORD=off` 关闭；其他取值与未设置一样开启。不新增 TOML 配置项，关闭不会删除既有记录。子会话继承环境，但分别写自己的 calls 文件。

每个会话使用两个独立文件：

```text
$NIB_HOME/sessions/<session_id>.jsonl        主日志：消息、代码与模型看到的 Run 输出
$NIB_HOME/sessions/<session_id>.calls.jsonl  旁路：工具调用与实际返回值，创建权限 0600
```

旁路按 Run 追加 JSONL，在 Run 结束时 flush、sync。主日志在整个 Step 完成后才提交；若进程在同一 Step 的后续 Run 中崩溃，旁路可能领先主日志。恢复后的首次录制以主日志确定的新 Step 为界，截掉旁路中首条 `step >= 新 Step` 的行及其后全部内容，只从保留部分重建去重集合。同一 Recorder 的后续 Run 不再执行恢复扫描，因此不会删除本次执行中尚待 Step 提交的前序 Run。即使一个 Run 没有调用工具，也保存一条元数据，供纯 JS 和时间相关代码定位。录制失败会警告并关闭后续录制，不把磁盘故障变成工具或会话失败；没有旁路文件的旧日志仍可恢复，但不能凭空补出录制结果。

每行都有 `step`、`run`。每个 Run 先写零条或多条调用行，**末尾只写一条元数据行**；没有 `type` 字段，也没有单独的 start/end 行。

| 行 | 字段 | 含义 |
| --- | --- | --- |
| 调用 | `step`, `run`, `index`, `seq`, `name`, `args`, `ok`, `result` / `error` | 一次工具调用的实际返回或拒绝，可附 `sha256`、`truncated` |
| 元数据 | `step`, `run`, `meta: {start_ms_epoch, end, incomplete?}` | Run 开始的 Unix 毫秒时间及终止原因：`ok`、`error`、`timeout` 或 `cancelled`；有工具已创建但未交回 JS 时才附 `incomplete: true` |

`index` 从 0 开始，是 Run 内工具 Promise 的创建顺序；`seq` 从 0 开始，是 JS 实际观察到的结算顺序。二者在并发调用时可能不同。`args` 是 JSON 值，不是 JSON 字符串。`ok=true` 时首次 `result` 是**序列化工具返回值的原始 JSON 文本字符串**；相同结果再次出现时是对象 `{"same_as":"<sha256>"}`，引用位于 `result` 内，不是顶层字段。`ok=false` 时 `error` 始终是拒绝文本，**不去重**。重放分别把它们还原成 JS 值或 rejected Promise。

```json
{"step":1,"run":0,"index":0,"seq":0,"name":"read","args":{"path":"a.txt"},"ok":true,"result":"{\"text\":\"hello\"}","sha256":"<sha256>","truncated":false}
{"step":1,"run":0,"index":1,"seq":1,"name":"read","args":{"path":"a.txt"},"ok":true,"result":{"same_as":"<sha256>"},"sha256":"<sha256>","truncated":false}
{"step":1,"run":0,"index":2,"seq":2,"name":"bash","args":{},"ok":false,"error":"denied","sha256":"<error-sha256>","truncated":false}
{"step":1,"run":0,"meta":{"start_ms_epoch":1700000000123,"end":"ok"}}
{"step":1,"run":1,"meta":{"start_ms_epoch":1700000000456,"end":"ok"}}
```

结果按完整原始 JSON 文本的 SHA-256 在同一会话内去重，跨 Run、跨恢复会话有效；恢复录制时从已有调用行的 `sha256` 重建结果哈希集合，不把 reject 纳入。引用只能指向前面已经出现的结果；内部加载后映射为独立的 `result` 字符串与 `same_as` 引用，重放核心不依赖磁盘表示。

每个首次 result、每次 error 最多保留 **1 MiB（1,048,576 字节）**，在 UTF-8 边界截断并标记 `truncated=true`；`sha256` 仍是完整原始文本的哈希，不是前缀的哈希。error 也选择截断以限制磁盘占用，但无论是否重复都保留文本，不改成引用。截断可能使 result 不再是合法 JSON，重放会把这种前缀作为 JS 字符串返回。引用会继承原结果的截断状态。

1 MiB 限制针对单项保留的原始文本，不是整行 JSONL 的编码体积；JSON 转义可能使行更大。参数保持完整，不设单独上限；暂不设整 Run 或会话总量上限、不自动轮转。Run 内先在内存累积，结束后同步写盘，大量调用仍会增加内存和磁盘占用。

只在统一的工具结算交付路径录制结果，不记录 worker 已完成但未交回 JS 的真实结果。eval 退出时比较工具创建总数与已交付总数；不相等时在 `meta` 附 `incomplete: true`，即使缺少的是最大 `index`、现有调用行没有中间空洞，也能判断录制不完整。用户取消或 JS 执行超时可能留下未交回的调用。普通 `error` 不会停止其他调用：`Promise.all` 中 read 拒绝时仍等待 bash 结算，创建工具后直接 throw 也继续 drain，因此这些错误 Run 的录制完整，仍可判定匹配。缺项时报告 `incomplete=true`、`match=null`；重放发现的 `divergence` 保留供诊断，但不能把它视为确定分歧。

加载器可以先接收调用行，再由末尾的 `meta` 补齐该 Run。缺失 `meta`、缺失引用、截断的条目会令报告 `incomplete=true`；缺失元数据时不推测时间（内部占位为 0），不把基于不完整数据的运行宣称为完整匹配。`--all` 只遍历所有有旁路记录的 Run，包括只有元数据、没有调用的 Run；`total` 不含 `NIB_RECORD=off` 时未录制的 Run，不据此统计主日志里的全部 Run。录制上限不改变原 Run 内 JS 获得的数据，也不改变模型侧的 Run 展示预算，见 [run-output.md](run-output.md)。

## JSON 报告

`--run ... --json` 输出一个 JSON 对象，不是 `ask --json` 的 NDJSON 事件流：

```json
{"run":"1:0","match":true,"incomplete":false,"uses_time":false,"uses_random":false,"output":"...","end":"ok"}
```

| 字段 | 含义 |
| --- | --- |
| `run` | `step:run` 定位字符串 |
| `match` | `true` 完整重放并与原输出相同；`false` 可判定分歧；`null` 无法判定或脚本模式 |
| `divergence` | 可选，首次调用/结算或最终输出分歧的描述；调用分歧含 index、expected name/args、actual name/args；少调用时列第一条未调用记录与 `actual no call`，多调用时为 `expected no call` |
| `incomplete` | 录制或结算不完整，不能把重放视为完整证据 |
| `uses_time` / `uses_random` | 重放代码是否访问被替换的时间或随机 API |
| `output` | 正常 Run 格式化后的输出，包括捕获的 console |
| `end` | 可选，原 Run 的终止原因 |

实现可为缺失的可选字段输出 `null`。`--all --json` 输出汇总对象：`total`、`matched`、`divergences`、`undetermined`，以及各 Run 的 `reports` 数组和分歧列表 `differences: [{run, divergence}]`。`divergences` 保留为可判定分歧的数字计数；`differences` 列出实际发现的调用或输出分歧（不完整记录中发现的调用分歧也保留，不算可判定匹配）。无法判定项单列，不算 matched；缺少元数据、原代码或对应 tool 结果时不能用空值冒充成功。

plain 单 Run 显示 `match`、`diff` 或 `undetermined`，必要时附 `incomplete`；原始结束原因为 timeout/cancelled 时显式显示 `end=timeout` / `end=cancelled`。plain `--all` 在汇总后逐项列出分歧和异常结束原因。

### 时间与随机数

重放的 `Date.now()` 及无参数 `new Date()` 固定为 `start_ms_epoch`，同一个 Run 两次访问返回相同时间；`Math.random()` 使用确定性替代值。访问时分别标记 `uses_time` / `uses_random`，便于解释输出分歧。它们不是原始 Run 每次访问的值：依赖真实时间推进、原始随机流或外部调度的程序可能无法逐字节匹配。超时、取消及不完整记录也不能据此宣称复现了原始执行。

重放使用与普通 Run 相同的默认沙箱 limits（包括默认 5 分钟 JS 执行预算）。原取消信号与真实工具耗时不会重放，因此不保证在相同位置超时或取消；即使重放顺利结束，原记录仍标为 incomplete、match 为 null。

## 隐私和能力边界

- 默认录制意味着磁盘会多一份**工具实际返回值**。它可能含模型侧截断后未展示的代码、文件全文、bash 输出、URL、个人信息或凭证。`0600` 限制同机其他用户访问，不是加密，也不防当前用户、备份程序或主动读取它的工具。
- 旁路文件不自动加入 provider 请求、恢复历史或 `/reflect` 输入。反思提示只允许读明确指定的本会话主日志，不枚举 sessions 目录，不读取 calls、兄弟或子会话日志；会话列表与 stats 也跳过 calls 文件。公开 issue 仍经过原有脱敏。这是提示词与数据流边界，不是针对恶意模型的文件访问沙箱。
- 关闭录制不删除既有文件。分享、备份或清理会话时分别检查主日志与旁路文件；主日志已脱敏不代表旁路也已脱敏。不要把 `.calls.jsonl` 上传到公开 issue。
- 重放**不能重放模型**、恢复推理过程或检验另一个模型会怎样决定；保存的是已执行的 Run，不是可重复的 provider 请求。
- 重放**不能验证工具实现**或外部系统是否正确；工具返回值是输入数据，不会重新读取当前文件、重新请求网络或校验当前 bash 行为。
- 重放**不能重现 bash 副作用**，也不会再次编辑/写入项目。匹配只说明这段 JS 在录制结果与重放语义下得到同样输出，不证明真实世界状态相同。
- 后台任务（`background: true` 的 agent/bash）只录制启动时交回 JS 的 `{ id }`；它们之后作为消息插入的结果不经过 Run，不在 calls 录制中，已写入主日志。

本地 mock、固定时间、首次参数分歧与 `/reflect` 特殊标记隐私回归测试：`zig build` 后运行 `python3 tests/test_replay.py`。

自动后台 Run 的录制仍使用启动时的全局 Step/Run 编号，多个 Run 的录制块可能按完成顺序乱序追加。每个 Run 内 index/seq 与统一结算出口不变。会话恢复整理所有未提交 Step 的录制，保留夹在其后的已提交早期 Step；跨 Run 去重不引用更晚 Step 的数据。replay 不等待真实阈值、不启动后台任务，用已提交后台消息中的 background_run.output 比较完整脚本的最终输出；未送达时不拿提前通知作期望值。取消或丢失且录制不完整时仍报告原有的不完整/停止语义。

自 speed-v5 起，calls footer 的 `meta.run_output_bytes` 保存该 Run 的展示预算；离线 replay 使用原值，旧录制缺省为 16384。只影响输出格式化，不截断录制工具数据。
