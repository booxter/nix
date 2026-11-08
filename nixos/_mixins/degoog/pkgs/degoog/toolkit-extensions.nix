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
  version = "0-unstable-2026-10-18";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchFromGitHub {
    owner = "SoPat712";
    repo = "degoog-toolkit";
    rev = "116e63df50f55ff46f6a4a6d596849c5053bee02";
    hash = "sha256-dRXJJtuPeRuqW3CBMr/PmCOxCOOZc7N5/mYhg/FUuh0=";
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
