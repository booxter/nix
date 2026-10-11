"""A small review program for exercising the real process and terminal boundaries."""

import argparse
import json
import os
import shlex
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=["pr"])
parser.add_argument("pull_requests", nargs="+")
parser.add_argument("--no-shell", action="store_true")
parser.add_argument("--include-pr", action="append", default=[])
parser.add_argument("-p", "--package", action="append", default=[])
parser.add_argument("--systems", required=True)
parser.add_argument("--post-result", action="store_true")
parser.add_argument("--approve-pr", action="store_true")
parser.add_argument("--tests", action="store_true")
parser.add_argument("--extra-nixpkgs-config")
parser.add_argument("--build-args")
arguments = parser.parse_args()

build_parser = argparse.ArgumentParser()
build_parser.add_argument("--builders")
build_options = build_parser.parse_args(shlex.split(arguments.build_args or ""))
report = vars(arguments) | {"builders": build_options.builders, "directory": str(Path.cwd())}
Path(os.environ["NR_TEST_REPORT"]).write_text(json.dumps(report))
print("review started", flush=True)

if gate := os.environ.get("NR_TEST_GATE"):
    while not Path(gate).exists():
        time.sleep(0.02)

print("review finished", flush=True)
sys.exit(int(os.environ.get("NR_TEST_STATUS", "0")))
