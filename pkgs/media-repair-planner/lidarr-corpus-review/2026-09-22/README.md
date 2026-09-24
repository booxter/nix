# Current Lidarr queue review

This directory contains the 25 planner-visible cases assembled from direct
audio directories in Lidarr's queue on 2026-09-22. The cases contain no source
paths, controller state, or API credentials. Three additional eligible queue
entries contained no supported audio and therefore did not produce planner
cases.

The OpenRouter evaluation used `openai/gpt-5.6-sol`, the OpenAI provider, high
reasoning, and 4096 output tokens. All 25 cases were migrated to the v3
protocol with compact case-local artifact IDs. The final shadow-only pass
produced a valid decision on the first attempt for every case.

The directory decisions were:

- 8 `no_repair/incomplete_release`
- 5 `no_repair/unsafe_to_repair`
- 4 `no_repair/unsupported_repair`
- 1 `no_repair/ambiguous_tracks`
- 7 `import_missing_tracks_v1`

The positive decisions were:

- In Strict Confidence, *Love Kills!*, release 33154: 11 safe mappings; the
  conflicting twelfth track and three unmatched extras are omitted.
- King Crimson, *THRAK*, release 3868: 16 safe stereo/original-mix mappings;
  the distinct surround tracks are omitted.
- The Fall, *Cerebral Caustic*, release 32957: all 77 expanded-edition tracks.
- Ye, *Late Registration*, release 30485: the sole missing track, “Skit #1.”
- Marillion, *marillion.com*, release 31038: 49 safe mappings; “Brave” is
  absent and omitted.
- The Fugs, *Tenderness Junction*, release 14180: 9 safe mappings; the
  differently segmented tenth track and second-album files are omitted.
- Belinda Carlisle, *Heaven on Earth*, release 32527: 12 safe mappings;
  “Should I Let You In?” is absent and omitted.

Before the final corpus pass, Belinda Carlisle and Marillion were each checked
in three focused runs and produced the same 12- and 49-track selections. The
77-track Fall case also passed a focused run after compact IDs reduced its
prompt from roughly 68,000 to 41,000 tokens and its response to 2,919 tokens.

No repair was applied during this review.
