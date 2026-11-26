# Plugin catalogue

Beast serves its source-built external plugins on loopback. The five built-in
providers remain part of the pinned Jellyfin server package. Jellyfin owns
plugin installation, updates and configuration; Jellarr owns the desired list
and managed settings.

Each upstream version is padded to four components. The final component becomes
`upstream * 100 + localRevision`, reserving revisions 1–99 for our rebuilds.
Increment `localRevision` when changing a patch or dependency of an existing release.

Deploying makes releases available. Jellyfin's plugin update task installs them;
a server restart loads them. Rolling back Nix restores the catalogue but does
not downgrade plugins already installed by Jellyfin.
