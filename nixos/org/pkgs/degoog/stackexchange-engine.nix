{
  fetchFromGitHub,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "degoog-stackexchange-engine";
  version = "1.0.0-unstable-2026-06-02";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchFromGitHub {
    owner = "Pross";
    repo = "degoog-stackexchange-engine";
    rev = "b575a2f4253f77f3376657b87e279327fa1b654b";
    hash = "sha256-kjmpV+VHB3p1rLHfe7VV6EYxgyd9ijU1XOiN7TrBiT4=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    cp -R engines/stackexchange "$out"

    runHook postInstall
  '';

  passthru.updateScript = [ ./update-stackexchange-engine.sh ];

  meta = {
    description = "Stack Exchange search engine extension for Degoog";
    homepage = "https://github.com/Pross/degoog-stackexchange-engine";
    changelog = "https://github.com/Pross/degoog-stackexchange-engine/commits/main";
    platforms = lib.platforms.all;
  };
}
