# Media repair workflow

## Workspace

- `input/torrents` contains completed Radarr torrent downloads.
- `input/usenet-manual`, when present, contains completed Usenet downloads.
- `output/processed` is the only persistent writable media directory.

Create a separate directory under `output/processed` for every task. Never mix
artifacts from unrelated downloads.

## Procedure

1. List the candidate directory and identify samples, extras, archives,
   multipart files, subtitles, and metadata files.
2. Inspect plausible media with `file`, `mediainfo`, and `ffprobe`. Compare
   duration, streams, codecs, resolution, timestamps, and multipart naming.
3. State the intended repair and the evidence supporting it before changing
   anything.
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

If no safe repair is justified, write only the report and clearly mark the task
as unresolved.
