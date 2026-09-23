# Current Lidarr queue review

This directory contains the 25 planner-visible cases assembled from direct
audio directories in Lidarr's queue on 2026-09-22. The cases contain no source
paths, controller state, or API credentials. Three additional eligible queue
entries contained no supported audio and therefore did not produce planner
cases.

The deployed OpenRouter planner used `openai/gpt-5.6-sol`, high reasoning, and
4096 output tokens. All 25 directory cases were rebuilt from normalized current
evidence and planned in one shadow-only v3 pass. A subsequent controller pass
reused all 26 stored decisions, including the existing tar case, without
another model call.

The directory decisions were:

- 15 `no_repair/incomplete_release`
- 5 `no_repair/unsupported_repair`
- 3 `no_repair/unsafe_to_repair`
- 1 `no_repair/ambiguous_release`
- 1 `import_missing_tracks_v1`

The positive case is Ye's *Late Registration*, release 30485. The release is
missing only track 395518, “Skit #1”; artifact
`artifact:07aef6cea64fcc1abd8c3a98b9f5b7ced7549bcd0ea194d0651248777ab1cbad`
is track 5, carries the matching title tag, and is 33.573 seconds long against
the catalog's 34 seconds. The planner maps only that artifact and ignores the
files for tracks already present.

The `unsafe_to_repair` result for The Fall remains a conservative fallback
after both attempts exhausted the output-token limit on an unusually large
case. No repair was applied during this review: the controller was deployed
without apply mode or action and source allowlists.
