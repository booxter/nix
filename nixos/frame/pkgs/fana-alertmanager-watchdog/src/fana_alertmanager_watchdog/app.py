from __future__ import annotations

import argparse
import asyncio
import html
import os
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Protocol

from telegram import Bot

DEFAULT_REPEAT_AFTER_SECONDS = 6 * 60 * 60
DEFAULT_TIMEOUT_SECONDS = 10.0


class Status(StrEnum):
    UP = "up"
    DOWN = "down"


@dataclass(frozen=True)
class ProbeResult:
    detail: str
    ready: bool


class ReadinessProbe(Protocol):
    def check(self) -> ProbeResult: ...


class Notifier(Protocol):
    def send(self, message: str) -> None: ...


@dataclass(frozen=True)
class MtlsReadinessProbe:
    ca_file: Path
    client_cert_file: Path
    client_key_file: Path
    timeout: float
    url: str

    def check(self) -> ProbeResult:
        context = ssl.create_default_context(cafile=self.ca_file)
        context.load_cert_chain(certfile=self.client_cert_file, keyfile=self.client_key_file)
        request = urllib.request.Request(self.url, headers={"Accept": "text/plain"})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout, context=context) as response:
                response.read()
            return ProbeResult("", True)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            return ProbeResult(truncate(f"HTTP {error.code} {error.reason}: {body}"), False)
        except OSError as error:
            return ProbeResult(truncate(f"{type(error).__name__}: {error}"), False)


@dataclass(frozen=True)
class TelegramNotifier:
    bot_token_file: Path
    chat_id_file: Path

    async def _send(self, message: str) -> None:
        async with Bot(token=read_secret(self.bot_token_file)) as bot:
            await bot.send_message(
                chat_id=read_secret(self.chat_id_file),
                text=message,
                parse_mode="HTML",
            )

    def send(self, message: str) -> None:
        asyncio.run(self._send(message))


@dataclass(frozen=True)
class StateStore:
    root: Path

    @property
    def error_file(self) -> Path:
        return self.root / "last-error"

    @property
    def notified_file(self) -> Path:
        return self.root / "last-notified"

    @property
    def status_file(self) -> Path:
        return self.root / "status"

    def prepare(self) -> None:
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)

    def last_notified(self) -> int:
        value = read_text(self.notified_file)
        try:
            return int(value)
        except ValueError:
            return 0

    def status(self) -> Status | None:
        value = read_text(self.status_file)
        try:
            return Status(value)
        except ValueError:
            return None

    def record_down(self, notified_at: int | None) -> None:
        if notified_at is not None:
            atomic_write(self.notified_file, f"{notified_at}\n")
        atomic_write(self.status_file, f"{Status.DOWN}\n")

    def record_up(self) -> None:
        atomic_write(self.status_file, f"{Status.UP}\n")
        remove_file(self.notified_file)
        remove_file(self.error_file)


@dataclass(frozen=True)
class Runtime:
    notifier: Notifier
    probe: ReadinessProbe
    repeat_after_seconds: int
    state: StateStore
    url: str


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def read_secret(path: Path) -> str:
    value = read_text(path)
    if not value:
        raise RuntimeError(f"secret file is empty or missing: {path}")
    return value


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent, text=True
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(content)
        os.replace(temporary, path)
    finally:
        remove_file(temporary)


