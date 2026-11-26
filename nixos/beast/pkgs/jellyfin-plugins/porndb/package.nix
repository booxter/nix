{
  lib,
  buildPlugin,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-porndb";
  version = "1.6.0.11";

  src = fetchFromGitHub {
    owner = "ThePornDatabase";
    repo = "Jellyfin.Plugin.ThePornDB";
    tag = "1.6.0.11";
    hash = "sha256-PCsJK6jYn6tB8LaNzHJuqXdPxPhZjTDW4luBhfjr81A=";
  };

  projectFile = "Jellyfin.Plugin.ThePornDB/ThePornDB.csproj";
  nugetDeps = ./deps.json;
  # Upstream enables its dependency-merging build task only in Release.
  dotnetRestoreFlags = [ "-p:Configuration=Release" ];
  # Publish copies the intermediate assembly instead of the merged build output.
  postInstall = ''
    install -m644 Jellyfin.Plugin.ThePornDB/bin/Release/net9.0/*/ThePornDB.dll "$out/ThePornDB.dll"
  '';

  pluginId = "fb7580cf-576d-4991-8e56-0b4520c111d3";
  pluginName = "ThePornDB";
  targetAbi = "10.11.0.0";
  pluginFiles = [ "ThePornDB.dll" ];

  meta = {
    description = "ThePornDB metadata provider for Jellyfin";
    homepage = "https://github.com/ThePornDatabase/Jellyfin.Plugin.ThePornDB";
    license = lib.licenses.mit;
  };
}
