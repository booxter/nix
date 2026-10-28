import io
import json
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest
from claude_statusline import LocalTranscriptReader, Status, compact, render, run, session_usage


@dataclass
class Transcript:
    records: tuple[str, ...] = ()

    def lines(self, path: Path) -> Iterator[str]:
        return iter(self.records)


def response(
    message_id: str, *, input_tokens: int = 10, output_tokens: int = 5, cached: int = 100
) -> str:
    return json.dumps(
        {
            "type": "assistant",
            "message": {
                "id": message_id,
                "usage": {
                    "input_tokens": input_tokens,
                    "output_tokens": output_tokens,
                    "cache_read_input_tokens": cached,
                    "cache_creation_input_tokens": 20,
                },
            },
        }
    )


def test_totals_deduplicate_blocks_and_keep_final_usage() -> None:
    transcript = Transcript(
        (
            response("first", output_tokens=1),
            response("first"),
            response("first"),
            '{"type":"user","message":{"content":"hello"}}',
            '{"type":"system","subtype":"compact_boundary"}',
            response("second", input_tokens=2, cached=0),
            '{"type":"assistant","message":{"content":[]}}',
        )
    )

    usage = session_usage(Path("session.jsonl"), transcript)

    assert usage is not None
    assert usage.total_input == 152
    assert usage.output_tokens == 10


def test_status_distinguishes_live_context_from_resumed_session(tmp_path: Path) -> None:
    transcript_path = tmp_path / "session.jsonl"
    transcript_path.write_text(response("before") + "\n" + response("after") + "\n")
    payload = {
        "model": {"display_name": "Opus"},
        "effort": {"level": "high"},
        "workspace": {"current_dir": "/home/user/src/nix"},
        "context_window": {
            "total_input_tokens": 15000,
            "total_output_tokens": 1200,
            "used_percentage": 7.5,
        },
        "transcript_path": str(transcript_path),
    }
    stdout = io.StringIO()

    run(io.StringIO(json.dumps(payload)), stdout, Path("/home/user"), LocalTranscriptReader())

    assert stdout.getvalue() == (
        "Opus · high · ~/src/nix · Context 16.2K tokens, 92% left · Session 260 in, 10 out\n"
    )


def test_new_session_with_no_usage() -> None:
    status = Status.model_validate(
        {
            "workspace": {"current_dir": "/home/user"},
            "context_window": {
                "total_input_tokens": 0,
                "total_output_tokens": 0,
                "used_percentage": None,
            },
            "transcript_path": "session.jsonl",
        }
    )

    assert render(status, Path("/home/user"), Transcript()) == (
        "~ · Context 0 tokens · Session 0 in, 0 out"
    )


@pytest.mark.parametrize("record", ['{"type":', '{"type":"assistant","message":null}'])
def test_incomplete_or_invalid_transcript_does_not_report_partial_totals(record: str) -> None:
    transcript = Transcript((response("first"), record))
    status = Status.model_validate(
        {
            "workspace": {"current_dir": "/home/user-other"},
            "context_window": {"used_percentage": 25},
            "transcript_path": "session.jsonl",
        }
    )

    assert render(status, Path("/home/user"), transcript) == (
        "/home/user-other · Context 75% left · Session tokens unavailable"
    )


def test_missing_transcript_keeps_model_visible(tmp_path: Path) -> None:
    status = Status.model_validate(
        {"model": {"display_name": "Opus"}, "transcript_path": str(tmp_path / "missing")}
    )

    assert render(status, tmp_path, LocalTranscriptReader()) == "Opus · Session tokens unavailable"
    assert render(Status(), tmp_path, Transcript()) == "Session tokens unavailable"


@pytest.mark.parametrize(
    ("tokens", "expected"),
    [(0, "0"), (999, "999"), (1000, "1K"), (15200, "15.2K"), (1200000, "1.2M"), (10**9, "1B")],
)
def test_compact_counts(tokens: int, expected: str) -> None:
    assert compact(tokens) == expected
