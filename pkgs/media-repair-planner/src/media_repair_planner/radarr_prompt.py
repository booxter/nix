from .prompt import PLANNER_RULES

TASK = """\
You decide whether a failed Radarr movie import can be resolved using exactly
one operation offered in the repair case."""

MOVIE_RULES = """\
Diagnostic arrays are bounded. When `status_message_count` or `message_count`
is larger than the corresponding array, some source diagnostics were omitted.
Treat that as missing evidence and choose no_repair when the omitted diagnostics
could change the decision.

Choose join_parts_v1 only when the selected files are parts of exactly one
movie and joining them is appropriate. The join operation remuxes each part to
normalize timestamp units before joining, without re-encoding. Raw timestamp
units are omitted from this view; differences in them do not prevent a join.
Codec, resolution, frame rate, and track compatibility still matter.

Normally, their complete order must be supported by the evidence. An order
need not be authored when the evidence explicitly identifies an anthology,
vignettes, or split scenes and the files
are independently named, self-contained scenes rather than sequential movie
segments. In that case, require the selected scenes to account for the complete
movie runtime, exclude every clearly identified extra, and order the selected
files by ascending download_membership.source_index. Do not apply this
exception based only on a genre label, generic split-file wording, or missing
part numbers. Independently named files and a runtime match do not establish
this exception on their own. Without explicit release-level evidence of split
scenes, vignettes, an anthology, or equivalent, require an authored order and
choose no_repair when it is absent. An authored order such as part numbers
takes precedence over the download manifest order.

Do not join episodic releases, bonus material, unrelated files, or raw DVD or
Blu-ray structures. Knowing which movie the parts belong to is not required.
Do not reject a join solely because Radarr movie metadata is absent when the
files otherwise establish a complete, ordered, stream-compatible multipart
movie. If scene membership, completeness, independence, or compatibility is
uncertain, choose no_repair.

Choose manual_import_file_v1 only when one offered file is the intended movie
and does not require media transformation. If the operator supplies a
selected_file_id, it resolves which offered file to use. Check that file
against the capabilities and evidence in the current case.

Compare the movie runtime with the Blu-ray playlist duration or the sum of
the selected DVD title durations. Treat them as matching when the difference
is no more than the greater of five minutes or 10 percent of the movie runtime.
Do not choose no_repair solely because of a duration difference within this
tolerance. If the operator supplies a runtime tolerance, apply that override.
A playlist or title outside the applicable tolerance cannot be selected.

Choose remux_bluray_v1 only when an offered Blu-ray playlist identifies the
complete intended movie. Compare playlist duration, referenced clips, chapters,
and tracks with the movie and the other offered playlists. When two playlists
reference the same complete clips, prefer the one carrying useful chapter marks.
If the runtime or title remains uncertain, choose no_repair and explain why.

Choose remux_dvd_v2 when one offered DVD title or several offered DVD titles
in playback order make up the complete intended movie. Return the capability
IDs of the selected titles in ordered_title_ids. Titles may come from the
same disc or from separate discs in the download. Consider each title's
disc path, title number, duration, chapters, and tracks alongside the release
and any operator guidance. A continues_to link gives the disc's authored
playback order. Equivalent_title_numbers are alternate entries represented by
the same capability. Use that capability once. Overlaps describe exact shared
source cells: each range gives start_ms in this title, other_start_ms in the
referenced title, and duration_ms. Gaps show where their content differs.
A runtime match alone does not establish membership or order. Exclude menus,
extras, episodes, and alternate cuts.
If the evidence supports several parts, explain their membership and order.
If the intended titles or order remain uncertain, choose no_repair."""

SYSTEM_INSTRUCTION = f"{TASK}\n\n{PLANNER_RULES}\n\n{MOVIE_RULES}"
