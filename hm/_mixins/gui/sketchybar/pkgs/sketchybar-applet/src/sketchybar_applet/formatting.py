from __future__ import annotations

import datetime as dt


def format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "?"
    if seconds < 0:
        return "expired"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3_600:
        return f"{seconds // 60}m"
    if seconds < 86_400:
        return f"{seconds // 3_600}h{seconds % 3_600 // 60:02d}"
    return f"{seconds // 86_400}d{seconds % 86_400 // 3_600:02d}h"


def format_epoch_local(epoch: int | float | None) -> str | None:
    if epoch is None:
        return None
    try:
        value = dt.datetime.fromtimestamp(epoch).astimezone()
    except (OSError, OverflowError, ValueError):
        return None
    return value.strftime("%Y-%m-%d %H:%M %Z")
