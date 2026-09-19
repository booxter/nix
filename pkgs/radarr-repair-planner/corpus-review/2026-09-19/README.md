# DVD canary queue review

The JSON case is the planner-visible state captured by the deployed shadow
controller for `PINK_VELVET_2` on srvarr. It contains no controller file paths
or API credentials. The DVD title identifier offered title 1, 9,779 seconds,
12 chapters, MPEG-2 video, and AC-3 audio. Radarr lists the movie as 163
minutes. Four shorter titles were filtered out before planning.

The controller's first shadow decision selected the offered DVD title. The
evaluation manifest also includes a synthetic 90-minute runtime mismatch
based on this case; the expected decision for that variant is `no_repair`.
