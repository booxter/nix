{ pkgs, ... }:
let
  plugin = (import ../../nixos/beast/pkgs/jellyfin-plugins { inherit pkgs; }).language-tags;
  fixtures =
    pkgs.runCommand "jellyfin-language-tags-fixtures" { nativeBuildInputs = [ pkgs.ffmpeg-headless ]; }
      ''
        mkdir "$out"
        for language in eng rus; do
          ffmpeg -v error \
            -f lavfi -i color=c=blue:s=64x64:r=1 \
            -f lavfi -i sine=frequency=440:sample_rate=8000 \
            -t 2 -c:v mpeg4 -c:a pcm_s16le -metadata:s:a:0 language="$language" \
            "$out/$language.mkv"
        done
      '';
in
pkgs.testers.runNixOSTest {
  name = "jellyfin-language-tags";

  nodes.machine = {
    services.jellyfin.enable = true;
    systemd.services.jellyfin.preStart = ''
      install -Dm644 ${plugin}/Jellyfin.Plugin.LanguageTags.dll \
        /var/lib/jellyfin/plugins/LanguageTags/Jellyfin.Plugin.LanguageTags.dll
    '';
    systemd.tmpfiles.rules = [ "d /srv/movies 0755 jellyfin jellyfin -" ];
    environment.systemPackages = [ pkgs.curl ];
    virtualisation = {
      cores = 2;
      memorySize = 2048;
      diskSize = 4096;
    };
  };

  testScript = ''
    FIXTURES = "${fixtures}"
    PLUGIN_ID = "${plugin.pluginId}"
    PLUGIN_VERSION = "${plugin.version}"
  ''
  + builtins.readFile ./lib/jellyfin.py
  + builtins.readFile ./jellyfin-language-tags/test.py;
}
