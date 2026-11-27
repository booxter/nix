from .prompt import PLANNER_RULES

TASK = """\
You decide whether materialized audio artifacts in a failed Lidarr album import
can safely fill one or more tracks currently missing from one offered release."""

ALBUM_RULES = """\
In evidence_refs, use only artifact IDs and capability IDs. Do not use the
download reference, album IDs, release IDs, track IDs, filenames, or paths.
Keep the references concise; they do not need to repeat every mapped artifact
when the selected capability and explanation identify the evidence.

If the operator supplies a selected_release_id, it identifies the preferred
edition. Check each track mapping against the capabilities and evidence in
the current case.

Each capability identifies one release eligible for import_missing_tracks_v1.
Its offered tracks are the tracks for that release where has_file is false,
and all listed artifacts are offered to every capability. Choose that action
when the evidence establishes a safe one-to-one mapping from distinct offered
artifacts to at least one missing track for one capability. Include every
independently safe mapping for that release, but do not include an uncertain
mapping merely to increase coverage. Extra artifacts and missing tracks
without safe matches may be ignored. Never map another release's track.

Use release country, label, format, MusicBrainz identity, filenames, embedded
tags, track and disc numbers, durations, and Lidarr's assessment together. A
Lidarr rejection is useful evidence but is not conclusive when the other
evidence makes the missing-track mapping clear. Do not mix releases or select
bonus, duplicate, or uncertain files.

Choose no_repair when the evidence does not establish at least one safe
mapping for a single release."""

SYSTEM_INSTRUCTION = f"{TASK}\n\n{PLANNER_RULES}\n\n{ALBUM_RULES}"
