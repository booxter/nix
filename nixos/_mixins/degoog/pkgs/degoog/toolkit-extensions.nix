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
  version = "0-unstable-2026-09-20";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchFromGitHub {
    owner = "SoPat712";
    repo = "degoog-toolkit";
    rev = "b6b6176b506f2305a102a5fe4f628c112148c442";
    hash = "sha256-Ns6bDGCmEAFEgYm97Xg9XVR3SQmopYohklC/0IUZyc4=";
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
