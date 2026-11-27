# ruff: noqa: F821, RUF001
# The NixOS driver and shared Jellyfin API helper supply globals.
import xml.etree.ElementTree as ET
from datetime import timedelta
from urllib.parse import urlencode

# The default pipeline must see й before cleanup, while BGN must produce y.
# Latin accents, other scripts, and numeric chunks retain their existing behavior.
SORT_KEYS = {
    "Йод": ("jod", "yod"),
    "Иод": ("iod", "iod"),
    "Жук": ("zuk", "zhuk"),
    "Зук": ("zuk", "zuk"),
    "Шар": ("sar", "shar"),
    "Щука": ("suka", "shchuka"),
    "Чай": ("caj", "chay"),
    "Яма": ("ama", "yama"),
    "Юла": ("ula", "yula"),
    "Ёж и йод": ("ez i jod", "yezh i yod"),
    "Е\u0308ж и и\u0306од": ("ez i jod", "yezh i yod"),
    "Новый": ("novyj", "novyy"),
    "Amélie": ("amelie", "amelie"),
    "Ωμέγα": ("omega", "omega"),
    "Серия 2": ("seria 0000000002", "seriya 0000000002"),
    "Серия 10": ("seria 0000000010", "seriya 0000000010"),
}


def add_movies():
    for index, title in enumerate(SORT_KEYS):
        directory = f"/srv/movies/{index}"
        machine.succeed(
            shlex.join(["install", "-D", "-m", "0644", MOVIE, f"{directory}/movie.mkv"])
        )
        metadata = ET.Element("movie")
        ET.SubElement(metadata, "title").text = title
        nfo = ET.tostring(metadata, encoding="unicode")
        machine.succeed(f"printf %s {shlex.quote(nfo)} > {directory}/movie.nfo")


def scan_movies():
    tasks = api("ScheduledTasks")
    previous = next(task for task in tasks if task["Key"] == "RefreshLibrary").get(
        "LastExecutionResult"
    )
    api("Library/Refresh", method="POST")

    def completed(_):
        task = next(task for task in api("ScheduledTasks") if task["Key"] == "RefreshLibrary")
        result = task.get("LastExecutionResult")
        if task["State"] != "Idle" or result == previous:
            return False

        assert result["Status"] == "Completed", result
        return True

    retry(completed, timeout=timedelta(seconds=120))


def movies(**filters):
    query = urlencode(
        {
            "Recursive": "true",
            "IncludeItemTypes": "Movie",
            "Fields": "SortName",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            **filters,
        }
    )
    return api("Items?" + query)["Items"]


def assert_sorting(mode):
    items = movies()
    actual = {item["Name"]: item["SortName"] for item in items}
    expected = {title: keys[mode] for title, keys in SORT_KEYS.items()}
    assert actual == expected, (actual, expected)

    keys = [item["SortName"] for item in items]
    assert keys == sorted(keys), items

    # Both the whole list and the existing A-Z picker must use the new keys.
    names = [item["Name"] for item in items]
    assert names.index("Иод") < names.index("Йод"), names
    assert names.index("Серия 2") < names.index("Серия 10"), names
    if mode == 1:
        assert names.index("Жук") < names.index("Зук"), names
        assert {item["Name"] for item in movies(NameStartsWith="Y")} == {
            "Йод",
            "Яма",
            "Юла",
            "Ёж и йод",
            "Е\u0308ж и и\u0306од",
        }


start_all()

for machine, mode in [(generic, 0), (bgn, 1)]:
    machine.wait_for_unit("jellyfin.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/Startup/FirstUser")
    token = ""
    user = api("Startup/FirstUser")
    api("Startup/Complete", method="POST")
    token = api("Users/AuthenticateByName", method="POST", data={"Username": user["Name"]})[
        "AccessToken"
    ]

    with subtest(f"{machine.name}: real library scan generates the expected transliterations"):
        add_movies()
        api(
            "Library/VirtualFolders?" + urlencode({"name": "Movies", "collectionType": "movies"}),
            method="POST",
            data={
                "LibraryOptions": {
                    "PathInfos": [{"Path": "/srv/movies"}],
                    "EnableRealtimeMonitor": False,
                    "TypeOptions": [{"Type": "Movie", "MetadataFetchers": [], "ImageFetchers": []}],
                }
            },
        )
        scan_movies()
        assert_sorting(mode)

    with subtest(f"{machine.name}: cached sort keys survive a server restart"):
        machine.succeed("systemctl restart jellyfin.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/health | grep -qx Healthy")
        assert_sorting(mode)
