# Lidarr repair protocol version 1

The controller supplies the planner with the selected Lidarr album and its
releases and tracks, content-derived evidence for every materialized audio
artifact, and Lidarr's own manual-import assessment of those artifacts.

The only repair action in version 1 maps each offered artifact to one Lidarr
track from one offered release. Paths, download IDs, import quality, commands,
and other host details remain controller-local. The controller validates the
mapping against the advertised capability and current Lidarr state before it
can execute an explicit manual-import command.

`case_id` is `sha256:` followed by the lowercase SHA-256 digest of the RFC 8785
canonical JSON representation after removing `case_id` and `observed_at`.
