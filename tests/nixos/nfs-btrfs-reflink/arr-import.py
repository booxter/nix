"""Exercise Arr manual imports through the running services' public APIs."""

import argparse
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class Arr:
    port: int
    version: int = 3

    def request(self, path: str, payload=None, *, method: str | None = None):
        data = None if payload is None else json.dumps(payload).encode()
        query = Request(
            f"http://127.0.0.1:{self.port}/api/v{self.version}/{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json", "X-Api-Key": "reflink-test-api-key"},
        )
        try:
            with urlopen(query, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            raise AssertionError(f"{path}: {error.code}: {error.read().decode()}") from error

    def wait_for_command(self, command_id: int) -> None:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            command = self.request(f"command/{command_id}")
            assert command["status"] != "failed", command
            if command["status"] == "completed":
                return
            time.sleep(1)
        raise AssertionError(f"Command timed out: {command}")


def import_movie() -> str:
    api = Arr(7878)
    library = "/mnt/media/library/movies"
    source = Path("/mnt/media/torrents/radarr/Reflink Movie (2020).mkv")
    api.request("rootfolder", {"path": library})
    profiles = api.request("qualityprofile")
    movie = api.request(
        "movie",
        {
            "title": "Reflink Movie",
            "tmdbId": 1,
            "qualityProfileId": profiles[0]["id"],
            "rootFolderPath": library,
            "monitored": False,
            "minimumAvailability": "released",
            "addOptions": {"searchForMovie": False},
        },
    )
    return import_copy(
        api, source, {"movieId": movie["id"]}, f"moviefile?movieId={movie['id']}", permissions=True
    )


def import_episode() -> str:
    api = Arr(8989)
    library = "/mnt/media/library/series"
    source = Path("/mnt/media/torrents/sonarr/Reflink Series S01E01.mkv")
    api.request("rootfolder", {"path": library})
    profiles = api.request("qualityprofile")
    series = api.request(
        "series",
        {
            "title": "Reflink Series",
            "tvdbId": 1,
            "qualityProfileId": profiles[0]["id"],
            "rootFolderPath": library,
            "monitored": False,
            "seasonFolder": True,
            "seriesType": "standard",
            "addOptions": {"searchForMissingEpisodes": False},
        },
    )
    refresh = api.request("command", {"name": "RefreshSeries", "seriesId": series["id"]})
    api.wait_for_command(refresh["id"])
    episodes = api.request(f"episode?seriesId={series['id']}")
    assert len(episodes) == 1, episodes
    return import_copy(
        api,
        source,
        {
            "seriesId": series["id"],
            "episodeIds": [episodes[0]["id"]],
        },
        f"episodefile?seriesId={series['id']}",
    )


def import_track() -> str:
    api = Arr(8686, version=1)
    library = "/mnt/media/library/music"
    source = Path("/mnt/media/torrents/lidarr/Reflink Track.flac")
    quality_profile = api.request("qualityprofile")[0]["id"]
    metadata_profile = api.request("metadataprofile")[0]["id"]
    api.request(
        "rootfolder",
        {
            "name": "Music",
            "path": library,
            "defaultQualityProfileId": quality_profile,
            "defaultMetadataProfileId": metadata_profile,
            "defaultMonitorOption": "none",
            "defaultNewItemMonitorOption": "none",
        },
    )
    artist = api.request(
        "artist",
        {
            "artistName": "Reflink Artist",
            "foreignArtistId": "11111111-1111-4111-8111-111111111111",
            "qualityProfileId": quality_profile,
            "metadataProfileId": metadata_profile,
            "rootFolderPath": library,
            "monitored": False,
            "addOptions": {"searchForMissingAlbums": False},
        },
    )
    refresh = api.request("command", {"name": "RefreshArtist", "artistId": artist["id"]})
    api.wait_for_command(refresh["id"])
    albums = api.request(f"album?artistId={artist['id']}")
    assert len(albums) == 1, albums
    album = albums[0]
    refresh = api.request("command", {"name": "RefreshAlbum", "albumId": album["id"]})
    api.wait_for_command(refresh["id"])
    tracks = api.request(f"track?albumId={album['id']}")
    assert len(tracks) == 1, tracks

    # Isolate copying from subsequent tag edits, which intentionally change data.
    metadata = api.request("config/metadataprovider")
    metadata["writeAudioTags"] = "no"
    api.request("config/metadataprovider", metadata, method="PUT")
    return import_copy(
        api,
        source,
        {
            "artistId": artist["id"],
            "albumId": album["id"],
            "albumReleaseId": album["releases"][0]["id"],
            "trackIds": [tracks[0]["id"]],
        },
        f"trackfile?artistId={artist['id']}",
        quality=6,
    )


def import_copy(
    api: Arr,
    source: Path,
    selection: dict,
    file_query: str,
    *,
    permissions: bool = False,
    quality: int = 4,
) -> str:
    original = source.read_bytes()
    media_management = api.request("config/mediamanagement")
    media_management["copyUsingHardlinks"] = True
    media_management["setPermissionsLinux"] = permissions
    media_management["chmodFolder"] = "777"
    api.request("config/mediamanagement", media_management, method="PUT")
    command = api.request(
        "command",
        {
            "name": "ManualImport",
            "importMode": "copy",
            "files": [
                {
                    "path": str(source),
                    **selection,
                    "quality": {"quality": {"id": quality}, "revision": {"version": 1}},
                    "languages": [{"id": 1, "name": "English"}],
                }
            ],
        },
    )
    api.wait_for_command(command["id"])
    files = api.request(file_query)
    assert len(files) == 1, files
    destination = Path(files[0]["path"])
    assert source.read_bytes() == original, "Import changed the torrent source"
    assert original == destination.read_bytes()
    assert not source.samefile(destination)
    with destination.open("rb") as stream:
        os.fsync(stream.fileno())
    return str(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    imports = {"radarr": import_movie, "sonarr": import_episode, "lidarr": import_track}
    parser.add_argument("app", choices=imports)
    args = parser.parse_args()
    destination = imports[args.app]()
    Path(f"/tmp/{args.app}-results.json").write_text(json.dumps([destination]))


if __name__ == "__main__":
    main()
