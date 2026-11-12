import csv
import io
import json
import re
from dataclasses import dataclass
from urllib.parse import urlencode

from bs4 import BeautifulSoup, Tag
from pydantic import TypeAdapter

from .models import ImdbId, ImportResult, Production, SyncError
from .transport import Transport, Upload


def attribute(tag: Tag | None, name: str) -> str:
    value = tag.get(name) if tag is not None else None
    if not isinstance(value, str):
        raise SyncError("Letterboxd importer markup changed or the session expired")
    return value


@dataclass(frozen=True)
class Preview:
    imdb_ids: tuple[str, ...]
    csrf: str
    production_ids: tuple[str, ...]


class Letterboxd:
    def __init__(self, transport: Transport, username: str) -> None:
        self.transport = transport
        self.username = username

    def preview(self, imdb_ids: tuple[str, ...]) -> Preview:
        """Upload IMDb IDs and resolve Letterboxd IDs without marking anything watched.

        The website separates CSV parsing, film matching, and confirmation.
        Keep those boundaries so dry runs exercise the same path up to confirmation.
        """
        # The website confirms at most 25 films per request. Use the same batch
        # size here so a preview corresponds to one confirmation and checkpoint.
        if not 1 <= len(imdb_ids) <= 25 or len(set(imdb_ids)) != len(imdb_ids):
            raise SyncError("Import batches must contain 1-25 distinct movies")
        TypeAdapter(tuple[ImdbId, ...]).validate_python(imdb_ids)

        csrf = self._open_importer()
        csrf = self._upload_csv(imdb_ids, csrf)
        return self._match_movies(imdb_ids, csrf)

    def _open_importer(self) -> str:
        # Cookies may have been exported from a different account. Check identity
        # before uploading viewing history, and obtain this session's CSRF token.
        page = BeautifulSoup(self.transport.request("GET", "/import/"), "html.parser")
        title = attribute(page.select_one('meta[property="og:title"]'), "content")
        if title.casefold() != f"Import titles and ratings for {self.username}".casefold():
            raise SyncError("Letterboxd session does not belong to the configured account")
        return attribute(page.select_one('#imdb-form input[name="__csrf"]'), "value")

    def _upload_csv(self, imdb_ids: tuple[str, ...], csrf: str) -> str:
        # Omitting dates and ratings makes this a watched-only import. The upload
        # returns parsed rows; matching is a separate request made by the page's JS.
        content = io.StringIO()
        writer = csv.writer(content)
        writer.writerow(["imdbID"])
        writer.writerows((imdb_id,) for imdb_id in imdb_ids)
        page = BeautifulSoup(
            self.transport.request(
                "POST",
                "/import/csv/",
                data={"__csrf": csrf},
                upload=Upload("watched.csv", content.getvalue().encode()),
            ),
            "html.parser",
        )
        form = page.select_one("#imdb-importer-matched-form")
        # These are private website endpoints, not a versioned API. Stop if the
        # form changes instead of submitting credentials to an unexpected action.
        if attribute(form, "action") != "/s/save-users-imported-imdb-history":
            raise SyncError("Letterboxd import action changed")
        if attribute(form, "data-url") != "/import/watchlist/match-import-film/":
            raise SyncError("Letterboxd matching endpoint changed")
        assert form is not None
        csrf = attribute(form.select_one('input[name="__csrf"]'), "value")
        productions = [
            Production.model_validate_json(attribute(tag, "data-json"))
            for tag in form.select("li.import-film")
        ]
        if tuple(production.imdbId for production in productions) != imdb_ids:
            raise SyncError("Letterboxd did not preserve the requested IMDb IDs")
        return csrf

    def _match_movies(self, imdb_ids: tuple[str, ...], csrf: str) -> Preview:
        # Use only our watched-only fields, even if the upload parser adds defaults later.
        # "diary" is the website's importer type even when no diary dates are supplied.
        payload = {
            "importType": "diary",
            "importProductions": [Production(imdbId=imdb_id).model_dump() for imdb_id in imdb_ids],
        }
        matched = BeautifulSoup(
            self.transport.request(
                "POST",
                "/import/watchlist/match-import-film/",
                data={"__csrf": csrf, "json": json.dumps(payload)},
            ),
            "html.parser",
        )
        matches = matched.select(".matched-item")
        if len(matches) != len(imdb_ids):
            raise SyncError("Letterboxd returned an incomplete matching response")

        accepted_ids = []
        production_ids = []
        # The response preserves input order. Keep each accepted IMDb ID paired
        # with its Letterboxd ID so skipped films never enter the checkpoint.
        for imdb_id, match in zip(imdb_ids, matches, strict=True):
            eligible = attribute(match.select_one('[name="shouldImportProduction"]'), "value")
            production_id = attribute(match.select_one('[name="importProductionId"]'), "value")

            # "No match found" still includes an icon-matched placeholder. The
            # empty ID and false import flag identify an unresolved film instead.
            if eligible == "false" and production_id == "":
                continue

            if match.select_one(".icon-matched") is None:
                raise SyncError("Letterboxd returned unexpected matching markup")
            if eligible != "true":
                raise SyncError("Letterboxd rejected a matched movie")
            if not re.fullmatch(r"[A-Za-z0-9]+", production_id):
                raise SyncError("Letterboxd returned an invalid production ID")

            accepted_ids.append(imdb_id)
            production_ids.append(production_id)

        if len(set(production_ids)) != len(production_ids):
            raise SyncError("Letterboxd returned duplicate matches")
        return Preview(tuple(accepted_ids), csrf, tuple(production_ids))

    def confirm(self, preview: Preview) -> None:
        fields = [("__csrf", preview.csrf), ("shouldMarkAsWatched", "true")]
        for production_id in preview.production_ids:
            fields.extend(
                [
                    ("importProductionId", production_id),
                    ("importViewingId", ""),
                    ("shouldImportProduction", "true"),
                    ("importRating", ""),
                    ("importReview", ""),
                    ("importTags", ""),
                    ("importWatchedDate", ""),
                    ("importRewatch", "false"),
                ]
            )
        result = ImportResult.model_validate_json(
            self.transport.request(
                "POST",
                "/s/save-users-imported-imdb-history",
                data=urlencode(fields).encode(),
            )
        )
        if not result.result:
            raise SyncError("Letterboxd did not confirm the import; progress was not recorded")
