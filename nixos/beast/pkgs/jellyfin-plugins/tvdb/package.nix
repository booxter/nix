{
  lib,
  buildPlugin,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-tvdb";
  version = "22";

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin-plugin-tvdb";
    tag = "v22";
    hash = "sha256-3cTzCKKgvnwwdaCJv70qAl5j73hixM4cCKVr1KOLh5A=";
  };

  projectFile = "Jellyfin.Plugin.Tvdb/Jellyfin.Plugin.Tvdb.csproj";
  nugetDeps = ./deps.json;

  pluginId = "a677c0da-fac5-4cde-941a-7134223f14c8";
  pluginName = "TheTVDB";
  targetAbi = "10.11.8.0";
  pluginFiles = [
    "Jellyfin.Plugin.Tvdb.dll"
    "Tvdb.Sdk.dll"
  ];

  meta = {
    description = "Get Jellyfin TV metadata from TheTVDB";
    homepage = "https://github.com/jellyfin/jellyfin-plugin-tvdb";
    license = lib.licenses.gpl3Only;
  };
}
