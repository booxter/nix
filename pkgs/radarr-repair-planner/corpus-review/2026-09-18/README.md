# Current Blu-ray queue review

The three case JSON files are fresh read-only inspections of the unprocessed
srvarr queue items. `bluray-playlists.json` records MKVToolNix identification
for every primary playlist on those discs.

On 2026-09-18, the configured OpenRouter model `openai/gpt-5.6-sol` was run
four times per case with high reasoning and 4096 output tokens. Each decision
passed the corpus expectation on its first attempt:

- Pandora's Mirror: remux `00000.mpls` (93.8 min, 5 chapters;
  Radarr 94 min). Result: 4/4.
- The Double Exposure of Holly: remux `00000.mpls` (74.8 min,
  4 chapters; Radarr 75 min). Result: 4/4.
- XConfessions 2: abstain (both feature playlists are 100.6 min;
  Radarr 116 min). Result: 4/4.

These results validate the model's playlist choices for the captured cases.
They do not validate remux output or a live worker integration.
