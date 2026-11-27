{
  lib,
  buildPlugin,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-letterboxd";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "zamhedonia";
    repo = "JellyfinLetterboxdLink";
    tag = "V1.0.0";
    hash = "sha256-aSgeFMigP0cdhdCs0fGbK7p7OFtkFA8uqwiMB53Wml0=";
  };

  projectFile = "Jellyfin.Plugin.Letterboxd.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_8_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;

  pluginId = "d20f95e1-8b89-7c2b-9e73-43e9f3d29f10";
  pluginName = "Letterboxd Link on Movies";
  targetAbi = "10.8.0.0";
  pluginFiles = [ "Jellyfin.Plugin.Letterboxd.dll" ];

  meta = {
    description = "Add Letterboxd links to Jellyfin movies";
    homepage = "https://github.com/zamhedonia/JellyfinLetterboxdLink";
    license = lib.licenses.unfree;
  };
}
