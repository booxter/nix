# Media repair workflow

## Workspace

- `input/torrents` contains completed Radarr torrent downloads.
- `input/usenet-manual`, when present, contains completed Usenet downloads.
- `output/processed` is the only persistent writable media directory.

The task gives you exact source and output paths. Use only those paths. Never
mix artifacts from unrelated downloads.

## Procedure

1. List the candidate directory and identify samples, extras, archives,
   multipart files, subtitles, and metadata files.
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
