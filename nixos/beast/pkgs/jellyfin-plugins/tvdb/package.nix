{
  lib,
  buildPlugin,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-tvdb";
  version = "24";

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin-plugin-tvdb";
    tag = "v24";
    hash = "sha256-/n+f/6ZuNwHquWGwVqwLYi7TIhg1dBUhKUwcN90Btcg=";
  };

  projectFile = "Jellyfin.Plugin.Tvdb/Jellyfin.Plugin.Tvdb.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;

  pluginId = "a677c0da-fac5-4cde-941a-7134223f14c8";
  pluginName = "TheTVDB";
  targetAbi = "12.0.0.0";
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
