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

When the task source is one regular media file:

1. Inspect it once with `ffprobe` and, when useful, `mediainfo`.
2. If its streams are readable and plausible for the requested movie, create a
   lossless stream-copy remux beneath the task output directory. The Radarr
   handoff itself is sufficient reason for one normalization remux; do not try
   to reproduce Radarr's internal rejection first.
3. Validate the remux once with `ffprobe` or `mediainfo`. Use a short head or
   tail decode only when truncation is suspected. Do not run a full-file decode
   or parse container bytes unless the ordinary probe or remux reports an
   error that requires it.
4. Once the candidate parses, has the expected streams and a plausible
   duration, stop investigating and immediately write `report.md` and
   `result.json`.

Do not repeat equivalent probes or pursue harmless container anomalies after
the remux validates. Limit diagnosis to the initial inspection and one targeted
follow-up before choosing the repair or reporting the task unresolved.

## Procedure

1. Use the single-file fast path when applicable. For a directory source, list
   that exact directory and identify samples, extras, archives, multipart
   files, subtitles, and metadata files.
2. Inspect plausible media with `file`, `mediainfo`, and `ffprobe`. Compare
   duration, streams, codecs, resolution, timestamps, and multipart naming.
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
