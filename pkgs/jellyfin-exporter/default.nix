{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule rec {
  pname = "jellyfin-exporter";
  version = "1.5.0";

  src = fetchFromGitHub {
    owner = "rebelcore";
    repo = "jellyfin_exporter";
    rev = "v${version}";
    sha256 = "1siskjahbh2jsxbl7bvlaxcq6k84jiws0h219mwl6rlsmi6nvpwb";
  };

  vendorHash = "sha256-p/6wv5XExUg1B8G2RiXXGAwxWyoIXmB4Y63hNGFRZJs=";

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Prometheus exporter for Jellyfin metrics";
    homepage = "https://github.com/rebelcore/jellyfin_exporter";
    changelog = "https://github.com/rebelcore/jellyfin_exporter/releases/tag/v${version}";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "jellyfin_exporter";
    platforms = lib.platforms.unix;
  };
}
