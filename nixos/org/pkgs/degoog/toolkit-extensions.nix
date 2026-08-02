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
  version = "0-unstable-2026-07-26";

  # Upstream publishes neither tags nor releases. Follow main through the
  # package update job while keeping the source pinned for reproducible builds.
  src = fetchFromGitHub {
    owner = "SoPat712";
    repo = "degoog-toolkit";
    rev = "b6f572fab75e177fc3185329d98478a6a650a3ff";
    hash = "sha256-0avQE1Ens+fyyPKgcfd14PaEBBAa9su48rJ5Tau3mTI=";
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
