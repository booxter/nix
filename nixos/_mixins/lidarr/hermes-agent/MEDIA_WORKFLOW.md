# Media repair workflow

## Workspace and contract

- `input/torrents` contains completed Lidarr torrent downloads.
- `input/usenet-manual`, when present, contains completed Usenet downloads.
- `output/processed` is the only persistent writable media directory.

Use only the exact source and output paths in the task. Ignore any
`_arr-post-processor` or `_lidarr-cue-split` directory in the source. Do not
inspect Lidarr state, services, logs, other downloads, or artifacts from another
task. The task catalog and queue status are authoritative.

External network access is unavailable by design. Do not attempt `curl`,
MusicBrainz queries, or other Internet lookups. Treat the task catalog as the
complete release catalog; lack of network access is not a repair failure.

The catalog may contain several releases with different track or disc layouts.
Select a release only when the source can produce every track in that release
and the available evidence uniquely identifies it. `any_release_ok` does not
permit an arbitrary choice between indistinguishable releases. If multiple
catalog releases remain equally compatible, report the task as unresolved.
Catalog durations are approximate evidence, not exact boundaries.

## Procedure

1. Inspect the exact source directory and identify CUE sheets, referenced audio,
   archives, independently playable tracks, and disc structure.
2. Compare titles, performers, embedded metadata, track counts, disc layout,
   order, and durations with every catalog release. Do not select a release
   using filenames alone, and do not break a tie arbitrarily.
3. If the source is archived, inspect it before extraction. Reject encrypted,
   unsafe, ambiguous, or unexpectedly large archives. Extract only below the
   task output directory.
4. For an image-style CUE, use `unflac` to inspect and split it. Do not split a
   CUE that already references one distinct audio file per track.
5. Preserve lossless audio. Do not transcode merely to change a container or
   manufacture missing tracks. Never pad, truncate, or synthesize audio to make
   durations agree with the catalog.
6. Write every candidate below the task output directory. Verify each completed
   file with `flac --test` when it is FLAC and inspect its streams and duration
   with `ffprobe`.
7. Confirm that the candidates cover every track ID in the selected release
   exactly once. Extra source material may be excluded only when the catalog
   clearly identifies it as outside the selected release.
8. Write `report.md` with the selected release, source evidence, transformations,
   validation, proposed track mapping, and remaining uncertainty.
9. Write `result.json` last. It must contain exactly these fields:

   ```json
   {
     "schema_version": 1,
     "attempt_id": "the task attempt ID",
     "download_id": "the task download ID",
     "source_fingerprint": "the task source fingerprint",
     "outcome": "repaired",
     "release_id": 123,
     "files": [
       {
         "candidate": "disc-01/01.flac",
         "expected_track_ids": [456]
       }
     ],
     "reason": "concise outcome summary"
   }
   ```

Candidate paths are relative to the task output directory. For an unresolved
task, set `release_id` to `null` and `files` to an empty list. Do not write the
manifest until every output and the report are complete.
