from typing import Protocol

from .letterboxd import Preview
from .state import State


class Destination(Protocol):
    def preview(self, imdb_ids: tuple[str, ...]) -> Preview: ...

    def confirm(self, preview: Preview) -> None: ...


def sync(movies: set[str], state: State, destination: Destination, *, dry_run: bool) -> int:
    pending = state.pending(movies)
    processed = 0
    for offset in range(0, len(pending), 25):
        batch = pending[offset : offset + 25]
        preview = destination.preview(batch)
        if not dry_run:
            destination.confirm(preview)
            # A crash between confirmation and this commit may replay watched flags,
            # which is safe because we never send dates, ratings, reviews, or rewatches.
            state.record(batch)
        processed += len(batch)
        print(f"{'Previewed' if dry_run else 'Imported'} {processed}/{len(pending)} movies")
    return processed
