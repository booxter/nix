{
  fetchgit,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "degoog-devinside-extensions";
  version = "0-unstable-2026-07-11";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchgit {
    url = "https://codeberg.org/devinside/devinside-degoog.git";
    rev = "1b44fb9f717cfbfdc0a8ba1124f750f10338a404";
    hash = "sha256-knv+PHGd3REKmlH+rdQg/GMxZ2RSj0KqU+Csvu4Y/b4=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    cp -R . "$out"

    runHook postInstall
  '';

  passthru.updateScript = [ ./update-devinside-extensions.sh ];

  meta = {
    description = "Degoog extension catalog maintained by devinside";
    homepage = "https://codeberg.org/devinside/devinside-degoog";
    changelog = "https://codeberg.org/devinside/devinside-degoog/commits/branch/main";
    platforms = lib.platforms.all;
  };
}
