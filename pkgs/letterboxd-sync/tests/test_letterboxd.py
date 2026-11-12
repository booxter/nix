import csv
import io
from pathlib import Path
from urllib.parse import parse_qs

import pytest
from letterboxd_sync.letterboxd import Letterboxd
from letterboxd_sync.models import SyncError

FIXTURES = Path(__file__).parent / "fixtures"


class Responses:
    def __init__(self):
        self.pages = {
            "/import/": (FIXTURES / "import.html").read_text(),
            "/import/csv/": (FIXTURES / "upload.html").read_text(),
            "/import/watchlist/match-import-film/": (FIXTURES / "match.html").read_text(),
            "/s/save-users-imported-imdb-history": '{"result": true}',
        }
        self.upload = None
        self.confirmation = None

    def request(self, method, path, *, data=None, upload=None):
        if upload is not None:
            self.upload = upload.content.decode()
        if isinstance(data, bytes):
            self.confirmation = parse_qs(data.decode(), keep_blank_values=True)
        return self.pages[path]


def test_import_marks_watched_without_dates_ratings_or_reviews():
    responses = Responses()
    client = Letterboxd(responses, "example")

    preview = client.preview(("tt0133093",))

    assert list(csv.DictReader(io.StringIO(responses.upload))) == [{"imdbID": "tt0133093"}]
    assert preview.production_ids == ("2a1m",)
    assert responses.confirmation is None

    client.confirm(preview)

    assert responses.confirmation["shouldMarkAsWatched"] == ["true"]
    assert responses.confirmation["importProductionId"] == ["2a1m"]
    for field in ("importWatchedDate", "importRating", "importReview", "importTags"):
        assert responses.confirmation[field] == [""]
    assert responses.confirmation["importRewatch"] == ["false"]


def test_wrong_account_is_rejected_before_upload():
    responses = Responses()

    with pytest.raises(SyncError, match="account"):
        Letterboxd(responses, "someone_else").preview(("tt0133093",))

    assert responses.upload is None


@pytest.mark.parametrize(
    "path,old,new",
    [
        ("/import/", 'name="__csrf"', 'name="changed"'),
        ("/import/csv/", "tt0133093", "tt9999999"),
        ("/import/csv/", "/s/save-users-imported-imdb-history", "/changed"),
        ("/import/csv/", "/import/watchlist/match-import-film/", "/changed"),
        ("/import/watchlist/match-import-film/", "icon-matched", "import-no-match"),
        ("/import/watchlist/match-import-film/", 'value="true"', 'value="false"'),
        ("/import/watchlist/match-import-film/", "2a1m", ""),
        ("/import/watchlist/match-import-film/", "matched-item", "changed"),
    ],
)
def test_changed_or_unmatched_responses_cannot_be_confirmed(path, old, new):
    responses = Responses()
    responses.pages[path] = responses.pages[path].replace(old, new)

    with pytest.raises(SyncError):
        Letterboxd(responses, "example").preview(("tt0133093",))

    assert responses.confirmation is None


def test_failed_confirmation_is_reported():
    responses = Responses()
    responses.pages["/s/save-users-imported-imdb-history"] = '{"result": false}'
    client = Letterboxd(responses, "example")
    preview = client.preview(("tt0133093",))

    with pytest.raises(SyncError, match="did not confirm"):
        client.confirm(preview)
