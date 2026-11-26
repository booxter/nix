{
  lib,
  buildPlugin,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-polyglot";
  # The release manifest corrects the stale 0.9.5.0 in this tag's build.yaml.
  version = "0.9.6";

  src = fetchFromGitHub {
    owner = "Maronato";
    repo = "jellyfin-plugin-polyglot";
    tag = "v0.9.6";
    hash = "sha256-tx6Yog2PvbHnuG9C7iXzedviPvFB2Qm579rq8J+OLpc=";
  };

  projectFile = "Jellyfin.Plugin.Polyglot/Jellyfin.Plugin.Polyglot.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_8_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;

  pluginId = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
  pluginName = "Polyglot";
  targetAbi = "10.10.0.0";
  pluginFiles = [ "Jellyfin.Plugin.Polyglot.dll" ];

  meta = {
    description = "Multi-language Jellyfin metadata through hardlinked libraries";
    homepage = "https://github.com/Maronato/jellyfin-plugin-polyglot";
    license = lib.licenses.gpl3Only;
  };
}
