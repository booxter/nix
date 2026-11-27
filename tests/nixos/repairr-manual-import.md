# Radarr manual import scenarios

Run each scenario in an isolated NixOS VM with a fresh Repairr database.
Fake Radarr offers one completed download awaiting import and counts every
manual-import POST it receives. Repairr resolves the queue entry to its movie
and download, checks eligibility, and inspects a real video file. A scripted
planner selects the file offered in that case.

## Successful import

The source stays unchanged. Repairr authorizes the selected file and records
the import intent, including the movie, download, source path, and Radarr
history baseline, before submitting the command. Fake Radarr receives the
selected file for the expected movie and accepts the command. The attempt
stays pending until a matching import appears in history after the baseline.
Repairr then records the receipt and marks the attempt confirmed.
Radarr receives exactly one submission.

## Selected file replaced

After the planner selects the file and before authorization, replace it with
a different file of the same length at the same path. Repairr checks the
current file against the planned identity and stops the attempt. The recorded
reason identifies the changed source, and the replacement stays untouched.
Radarr receives zero submissions.

## Accepted command with a lost response

Fake Radarr accepts the POST, drops the connection before returning a command
ID, and withholds the import history entry. Restart the Repairr process with
the same database while the outcome is unknown. Keep fake Radarr running so
its request count spans the restart.

The restarted process resumes from the saved intent. Wait for it to check
history while the entry is still absent and verify that the attempt remains
pending. Then expose the matching import. Repairr confirms the original
attempt from that receipt. Radarr receives exactly one submission across both
processes.
