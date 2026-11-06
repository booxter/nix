import json
from pathlib import Path

import pytest
from transmission_torrent_cleaner.history import (
    HOUR_SECONDS,
    FileHistoryStore,
    HistoryError,
    TorrentHistory,
    UploadHistory,
    observe_upload,
)

WINDOW = 14 * 24 * HOUR_SECONDS


def observe(
    history: TorrentHistory | None, hour: int, uploaded: int, completed_at: int = 1
) -> tuple[TorrentHistory, float | None]:
    return observe_upload(
        history,
        completed_at=completed_at,
        uploaded_bytes=uploaded,
        now=float(hour * HOUR_SECONDS),
        window_seconds=float(WINDOW),
    )


def test_full_window_and_rolling_rate() -> None:
    history = None
    for hour in range(14 * 24):
        history, rate = observe(history, hour, hour * HOUR_SECONDS * 10240)
        assert rate is None

    for hour in range(14 * 24, 16 * 24):
        history, rate = observe(history, hour, hour * HOUR_SECONDS * 10240)
        assert rate == 10240
        assert len(history.samples) <= 14 * 24 + 1


@pytest.mark.parametrize("event", ["gap", "reset", "completion", "clock"])
def test_discontinuity_requires_a_fresh_window(event: str) -> None:
    history = None
    for hour in range(14 * 24 + 1):
        history, rate = observe(history, hour, hour * HOUR_SECONDS)
    assert rate == 1

    hour = 14 * 24 + 1
    uploaded = hour * HOUR_SECONDS
    completed_at = 1
    if event == "gap":
        hour += 2
    elif event == "reset":
        uploaded = 0
    elif event == "completion":
        completed_at = 2
    else:
        hour -= 2
    history, rate = observe(history, hour, uploaded, completed_at)
    assert rate is None
    assert len(history.samples) == 1
    for offset in range(1, 14 * 24):
        history, rate = observe(
            history, hour + offset, uploaded + offset * HOUR_SECONDS, completed_at
        )
        assert rate is None
    _, rate = observe(history, hour + 14 * 24, uploaded + WINDOW, completed_at)
    assert rate == 1


@pytest.mark.parametrize("event", ["reset", "clock"])
def test_intra_hour_discontinuity_restarts_window(event: str) -> None:
    history = None
    for hour in range(14 * 24 + 1):
        history, _ = observe(history, hour, hour * HOUR_SECONDS)

    now = float(WINDOW + 1800)
    history, rate = observe_upload(
        history,
        completed_at=1,
        uploaded_bytes=WINDOW + 1800,
        now=now,
        window_seconds=float(WINDOW),
    )
    assert rate is not None and rate >= 1
    history, rate = observe_upload(
        history,
        completed_at=1,
        uploaded_bytes=WINDOW + (900 if event == "reset" else 2000),
        now=now + (1 if event == "reset" else -900),
        window_seconds=float(WINDOW),
    )
    assert rate is None
    assert len(history.samples) == 1


def test_hourly_boundary_never_underestimates_productive_window() -> None:
    history = None
    rate_threshold = 10240
    for hour in range(14 * 24 + 1):
        # No upload in the first half hour; exactly the threshold afterward.
        uploaded = max(0, hour * HOUR_SECONDS - 1800) * rate_threshold
        history, _ = observe(history, hour, uploaded)
    _, rate = observe_upload(
        history,
        completed_at=1,
        uploaded_bytes=WINDOW * rate_threshold,
        now=float(WINDOW + 1800),
        window_seconds=float(WINDOW),
    )
    assert rate == rate_threshold


def test_file_store_roundtrip_and_invalid_file(tmp_path: Path) -> None:
    path = tmp_path / "history.json"
    store = FileHistoryStore(path)
    assert store.load() == UploadHistory()
    history, _ = observe(None, 0, 100)
    expected = UploadHistory(torrents={"hash": history})
    store.save(expected)
    assert store.load() == expected
    assert list(tmp_path.iterdir()) == [path]
    path.write_text("{invalid")
    with pytest.raises(HistoryError):
        store.load()


@pytest.mark.parametrize(
    "last_observation",
    [
        {"timestamp": -1, "uploaded_bytes": 100},
        {"timestamp": 1, "uploaded_bytes": 99},
        {"timestamp": float("nan"), "uploaded_bytes": 100},
    ],
)
def test_file_store_rejects_invalid_observations(
    tmp_path: Path, last_observation: dict[str, float | int]
) -> None:
    path = tmp_path / "history.json"
    path.write_text(
        json.dumps(
            {
                "torrents": {
                    "hash": {
                        "completed_at": 1,
                        "samples": [{"timestamp": 0, "uploaded_bytes": 100}],
                        "last_observation": last_observation,
                    }
                }
            }
        )
    )
    with pytest.raises(HistoryError):
        FileHistoryStore(path).load()
