import io
import signal
import subprocess
from collections.abc import Sequence

import pytest
from auth_request import indicator, pass_gpg


class Bar:
    def __init__(self) -> None:
        self.items: set[str] = set()
        self.labels: list[str] = []

    def __call__(self, args: Sequence[str]) -> None:
        if "--add" in args:
            self.items.add(args[3])
            self.labels.extend(arg for arg in args if arg.startswith("label="))
        else:
            self.items.remove(args[2])


class LeaseStream(io.BytesIO):
    def __init__(self, bar: Bar, item: str) -> None:
        super().__init__(b"ignored")
        self.bar = bar
        self.item = item

    def read(self, size: int = -1) -> bytes:
        assert self.item in self.bar.items
        return super().read(size)


def test_indicator_lasts_until_eof_and_removes_only_its_item() -> None:
    bar = Bar()
    bar.items.add("other")
    indicator.show_activity("bar", "yellow", "black", "SSH", "one", LeaseStream(bar, "one"), bar)
    assert bar.items == {"other"}
    assert bar.labels == ["label=SSH"]


def test_indicator_cleans_up_on_cancellation() -> None:
    class Interrupted(io.BytesIO):
        def read(self, size: int = -1) -> bytes:
            indicator.cancel(signal.SIGTERM, None)
            return b""

    bar = Bar()
    with pytest.raises(indicator.Cancelled):
        indicator.show_activity("bar", "a", "b", "SSH", "one", Interrupted(), bar)
    assert not bar.items


def test_sketchybar_failure_is_best_effort() -> None:
    indicator.run_sketchybar(["/nonexistent/sketchybar"])


class FakeProcess:
    def __init__(self, status: int = 0, *, timeout: bool = False, cancelled: bool = False) -> None:
        self.stdin: io.BytesIO | None = io.BytesIO()
        self.status = status
        self.timeout = timeout
        self.cancelled = cancelled
        self.signals: list[int] = []
        self.killed = False

    def wait(self, timeout: float | None = None) -> int:
        if self.cancelled:
            self.cancelled = False
            raise pass_gpg.Cancelled(signal.SIGTERM)
        if self.timeout and timeout is not None:
            raise subprocess.TimeoutExpired("indicator", timeout)
        return self.status

    def send_signal(self, sig: int) -> None:
        self.signals.append(sig)

    def kill(self) -> None:
        self.killed = True


class FakeLauncher:
    def __init__(self) -> None:
        self.lease = FakeProcess()
        self.child = FakeProcess(23)
        self.started = False
        self.fail_indicator = False
        self.fail_gpg = False

    def indicator(self, path: str, label: str) -> FakeProcess:
        self.started = True
        if self.fail_indicator:
            raise FileNotFoundError(path)
        return self.lease

    def gpg(self, path: str, args: Sequence[str]) -> FakeProcess:
        if self.fail_gpg:
            raise FileNotFoundError(path)
        if self.started and not self.fail_indicator:
            assert self.lease.stdin is not None and not self.lease.stdin.closed
        return self.child


@pytest.mark.parametrize(
    "args,indicated", [(["-d", "file"], True), (["--decrypt"], True), (["--decrypt-files"], False)]
)
def test_decryption_lease_and_exit_status(args: list[str], indicated: bool) -> None:
    launcher = FakeLauncher()
    assert pass_gpg.run_gpg("gpg", "indicator", "pass", args, launcher) == 23
    assert launcher.started is indicated
    assert launcher.lease.stdin is not None
    assert launcher.lease.stdin.closed is indicated


def test_missing_indicator_does_not_stop_gpg() -> None:
    launcher = FakeLauncher()
    launcher.fail_indicator = True
    assert pass_gpg.run_gpg("gpg", "missing", "pass", ["-d"], launcher) == 23


def test_gpg_failure_closes_lease() -> None:
    launcher = FakeLauncher()
    launcher.fail_gpg = True
    with pytest.raises(FileNotFoundError):
        pass_gpg.run_gpg("missing", "indicator", "pass", ["-d"], launcher)
    assert launcher.lease.stdin is not None and launcher.lease.stdin.closed


def test_cancellation_forwarded_and_lease_closed() -> None:
    launcher = FakeLauncher()
    launcher.child.cancelled = True
    with pytest.raises(pass_gpg.Cancelled):
        pass_gpg.run_gpg("gpg", "indicator", "pass", ["-d"], launcher)
    assert launcher.child.signals == [signal.SIGTERM]
    assert launcher.lease.stdin is not None and launcher.lease.stdin.closed


def test_stuck_indicator_is_killed() -> None:
    process = FakeProcess(timeout=True)
    pass_gpg.close_indicator(process)
    assert process.killed


def test_signal_handler() -> None:
    with pytest.raises(pass_gpg.Cancelled) as exc:
        pass_gpg.cancel(signal.SIGHUP, None)
    assert exc.value.signum == signal.SIGHUP
