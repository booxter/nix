{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule rec {
  pname = "jellyfin-exporter";
  version = "1.5.0-unstable-2026-05-08";
  rev = "f70ea2010fbd27e8b3ffa0dd77304275eedeb581";

  src = fetchFromGitHub {
    owner = "booxter";
    repo = "jellyfin_exporter";
    inherit rev;
    sha256 = "12h8vg8q4dpx07alphy5pz9z92n2b4abkn46xk52bc2xanhbqkb2";
  };

  vendorHash = "sha256-p/6wv5XExUg1B8G2RiXXGAwxWyoIXmB4Y63hNGFRZJs=";

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Prometheus exporter for Jellyfin metrics";
    homepage = "https://github.com/booxter/jellyfin_exporter";
    changelog = "https://github.com/booxter/jellyfin_exporter/commit/${rev}";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "jellyfin_exporter";
    platforms = lib.platforms.unix;
  };
}