def remove_file(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def credential_path(name: str, explicit_path: str | None, environment: Mapping[str, str]) -> Path:
    if explicit_path:
        return Path(explicit_path)
    credentials_directory = environment.get("CREDENTIALS_DIRECTORY")
    if not credentials_directory:
        option = name.replace("_", "-")
        raise RuntimeError(f"--{option} was not provided and CREDENTIALS_DIRECTORY is not set")
    return Path(credentials_directory) / name.replace("_", "-")


def truncate(value: object, limit: int = 300) -> str:
    normalized = " ".join(str(value).split())
    if len(normalized) <= limit:
        return normalized
    return normalized[: limit - 3] + "..."


def format_status_message(url: str, detail: str, status: Status) -> str:
    title = html.escape(url, quote=False)
    safe_detail = html.escape(detail, quote=False)
    if status is Status.UP:
        return (
            "✅ <b>Alert resolved</b>\n"
            "<b>Fana alertmanager readiness probe recovered</b>\n\n"
            f"frame can reach {title} with mTLS again.\n\n"
            "<b>Details</b>\n"
            f"• Target: {title}\n"
            "• Sender: frame\n"
            "• Source: fana/monitoring watchdog"
        )
    return (
        "🚨 <b>Alert firing</b>\n"
        "<b>Fana Alertmanager readiness probe failed</b>\n\n"
        f"frame cannot reach {title} with mTLS.\n"
        "Regular alert notifications from fana may be unavailable.\n\n"
        "<b>Details</b>\n"
        f"• Target: {title}\n"
        "• Sender: frame\n"
        "• Source: fana/monitoring watchdog\n"
        f"• Detail: {safe_detail}\n\n"
        '<a href="https://grafana.home.arpa/alerting/groups">Open active alerts in Grafana</a>'
    )


def should_notify(
    last_status: Status | None,
    now: int,
    last_notified: int,
    repeat_after_seconds: int,
) -> bool:
    return last_status is not Status.DOWN or now - last_notified >= repeat_after_seconds


def run(runtime: Runtime, now: int) -> None:
    runtime.state.prepare()
    last_status = runtime.state.status()
    result = runtime.probe.check()
    if result.ready:
        if last_status is Status.DOWN:
            runtime.notifier.send(format_status_message(runtime.url, "", Status.UP))
        runtime.state.record_up()
        return

    notify = should_notify(
        last_status,
        now,
        runtime.state.last_notified(),
        runtime.repeat_after_seconds,
    )
    atomic_write(runtime.state.error_file, f"{result.detail}\n")
    if notify:
        runtime.notifier.send(format_status_message(runtime.url, result.detail, Status.DOWN))
    runtime.state.record_down(now if notify else None)


@dataclass(frozen=True)
class Arguments:
    ca_file: Path
    client_cert_file: str | None
    client_key_file: str | None
    repeat_after_seconds: int
    state_dir: Path
    telegram_bot_token_file: str | None
    telegram_chat_id_file: str | None
    timeout: float
    url: str


def parse_arguments(
    argv: Sequence[str] | None = None,
    environment: Mapping[str, str] = os.environ,
) -> Arguments:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--ca-file", required=True, type=Path)
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=environment.get("STATE_DIRECTORY") or "/var/lib/fana-alertmanager-watchdog",
    )
    parser.add_argument("--client-cert-file")
    parser.add_argument("--client-key-file")
    parser.add_argument("--telegram-bot-token-file")
    parser.add_argument("--telegram-chat-id-file")
    parser.add_argument("--repeat-after-seconds", type=int, default=DEFAULT_REPEAT_AFTER_SECONDS)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    parsed = parser.parse_args(argv)
    return Arguments(
        ca_file=parsed.ca_file,
        client_cert_file=parsed.client_cert_file,
        client_key_file=parsed.client_key_file,
        repeat_after_seconds=parsed.repeat_after_seconds,
        state_dir=parsed.state_dir,
        telegram_bot_token_file=parsed.telegram_bot_token_file,
        telegram_chat_id_file=parsed.telegram_chat_id_file,
        timeout=parsed.timeout,
        url=parsed.url,
    )


def runtime(arguments: Arguments, environment: Mapping[str, str] = os.environ) -> Runtime:
    bot_token = credential_path(
        "telegram_bot_token", arguments.telegram_bot_token_file, environment
    )
    chat_id = credential_path("telegram_chat_id", arguments.telegram_chat_id_file, environment)
    client_cert = credential_path("mtls_client_crt", arguments.client_cert_file, environment)
    client_key = credential_path("mtls_client_key", arguments.client_key_file, environment)
    return Runtime(
        notifier=TelegramNotifier(bot_token, chat_id),
        probe=MtlsReadinessProbe(
            ca_file=arguments.ca_file,
            client_cert_file=client_cert,
            client_key_file=client_key,
            timeout=arguments.timeout,
            url=arguments.url,
        ),
        repeat_after_seconds=arguments.repeat_after_seconds,
        state=StateStore(arguments.state_dir),
        url=arguments.url,
    )


def main(argv: Sequence[str] | None = None) -> int:
    try:
        run(runtime(parse_arguments(argv)), int(time.time()))
    except Exception as error:
        print(f"fana-alertmanager-watchdog: {error}", file=sys.stderr)
        return 1
    return 0
