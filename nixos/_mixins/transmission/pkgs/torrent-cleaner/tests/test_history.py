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
        seconds_seeding=hour * HOUR_SECONDS,
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
    for offset in range(1, 14 * 24):
        history, rate = observe(
            history, hour + offset, uploaded + offset * HOUR_SECONDS, completed_at
        )
        assert rate is None
    _, rate = observe(history, hour + 14 * 24, uploaded + WINDOW, completed_at)
    assert rate == 1


@pytest.mark.parametrize(
    ("seed_offset", "upload_offset", "wall_offset"),
    [(2000, 900, 2000), (900, 2000, 2000), (2000, 2000, 900)],
    ids=["upload-counter-reset", "seeding-counter-reset", "clock-reversal"],
)
def test_intra_hour_discontinuity_restarts_window(
    seed_offset: int, upload_offset: int, wall_offset: int
) -> None:
    history = None
    for hour in range(14 * 24 + 1):
        history, _ = observe(history, hour, hour * HOUR_SECONDS)

    now = float(WINDOW + 1800)
    history, rate = observe_upload(
        history,
        completed_at=1,
        seconds_seeding=WINDOW + 1800,
        uploaded_bytes=WINDOW + 1800,
        now=now,
        window_seconds=float(WINDOW),
    )
    assert rate is not None and rate >= 1
    _, rate = observe_upload(
        history,
        completed_at=1,
        seconds_seeding=WINDOW + seed_offset,
        uploaded_bytes=WINDOW + upload_offset,
        now=float(WINDOW + wall_offset),
        window_seconds=float(WINDOW),
    )
    assert rate is None


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
        seconds_seeding=WINDOW + 1800,
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
    "overrides",
    [
        {"timestamp": -1},
        {"seconds_seeding": 99},
        {"uploaded_bytes": 99},
        {"timestamp": float("nan")},
    ],
)
def test_file_store_rejects_invalid_observations(
    tmp_path: Path, overrides: dict[str, float | int]
) -> None:
    path = tmp_path / "history.json"
    path.write_text(
        json.dumps(
            {
                "torrents": {
                    "hash": {
                        "completed_at": 1,
                        "samples": [
                            {"timestamp": 0, "seconds_seeding": 100, "uploaded_bytes": 100}
                        ],
                        "last_observation": (
                            {"timestamp": 1, "seconds_seeding": 101, "uploaded_bytes": 101}
                            | overrides
                        ),
                    }
                }
            }
        )
    )
    with pytest.raises(HistoryError):
        FileHistoryStore(path).load()
