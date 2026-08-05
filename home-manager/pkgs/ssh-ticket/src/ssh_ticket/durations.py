import re


class DurationError(ValueError):
    pass


def parse_duration(value: int | str) -> int:
    if isinstance(value, int):
        return value
    text = value.strip().lower()
    if not text:
        raise DurationError("duration must not be empty")
    units = {
        "": 1,
        "s": 1,
        "m": 60,
        "h": 60 * 60,
        "d": 24 * 60 * 60,
        "w": 7 * 24 * 60 * 60,
    }
    total = 0
    position = 0
    for match in re.finditer(r"(\d+)([smhdw]?)", text):
        if match.start() != position:
            raise DurationError(f"invalid duration: {value}")
        total += int(match.group(1)) * units[match.group(2)]
        position = match.end()
    if position != len(text) or total <= 0:
        raise DurationError(f"invalid duration: {value}")
    return total


def format_duration(seconds: int) -> str:
    for unit, size in (("w", 604800), ("d", 86400), ("h", 3600), ("m", 60)):
        if seconds % size == 0 and seconds >= size:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"
