{ inputs, pkgs }:
let
  server = inputs.self.nixosConfigurations.beast.config;
  movie = pkgs.runCommand "jellyfin-transliteration-movie.mkv" { } ''
    ${pkgs.ffmpeg-headless}/bin/ffmpeg -v error \
      -f lavfi -i color=c=blue:s=64x64:r=1 -t 2 -c:v mpeg4 -f matroska "$out"
  '';
  node = {
    services.jellyfin = {
      enable = true;
      package = server.services.jellyfin.package;
    };
    environment.systemPackages = [ pkgs.curl ];
    virtualisation = {
      cores = 2;
      memorySize = 2048;
      diskSize = 4096;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "jellyfin-transliteration";

  nodes = {
    generic = node;
    bgn = node // {
      systemd.services.jellyfin.environment.JELLYFIN_TRANSLITERATOR_ID =
        server.systemd.services.jellyfin.environment.JELLYFIN_TRANSLITERATOR_ID;
    };
  };

  testScript = ''
    MOVIE = "${movie}"
  ''
  + builtins.readFile ./lib/jellyfin.py
  + builtins.readFile ./jellyfin-transliteration/test.py;
}
