#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


record = {
    "command": Path(sys.argv[0]).name,
    "arguments": sys.argv[1:],
    "stdin": sys.stdin.read(),
}
with Path(os.environ["HBA_FLASH_TEST_LOG"]).open("a") as output:
    output.write(json.dumps(record) + "\n")
