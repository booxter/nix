# Current Blu-ray queue review

The three case JSON files are fresh read-only inspections of the unprocessed
srvarr queue items. `identification/bluray-playlists.json` records MKVToolNix
identification for every primary playlist on those discs.

On 2026-09-18, the configured OpenRouter model `openai/gpt-5.6-sol` was run
four times per case with high reasoning and 4096 output tokens. Each decision
passed the corpus expectation on its first attempt:

- Pandora's Mirror: remux `00000.mpls` (93.8 min, 5 chapters;
  Radarr 94 min). Result: 4/4.
- The Double Exposure of Holly: remux `00000.mpls` (74.8 min,
  4 chapters; Radarr 75 min). Result: 4/4.
- XConfessions 2: abstain (both feature playlists are 100.6 min;
  Radarr 116 min). Result: 4/4.

The isolated Blu-ray worker was also run against each live queue item without
activating a new system. Its case IDs and playlist capability IDs matched the
captured corpus for all three items.

On 2026-09-19, MKVToolNix remuxed each positive case's chosen playlist into a
temporary MKV on srvarr. FFprobe found the expected Matroska output, chapters,
and stream types in both files:

- Pandora's Mirror: 5629.499 seconds, 5 chapters, 1 video, 3 audio,
  1 subtitle stream; 22,006,977,393 bytes.
- The Double Exposure of Holly: 4490.570 seconds, 4 chapters, 1 video,
  1 audio, 1 subtitle stream; 20,154,156,930 bytes.

Both temporary MKVs were removed after inspection. The negative XConfessions 2
case was not remuxed. The controller's staged artifact and Radarr import flow
still requires live integration validation before automatic rollout.
