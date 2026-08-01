{
  fetchgit,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "degoog-georgvwt-extensions";
  version = "0-unstable-2026-05-03";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchgit {
    url = "https://codeberg.org/Georgvwt/georgvwt-degoog-stuff.git";
    rev = "7a19dfd3396344883fdb5914375281d7c1731b9e";
    hash = "sha256-ogmomskKQU6WgVzCADZpVqyQDNBx0LKTulAZnae3vyI=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    cp -R . "$out"

    runHook postInstall
  '';

  passthru.updateScript = [ ./update-georgvwt-extensions.sh ];

  meta = {
    description = "Degoog extension catalog maintained by Georgvwt";
    homepage = "https://codeberg.org/Georgvwt/georgvwt-degoog-stuff";
    changelog = "https://codeberg.org/Georgvwt/georgvwt-degoog-stuff/commits/branch/main";
    platforms = lib.platforms.all;
  };
}
