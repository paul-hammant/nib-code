"""JS fixtures and bounded filesystem gates for change-attribution E2E tests."""
import json
import shlex
import sys


def call(name, **args):
    return "tools." + name + "(" + json.dumps(args) + ")"


def checked_bash(command):
    return ("if ((await " + call("bash", command=command) +
            ').exit_code !== 0) throw new Error("change fixture command failed"); ')


def wait_command(path):
    program = ("import pathlib,time\n"
               "path = pathlib.Path(" + repr(path) + ")\n"
               "deadline = time.monotonic() + 8\n"
               "while not path.exists():\n"
               "    if time.monotonic() > deadline: raise TimeoutError(str(path))\n"
               "    time.sleep(.01)\n")
    return shlex.join([sys.executable, "-c", program])
