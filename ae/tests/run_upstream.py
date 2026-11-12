"""Run one of upstream's unittest files (tests/test_*.py), unchanged, leaving
out the tests the port excludes by policy or has not reached yet.

    cd tests && python3 ../ae/tests/run_upstream.py test_agent.py [SKIP ...]

Each SKIP is a substring of a test's id (Class.method); a matching test is
not run. ae/tests/upstream-e2e.sh holds the list and the reason for each.
"""
import importlib.util
import os
import sys
import unittest


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def main():
    path, skips = sys.argv[1], sys.argv[2:]
    sys.path.insert(0, os.getcwd())
    name = os.path.splitext(os.path.basename(path))[0]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    loaded = unittest.defaultTestLoader.loadTestsFromModule(module)
    kept, skipped = unittest.TestSuite(), []
    for test in flatten(loaded):
        test_id = test.id().split(".", 1)[-1]
        if any(s in test_id for s in skips):
            skipped.append(test_id)
        else:
            kept.addTest(test)
    print(f"excluded {len(skipped)}: {', '.join(skipped) or '-'}", flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(kept)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
