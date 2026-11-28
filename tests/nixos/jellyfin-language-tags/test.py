# ruff: noqa: F821
# The NixOS driver and shared Jellyfin API helper supply globals.
import time
from datetime import timedelta
from urllib.parse import urlencode

MOVIE_PATH = "/srv/movies/Replacement/movie.mkv"


def movie():
    items = api("Items?Recursive=true&IncludeItemTypes=Movie&Fields=Tags,MediaStreams,Path")[
        "Items"
    ]
    assert len(items) == 1, items
    assert items[0]["Path"] == MOVIE_PATH, items
    return items[0]


def audio_languages(item):
    return {stream.get("Language") for stream in item["MediaStreams"] if stream["Type"] == "Audio"}


def language_tags(item):
    return {tag for tag in item["Tags"] if tag.startswith("language_")}


def scan_library():
    def task():
        return next(task for task in api("ScheduledTasks") if task["Key"] == "RefreshLibrary")

    previous = task().get("LastExecutionResult")
    api("Library/Refresh", method="POST")

    def completed(_):
        current = task()
        result = current.get("LastExecutionResult")
        if current["State"] != "Idle" or result == previous:
            return False

        assert result["Status"] == "Completed", result
        return True

    retry(completed, timeout=timedelta(seconds=120))


def wait_for_replacement(item_id):
    def refreshed(_):
        item = movie()
        assert item["Id"] == item_id, item
        return audio_languages(item) == {"rus"}

    retry(refreshed, timeout=timedelta(seconds=120))


def wait_for_tags(expected):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        item = movie()
        if language_tags(item) == expected:
            return True
        time.sleep(1)

    print(f"Tags did not converge: {item}")
    return False


machine.start()
machine.wait_for_unit("jellyfin.service")
machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/Startup/FirstUser")
token = ""
user = api("Startup/FirstUser")
api("Startup/Complete", method="POST")
token = api("Users/AuthenticateByName", method="POST", data={"Username": user["Name"]})[
    "AccessToken"
]

with subtest("the real plugin tags the original English audio"):
    plugins = {plugin["Id"].replace("-", ""): plugin for plugin in api("Plugins")}
    assert PLUGIN_ID.replace("-", "") in plugins, plugins
    plugin = plugins[PLUGIN_ID.replace("-", "")]
    assert plugin["Status"] == "Active", plugin
    assert plugin["Version"] == PLUGIN_VERSION, plugin
    configuration = api(f"Plugins/{PLUGIN_ID}/Configuration")
    configuration.update(
        AlwaysForceFullRefresh=False,
        AudioLanguageTagPrefix="language_",
        AddSubtitleTags=False,
        SynchronousRefresh=True,
    )
    api(f"Plugins/{PLUGIN_ID}/Configuration", method="POST", data=configuration)
    machine.succeed(
        f"install -Dm644 {FIXTURES}/eng.mkv {MOVIE_PATH}",
        f"touch -d '1 hour ago' {MOVIE_PATH}",
    )
    api(
        "Library/VirtualFolders?" + urlencode({"name": "Movies", "collectionType": "movies"}),
        method="POST",
        data={
            "LibraryOptions": {
                "PathInfos": [{"Path": "/srv/movies"}],
                "EnableRealtimeMonitor": True,
                "MetadataSavers": [],
                "TypeOptions": [{"Type": "Movie", "MetadataFetchers": [], "ImageFetchers": []}],
            }
        },
    )
    scan_library()
    original = movie()
    assert audio_languages(original) == {"eng"}, original
    assert wait_for_tags({"language_English"}), movie()
    # Manual refreshes must leave automatic tagging running for later replacements.
    api("LanguageTags/RefreshLanguageTags?type=movies", method="POST")
    assert language_tags(movie()) == {"language_English"}, movie()

with subtest("replacing the file updates its language tags without a forced refresh"):
    machine.succeed(
        f"install -m644 {FIXTURES}/rus.mkv /srv/replacement.mkv",
        f"mv -fT /srv/replacement.mkv {MOVIE_PATH}",
    )
    try:
        wait_for_replacement(original["Id"])
        updated = wait_for_tags({"language_Russian"})
        print(f"Replacement audio languages: {audio_languages(movie())}")
        print(f"Automatically refreshed language tags: {updated}")

        # Positive control: distinguish stale tags from broken media probing or tagging.
        api("LanguageTags/RefreshLanguageTags?type=movies", method="POST")
        assert language_tags(movie()) == {"language_Russian"}, movie()
        assert updated, (
            "Jellyfin detected Russian audio on the same movie, but its English tag survived; "
            "a forced language-tag refresh corrected it"
        )
    finally:
        print(machine.succeed("journalctl -u jellyfin -n 150 --no-pager"))
