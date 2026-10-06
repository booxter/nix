{
  degoogVersion,
  fetchFromGitHub,
  lib,
  stdenvNoCC,
}:

assert lib.assertMsg (lib.versionOlder degoogVersion "0.24.0") ''
  Remove stocks-degoog-0.23-slot-position.patch: Degoog ${degoogVersion}
  supports the Stocks plugin's full-width slot position.
'';
stdenvNoCC.mkDerivation {
  pname = "degoog-toolkit-extensions";
  version = "0-unstable-2026-10-06";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchFromGitHub {
    owner = "SoPat712";
    repo = "degoog-toolkit";
    rev = "f10352fe6861af13521f8a7d196c65135bee42a0";
    hash = "sha256-svZbGSLuUbbOJMmmyxjUm4sBV2+Vy5LD717hBOC9ZpY=";
  };

  patches = [ ./stocks-degoog-0.23-slot-position.patch ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    cp -R . "$out"

    runHook postInstall
  '';

  passthru.updateScript = [ ./update-toolkit-extensions.sh ];

  meta = {
    description = "Degoog extension toolkit maintained by SoPat712";
    homepage = "https://github.com/SoPat712/degoog-toolkit";
    changelog = "https://github.com/SoPat712/degoog-toolkit/commits/main";
    platforms = lib.platforms.all;
  };
}
