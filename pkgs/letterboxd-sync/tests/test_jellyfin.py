import pytest
from letterboxd_sync.jellyfin import Jellyfin
from letterboxd_sync.models import SyncError


def movie(identifier, imdb="tt1", kind="Movie", played=True):
    return {
        "Id": identifier,
        "Type": kind,
        "ProviderIds": {"Imdb": imdb},
        "UserData": {"Played": played},
    }


class Library:
    def __init__(self, pages, users=None):
        self.pages = iter(pages)
        self.users = users if users is not None else [{"Id": "abc123", "Name": "source"}]

    def get_users(self):
        return self.users

    def items(self, *, params):
        return next(self.pages)


def test_pagination_only_keeps_watched_movies_with_imdb_ids():
    library = Library(
        [
            {"Items": [movie("1"), movie("2", kind="Episode")], "TotalRecordCount": 6},
            {"Items": [movie("3", played=False), movie("4", imdb="")], "TotalRecordCount": 6},
            {"Items": [movie("5"), movie("6", imdb="tt2")], "TotalRecordCount": 6},
        ]
    )

    assert Jellyfin(library).watched("source") == {"tt1", "tt2"}


@pytest.mark.parametrize("users", [[], [{"Id": "a", "Name": "source"}] * 2])
def test_account_must_exist_and_be_unique(users):
    with pytest.raises(SyncError, match="uniquely"):
        Jellyfin(Library([], users)).watched("source")


@pytest.mark.parametrize("last_page", [[], [movie("1")]])
def test_incomplete_or_repeating_pages_are_rejected(last_page):
    library = Library(
        [
            {"Items": [movie("1")], "TotalRecordCount": 2},
            {"Items": last_page, "TotalRecordCount": 2},
        ]
    )

    with pytest.raises(SyncError):
        Jellyfin(library).watched("source")
