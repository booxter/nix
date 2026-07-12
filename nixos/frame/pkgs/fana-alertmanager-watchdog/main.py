import argparse
import asyncio
import html
import os
import pathlib
import ssl
import sys
import time
import urllib.error
import urllib.request

from telegram import Bot


STATUS_UP = "up"
STATUS_DOWN = "down"
DEFAULT_REPEAT_AFTER_SECONDS = 6 * 60 * 60
DEFAULT_TIMEOUT_SECONDS = 10.0


def read_text(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def read_secret(path):
    value = read_text(path)
    if not value:
        raise RuntimeError(f"secret file is empty or missing: {path}")
    return value


def read_int(path, default):
    value = read_text(path)
    try:
        return int(value)
    except ValueError:
        return default


def atomic_write(path, content):
    path = pathlib.Path(path)
    tmp_path = path.with_name(f".{path.name}.tmp")
    try:
        tmp_path.write_text(content, encoding="utf-8")
        os.replace(tmp_path, path)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def remove_file(path):
    try:
        pathlib.Path(path).unlink()
    except FileNotFoundError:
        pass


def credential_path(name, explicit_path=None):
    if explicit_path:
        return pathlib.Path(explicit_path)
    credentials_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials_dir:
        raise RuntimeError(
            f"--{name.replace('_', '-')} was not provided and CREDENTIALS_DIRECTORY is not set"
        )
    return pathlib.Path(credentials_dir) / name.replace("_", "-")


def default_state_dir():
    return os.environ.get("STATE_DIRECTORY") or "/var/lib/fana-alertmanager-watchdog"


def truncate(value, limit=300):
    value = " ".join(str(value).split())
    if len(value) <= limit:
        return value
    return value[: limit - 3] + "..."


def check_ready(url, ca_file, client_cert_file, client_key_file, timeout):
    context = ssl.create_default_context(cafile=ca_file)
    context.load_cert_chain(certfile=client_cert_file, keyfile=client_key_file)
    request = urllib.request.Request(url, headers={"Accept": "text/plain"})
    try:
        with urllib.request.urlopen(
            request, timeout=timeout, context=context
        ) as response:
            response.read()
        return True, ""
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        return False, truncate(f"HTTP {error.code} {error.reason}: {body}")
    except (OSError, ssl.SSLError, urllib.error.URLError) as error:
        return False, truncate(f"{type(error).__name__}: {error}")


async def send_telegram_async(token, chat_id, message):
    async with Bot(token=token) as bot:
        await bot.send_message(chat_id=chat_id, text=message, parse_mode="HTML")


def send_telegram(bot_token_file, chat_id_file, message):
    token = read_secret(bot_token_file)
    chat_id = read_secret(chat_id_file)
    asyncio.run(send_telegram_async(token, chat_id, message))


def html_escape(text):
    return html.escape(str(text), quote=False)


def format_status_message(url, detail, status):
    title = html_escape(url)
    safe_detail = html_escape(detail)
    if status == STATUS_UP:
        return (
            "✅ <b>Alert resolved</b>\n"
            "<b>Fana alertmanager readiness probe recovered</b>\n\n"
            "frame can reach {title} with mTLS again.\n\n"
            "<b>Details</b>\n"
            "• Target: {title}\n"
            "• Sender: frame\n"
            "• Source: fana/monitoring watchdog"
        ).format(title=title)
    return (
        "🚨 <b>Alert firing</b>\n"
        "<b>Fana Alertmanager readiness probe failed</b>\n\n"
        "frame cannot reach {title} with mTLS.\n"
        "Regular alert notifications from fana may be unavailable.\n\n"
        "<b>Details</b>\n"
        "• Target: {title}\n"
        "• Sender: frame\n"
        "• Source: fana/monitoring watchdog\n"
        f"• Detail: {safe_detail}\n\n"
        '<a href="https://grafana.home.arpa/alerting/groups">Open active alerts in Grafana</a>'
    ).format(title=title, safe_detail=safe_detail)


def should_notify(last_status, now, last_notified, repeat_after_seconds):
    return last_status != STATUS_DOWN or now - last_notified >= repeat_after_seconds


def run(args):
    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    status_file = state_dir / "status"
    notified_file = state_dir / "last-notified"
    error_file = state_dir / "last-error"

    bot_token_file = credential_path("telegram_bot_token", args.telegram_bot_token_file)
    chat_id_file = credential_path("telegram_chat_id", args.telegram_chat_id_file)
    client_cert_file = credential_path("mtls_client_crt", args.client_cert_file)
    client_key_file = credential_path("mtls_client_key", args.client_key_file)

    last_status = read_text(status_file)
    ok, detail = check_ready(
        url=args.url,
        ca_file=args.ca_file,
        client_cert_file=client_cert_file,
        client_key_file=client_key_file,
        timeout=args.timeout,
    )

    if ok:
        if last_status == STATUS_DOWN:
            send_telegram(
                bot_token_file,
                chat_id_file,
                format_status_message(args.url, "", STATUS_UP),
            )
        atomic_write(status_file, STATUS_UP + "\n")
        remove_file(notified_file)
        remove_file(error_file)
        return

    now = int(time.time())
    last_notified = read_int(notified_file, 0)
    atomic_write(error_file, detail + "\n")

    if should_notify(last_status, now, last_notified, args.repeat_after_seconds):
        send_telegram(
            bot_token_file,
            chat_id_file,
            format_status_message(args.url, detail, STATUS_DOWN),
        )
        atomic_write(notified_file, f"{now}\n")

    atomic_write(status_file, STATUS_DOWN + "\n")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--state-dir", default=default_state_dir())
    parser.add_argument("--client-cert-file")
    parser.add_argument("--client-key-file")
    parser.add_argument("--telegram-bot-token-file")
    parser.add_argument("--telegram-chat-id-file")
    parser.add_argument(
        "--repeat-after-seconds", type=int, default=DEFAULT_REPEAT_AFTER_SECONDS
    )
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    return parser.parse_args()


def main():
    try:
        run(parse_args())
    except Exception as error:
        print(f"fana-alertmanager-watchdog: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
