# Media repair workflow

## Workspace

- `input/torrents` contains completed Radarr torrent downloads.
- `input/usenet-manual`, when present, contains completed Usenet downloads.
- `output/processed` is the only persistent writable media directory.

The task gives you exact source and output paths. Use only those paths. Never
mix artifacts from unrelated downloads.

The task contract is authoritative. Do not investigate Radarr, the post
processor, download clients, containers, systemd units, host processes, or
files outside the workspace. Do not search `/var/lib`, `/var/log`, `/run`, or
application state for another explanation. Use `radarr_queue_status` and its
messages as the complete description of Radarr's observed failure. The source
fingerprint is an opaque correlation value, not a file checksum; copy it into
`result.json` unchanged.

## Single-file fast path

When the task source is one regular media file, follow this algorithm exactly:

1. Operate on the exact `source_path`. Do not list its parent directory or any
   unrelated workspace path.
2. Probe the source once with `ffprobe`.
3. If the probe succeeds, perform no further source diagnosis. Immediately
   create a lossless stream-copy remux beneath the task output directory. The
   Radarr handoff itself is sufficient reason for this normalization remux.
4. Probe the remux once with `ffprobe`. If it succeeds and reports the expected
   streams, immediately write `report.md`, then `result.json`, and end the
   task.
5. Only when the probe or remux fails may you perform one targeted diagnostic.
   Apply a clearly justified repair if one is available; otherwise report the
   task unresolved.

`movie_runtime_minutes` is approximate catalog metadata. Never interpret a
duration difference as evidence that the source is truncated. Do not use
`mediainfo`, Python or other custom scripts, `xxd`, `od`, `hexdump`, manual
EBML or MP4 atom parsing, head or tail decodes, or full-file decodes on the
successful-probe path. Do not repeat equivalent probes or investigate harmless
container anomalies after the remux validates.

## Procedure

1. Use the single-file fast path when applicable. For a directory source, list
   that exact directory and identify samples, extras, archives, multipart
   files, subtitles, and metadata files.
2. For a directory source, inspect plausible media with `file`, `mediainfo`,
   and `ffprobe`. Compare duration, streams, codecs, resolution, timestamps,
   and multipart naming.
3. Choose the smallest safe repair supported by the evidence. Work
   autonomously and do not request approval.
4. Prefer `join-media-parts` for compatible multipart movies. Use direct
   `ffmpeg` operations only when the specialized tool is insufficient and the
   exact transformation is understood.
5. Write all generated files beneath the task's output directory. Never write
   temporary or final files into `input/`.
6. Inspect the completed output again with `ffprobe` or `mediainfo`. Check that
   it is readable, has the expected duration and streams, and is not truncated.
   When those checks pass, stop diagnosis; do not search for additional causes
   or perform redundant validation.
7. Write `report.md` in the task output directory. Include the selected inputs,
   observations, commands or tools used, validation results, remaining
   uncertainty, and the candidate file Radarr should import.
8. Write `result.json` last. It must contain exactly these fields:

   ```json
   {
     "schema_version": 1,
     "attempt_id": "the task attempt ID",
     "download_id": "the task download ID",
     "source_fingerprint": "the task source fingerprint",
     "outcome": "repaired",
     "candidate": "path/to/movie.mkv",
     "reason": "concise outcome summary"
   }
   ```

   `candidate` is relative to the task output directory. For an unresolved
   task, set `outcome` to `unresolved` and `candidate` to `null`. Do not write
   `result.json` until all output and the report are complete.

If no safe repair is justified, leave the source untouched and clearly explain
the uncertainty in the report and result.
