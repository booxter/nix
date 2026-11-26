{
  lib,
  buildPlugin,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-lrclib";
  version = "3";

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin-plugin-lrclib";
    tag = "v3";
    hash = "sha256-GDoNTH20s1OQY2IoxSrstKhkHX+4BWAfHFreu2bWKPA=";
  };

  projectFile = "Jellyfin.Plugin.LrcLib/Jellyfin.Plugin.LrcLib.csproj";
  nugetDeps = ./deps.json;

  pluginId = "d106ebe6-9ca8-4fbc-9cd1-a92a213da9f9";
  pluginName = "LrcLib Lyrics";
  targetAbi = "10.11.0.0";
  pluginFiles = [ "Jellyfin.Plugin.LrcLib.dll" ];

  meta = {
    description = "Download Jellyfin music lyrics from LrcLib";
    homepage = "https://github.com/jellyfin/jellyfin-plugin-lrclib";
    license = lib.licenses.gpl3Only;
  };
}
