{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule rec {
  pname = "jellyfin-exporter";
  version = "1.5.0-unstable-2026-05-09";
  rev = "b8d2a8887095ad10a4635d7685a67fe1a8b41e4f";

  src = fetchFromGitHub {
    owner = "booxter";
    repo = "jellyfin_exporter";
    inherit rev;
    sha256 = "0rjmxk2mvhp70nqzz34936p2nc2855n827yq04ldvn33qdmxqxp1";
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
