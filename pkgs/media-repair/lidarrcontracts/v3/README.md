# Lidarr repair protocol version 3

The controller supplies the planner with the selected Lidarr album and its
releases and tracks, content-derived evidence for every materialized audio
artifact, and Lidarr's own manual-import assessment of those artifacts.

The only repair action in version 3 maps distinct offered artifacts to one or
more tracks currently missing from one Lidarr release. A decision may leave
other missing tracks unresolved. Existing tracks are outside the capability
and cannot be replaced. Paths, download IDs, import quality, commands, and
other host details remain controller-local. The controller validates the
mapping against the advertised capability and current Lidarr state before it
can execute an explicit manual-import command.

Artifact IDs are compact, case-local handles. They join artifacts,
assessments, capabilities, and decisions without making the planner repeat
content hashes. The separate artifact fingerprint carries content identity and
is revalidated by the controller.

`case_id` is `sha256:` followed by the lowercase SHA-256 digest of the RFC 8785
canonical JSON representation after removing `case_id` and `observed_at`.
