{
  lib,
  buildPlugin,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-lrclib";
  version = "5";

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin-plugin-lrclib";
    tag = "v5";
    hash = "sha256-HPlilULz96s/LeIyh9TE9oHqXIejBTNO2uxXWNkFJZk=";
  };

  projectFile = "Jellyfin.Plugin.LrcLib/Jellyfin.Plugin.LrcLib.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;

  pluginId = "d106ebe6-9ca8-4fbc-9cd1-a92a213da9f9";
  pluginName = "LrcLib Lyrics";
  targetAbi = "12.0.0.0";
  pluginFiles = [ "Jellyfin.Plugin.LrcLib.dll" ];

  meta = {
    description = "Download Jellyfin music lyrics from LrcLib";
    homepage = "https://github.com/jellyfin/jellyfin-plugin-lrclib";
    license = lib.licenses.gpl3Only;
  };
}
