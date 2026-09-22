# Radarr repair protocol version 2

Version 2 keeps the version 1 actions and safety boundaries while representing
download evidence without assuming Transmission or torrents. The controller
may report a `torrent` from `transmission` or a `usenet` download from
`sabnzbd`.

`content_ownership` distinguishes an explicit client manifest from a completed
post-processing output tree. Each observed file has either null
`download_membership` or a membership object containing its optional source
index, selection state, source size, and available bytes. A SABnzbd output-tree
file therefore has a null source index without pretending to be untracked.

The JSON Schemas remain the authoritative wire contracts. Go and Python models
are generated during Nix builds and are not checked in. Objects are closed to
unknown properties, externally sourced text is untrusted, absolute paths and
raw download IDs stay controller-local, and all identifiers sent to the planner
are opaque.

`case_id` is `sha256:` followed by the lowercase SHA-256 digest of the RFC 8785
canonical JSON representation after removing `case_id` and `observed_at`.
Schema validation cannot establish reference membership or compare a decision
with its request; the controller performs those semantic checks independently.

The decision actions are `no_repair`, `join_parts_v1`,
`manual_import_file_v1`, and `remux_bluray_v1`. The Blu-ray action selects one
offered playlist capability. Its clip order, duration, chapters, and tracks
come from MKVToolNix identification and are bound to inventoried files. The
planner cannot choose a path, output name, executable, command argument, movie
ID, quality, language, release group, or import mode.
