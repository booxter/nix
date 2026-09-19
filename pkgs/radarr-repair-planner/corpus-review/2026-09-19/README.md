# Current queue review

## DVD canary

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

## Split-scene release

The Malice Before Daylight case was reconstructed from the stored queue
observation and fresh FFprobe metadata for all five numbered MP4 scenes.
FFprobe had rejected each scene because its optional video `handler_name`
contains a control character. Dropping that tag preserves the H.264, AAC, and
duration evidence. The corrected case offers a five-file join, and the
controller's join policy accepts the files in scene order. Their combined
duration is 7,381.88 seconds, consistent with Radarr's 123-minute runtime.

The configured OpenRouter planner selected that exact five-file order in all
three shadow calls. A worker-equivalent FFmpeg concat on srvarr produced a
temporary 6,635,524,147-byte MP4 with one H.264 video stream, one AAC audio
stream, and a 7,381.88-second duration. FFmpeg emitted no warnings. The
temporary output was removed; no import or publication occurred during these
checks.
