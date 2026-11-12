import pytest
from letterboxd_sync.letterboxd import Preview
from letterboxd_sync.models import SyncError
from letterboxd_sync.state import State
from letterboxd_sync.sync import sync


class Destination:
    def __init__(self, fail_after=None):
        self.watched = set()
        self.fail_after = fail_after

    def preview(self, imdb_ids):
        return Preview(imdb_ids, "test-token", imdb_ids)

    def confirm(self, preview):
        if self.fail_after is not None and len(self.watched) >= self.fail_after:
            raise SyncError("Import failed")
        self.watched.update(preview.imdb_ids)


@pytest.fixture
def state(tmp_path):
    state = State(tmp_path, "example")
    try:
        yield state
    finally:
        state.close()


def test_sync_only_adds_movies_missing_from_checkpoint(state):
    destination = Destination()
    movies = {f"tt{index}" for index in range(53)}

    assert sync(movies, state, destination, dry_run=False) == 53
    assert destination.watched == movies
    assert sync(movies, state, destination, dry_run=False) == 0
    assert sync(movies | {"tt1234"}, state, destination, dry_run=False) == 1


def test_dry_run_neither_imports_nor_checkpoints(state):
    destination = Destination()

    assert sync({"tt1"}, state, destination, dry_run=True) == 1
    assert destination.watched == set()
    assert state.pending({"tt1"}) == ("tt1",)


@pytest.mark.parametrize("fail_after", [0, 25])
def test_retry_resumes_after_last_successful_batch(state, fail_after):
    movies = {f"tt{index:03d}" for index in range(30)}
    destination = Destination(fail_after=fail_after)

    with pytest.raises(SyncError):
        sync(movies, state, destination, dry_run=False)

    assert len(destination.watched) == fail_after
    assert len(state.pending(movies)) == 30 - fail_after

    destination.fail_after = None
    assert sync(movies, state, destination, dry_run=False) == 30 - fail_after
    assert destination.watched == movies


def test_checkpoint_survives_restart_and_is_account_scoped(tmp_path):
    first = State(tmp_path, "first")
    first.record(["tt1"])
    first.close()

    reopened = State(tmp_path, "FIRST")
    assert reopened.pending(["tt1"]) == ()
    reopened.close()

    second = State(tmp_path, "second")
    assert second.pending(["tt1"]) == ("tt1",)
    second.close()
