import argparse
import json
import os
import subprocess
import sys
import tomllib
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import pytest
from codex_launcher.cli import Catalog, CodexRuntime, Preference, launch

PREFERENCE = Preference("preferred-sol", "high")


@dataclass
class FakeRuntime:
    available: Catalog | None = None
    model: str = "workspace-sol"
    effort: str = "medium"
    started: bool = False

    def catalog(self) -> Catalog | None:
        return self.available

    def launch(self, arguments: Sequence[str]) -> None:
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--model", "-m")
        parser.add_argument("--config", "-c", action="append", default=[])
        settings, _ = parser.parse_known_args(arguments)
        if settings.model is not None:
            self.model = settings.model
        for assignment in settings.config:
            config = tomllib.loads(assignment)
            if "model" in config:
                self.model = config["model"]
            if "model_reasoning_effort" in config:
                self.effort = config["model_reasoning_effort"]
        self.started = True


def test_available_model_gets_preferred_effort() -> None:
    runtime = FakeRuntime(Catalog.model_validate({"models": [{"slug": "preferred-sol"}]}))

    launch(["explain this code"], PREFERENCE, runtime)

    assert runtime.started
    assert runtime.model == "preferred-sol"
    assert runtime.effort == "high"


@pytest.mark.parametrize(
    "catalog", [None, Catalog(models=[]), Catalog.model_validate({"models": [{"slug": "other"}]})]
)
def test_unavailable_model_preserves_defaults(catalog: Catalog | None) -> None:
    runtime = FakeRuntime(catalog)

    launch(["--no-alt-screen", "hello"], PREFERENCE, runtime)

    assert runtime.started
    assert runtime.model == "workspace-sol"
    assert runtime.effort == "medium"


@pytest.mark.parametrize(
    "arguments",
    [
        ["--model", "other"],
        ["--model=other"],
        ["-mother"],
        ["-m", "other"],
        ["--profile", "work"],
        ["-pwork"],
        ["-c", "model_reasoning_effort='low'"],
        ["--config=personality='pragmatic'"],
        ["--remote", "unix:///tmp/codex.sock"],
        ["--oss"],
        ["--local-provider=ollama"],
        ["--help"],
        ["-V"],
        ["hello", "--model", "other"],
    ],
)
def test_explicit_settings_do_not_query_catalog(arguments: list[str]) -> None:
    class ExplicitRuntime(FakeRuntime):
        def catalog(self) -> Catalog | None:
            pytest.fail("explicit launches must not query model availability")

    runtime = ExplicitRuntime()

    launch(arguments, PREFERENCE, runtime)

    assert runtime.started
    assert runtime.model != "preferred-sol"
    assert runtime.effort != "high"


@pytest.mark.parametrize(
    "arguments",
    [
        [],
        ["hello"],
        ["--", "exec"],
        ["-C", "exec", "hello"],
        ["--enable", "some-feature", "hello"],
        ["-s", "read-only", "hello"],
        ["hello", "another prompt argument"],
        ["exec", "hello"],
        ["debug", "models"],
        ["resume", "--last"],
        ["-C", "somewhere", "mcp", "list"],
        ["future-command", "some-option"],
    ],
)
def test_commands_prefer_available_model(arguments: list[str]) -> None:
    runtime = FakeRuntime(Catalog.model_validate({"models": [{"slug": "preferred-sol"}]}))

    launch(arguments, PREFERENCE, runtime)

    assert runtime.started
    assert runtime.model == "preferred-sol"
    assert runtime.effort == "high"


def test_catalog_reads_real_process_output() -> None:
    payload = {"models": [{"slug": "preferred-sol", "display_name": "Sol"}]}
    runtime = CodexRuntime((sys.executable, "-c", f"print({json.dumps(json.dumps(payload))})"))

    assert runtime.catalog() == Catalog.model_validate(payload)


@pytest.mark.parametrize(
    "script",
    [
        "print('not json')",
        "print('{}')",
        'print(\'{"models": [{"slug": 2}]}\')',
        "raise SystemExit(1)",
        "import time; time.sleep(60)",
    ],
)
def test_failed_catalog_lookup_returns_no_preference(script: str) -> None:
    runtime = CodexRuntime((sys.executable, "-c", script), timeout=0.1)

    assert runtime.catalog() is None


def test_missing_codex_returns_no_preference(tmp_path: Path) -> None:
    assert CodexRuntime((str(tmp_path / "absent"),)).catalog() is None


def test_launcher_replaces_process_and_preserves_exit_status(tmp_path: Path) -> None:
    # A real executable exercises the launch boundary without replacing the test process.
    executable = tmp_path / "codex"
    executable.write_text(
        f"#!{sys.executable}\nimport sys\nprint(' '.join(sys.argv[1:]))\nraise SystemExit(17)\n"
    )
    executable.chmod(0o755)
    script = "from codex_launcher.cli import main\nmain()\n"
    result = subprocess.run(
        [sys.executable, "-c", script, str(executable), "preferred-sol", "high", "--help"],
        env={**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 17
    assert result.stdout == "--help\n"
