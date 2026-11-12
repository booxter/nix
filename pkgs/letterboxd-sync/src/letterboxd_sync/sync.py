from typing import Protocol

from .letterboxd import Preview
from .state import State


class Destination(Protocol):
    def preview(self, imdb_ids: tuple[str, ...]) -> Preview: ...

    def confirm(self, preview: Preview) -> None: ...


def sync(movies: set[str], state: State, destination: Destination, *, dry_run: bool) -> int:
    pending = state.pending(movies)
    processed = 0
    unmatched: list[str] = []

    for offset in range(0, len(pending), 25):
        batch = pending[offset : offset + 25]
        preview = destination.preview(batch)
        unmatched.extend(imdb_id for imdb_id in batch if imdb_id not in preview.imdb_ids)

        if not dry_run and preview.imdb_ids:
            destination.confirm(preview)
            # A crash between confirmation and this commit may replay watched flags,
            # which is safe because we never send dates, ratings, reviews, or rewatches.
            state.record(preview.imdb_ids)

        processed += len(preview.imdb_ids)
        print(f"{'Previewed' if dry_run else 'Imported'} {processed}/{len(pending)} movies")

    if unmatched:
        # Catalog gaps are normal. Leave these IDs pending in case Letterboxd
        # adds them later, without treating an otherwise successful run as failed.
        print(f"Warning: no Letterboxd match for {len(unmatched)} movies: {', '.join(unmatched)}")

    return processed
