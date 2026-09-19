# DVD canary queue review

The JSON case is the planner-visible state captured by the deployed shadow
controller for `PINK_VELVET_2` on srvarr. It contains no controller file paths
or API credentials. The DVD title identifier offered title 1, 9,779 seconds,
12 chapters, MPEG-2 video, and AC-3 audio. Radarr lists the movie as 163
minutes. Four shorter titles were filtered out before planning.

The controller's first shadow decision selected the offered DVD title. The
evaluation manifest also includes a synthetic 90-minute runtime mismatch
based on this case; the expected decision for that variant is `no_repair`.
The configured model abstained in all three approved high-reasoning runs of
the negative case: twice for insufficient evidence and once for ambiguous
file selection. No run chose a remux.

After fixing FFprobe's handling of unrequested MPEG-2 side data, the stored
positive decision completed the canary import on srvarr. The published MKV was
6,969,755,732 bytes with MPEG-2 video, AC-3 audio, 12 chapters, and a duration
of 9,788.385 seconds. Radarr confirmed movie file 10859 and removed queue
record 1064302078. The initial failed probe execution is retained in the
controller's retry backup directory.
