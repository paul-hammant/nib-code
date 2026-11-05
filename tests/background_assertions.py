"""Byte-accounting assertions shared by background tool E2E tests."""
from mock_llm_tool import content
from test_llm import records


def root_records(home):
    for path in (home / "sessions").glob("?" * 32 + ".jsonl"):
        log = records(path)
        if any(m.get("role") == "user" and m.get("content") == "initial"
               for r in log for m in r.get("messages", [])):
            return log
    raise AssertionError("root session log not found")


def assert_background_bytes(test, log, requests, terminal=None):
    steps, pending, seen, logged = [], [], [], []
    for record in log:
        background = [m["content"] for m in record.get("messages", [])
                      if m.get("source") == "background"]
        logged.extend(background)
        if "model_ms" not in record:
            if background or "background" in record:
                for key in ("tool_bytes", "output_bytes", "run_results"):
                    test.assertNotIn(key, record)
            pending.extend(background)
            continue

        request = requests[len(steps)]
        delivered = [content(m) for m in request["messages"]
                     if content(m).startswith("[background ")]
        newly_delivered = [text for text in delivered if text not in seen]
        test.assertEqual(pending, newly_delivered)
        seen = delivered
        runs = record["run_results"]
        outputs = [m for m in record["messages"] if m["role"] == "tool"]
        test.assertEqual([r["tool_call_id"] for r in runs],
                         [m["tool_call_id"] for m in outputs])
        for run, message in zip(runs, outputs):
            test.assertEqual(run["output_bytes"], len(message["content"].encode("utf-8")))
        test.assertEqual(record["tool_bytes"], sum(r["tool_bytes"] for r in runs))
        if not record.get("calls_omitted"):
            test.assertEqual(record["tool_bytes"],
                             sum(c["result_bytes"] for c in record["calls"]))
        test.assertEqual(record["output_bytes"],
                         sum(r["output_bytes"] for r in runs) +
                         sum(len(text.encode("utf-8")) for text in newly_delivered), record)
        test.assertFalse(background, record)
        steps.append(record)
        pending = []

    test.assertTrue(steps)
    test.assertEqual(logged, [content(m) for m in requests[-1]["messages"]
                              if content(m).startswith("[background ")])
    if pending:
        test.assertIsNotNone(terminal)
        test.assertIn("message", terminal)
        delivered = [content(m) for m in requests[len(steps)]["messages"]
                     if content(m).startswith("[background ") and content(m) not in seen]
        test.assertEqual(pending, delivered)
    if terminal is not None:
        test.assertEqual(terminal["steps"], len(steps))
        for key in ("tool_bytes", "output_bytes"):
            test.assertEqual(terminal["timing"][key], sum(step[key] for step in steps))
    return steps


def stop_result(id, stopped):
    result = dict(id=id, stopped=stopped, reason='mock requested cancellation')
    if stopped:
        result['notice'] = 'Task canceled; unfinished validation has no passing result. Restarting repeats its work.'
    return result
