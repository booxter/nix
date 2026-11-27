{
  lib,
  buildPlugin,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-porndb";
  version = "1.6.0.11";
  localRevision = 2;

  src = fetchFromGitHub {
    owner = "ThePornDatabase";
    repo = "Jellyfin.Plugin.ThePornDB";
    # No tagged Jellyfin 12 release yet; return to tags with the next release.
    rev = "125b1b30383d183b434f9b86375f1297cd0e4181";
    hash = "sha256-50emK7oohNQ9gu7oQqjSsMj0pkctQLX1GpuJqzL0nrs=";
  };

  projectFile = "Jellyfin.Plugin.ThePornDB/ThePornDB.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;
  # Upstream enables its dependency-merging build task only in Release.
  dotnetRestoreFlags = [ "-p:Configuration=Release" ];
  # Publish copies the intermediate assembly instead of the merged build output.
  postInstall = ''
    install -m644 Jellyfin.Plugin.ThePornDB/bin/Release/net10.0/*/ThePornDB.dll "$out/ThePornDB.dll"
  '';

  pluginId = "fb7580cf-576d-4991-8e56-0b4520c111d3";
  pluginName = "ThePornDB";
  targetAbi = "12.0.0.0";
  pluginFiles = [ "ThePornDB.dll" ];

  meta = {
    description = "ThePornDB metadata provider for Jellyfin";
    homepage = "https://github.com/ThePornDatabase/Jellyfin.Plugin.ThePornDB";
    license = lib.licenses.mit;
  };
}
