{
  lib,
  buildPlugin,
  fetchFromGitHub,
  fetchpatch,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-polyglot";
  # The release manifest corrects the stale 0.9.5.0 in this tag's build.yaml.
  version = "0.9.6";
  localRevision = 2;

  src = fetchFromGitHub {
    owner = "Maronato";
    repo = "jellyfin-plugin-polyglot";
    tag = "v0.9.6";
    hash = "sha256-tx6Yog2PvbHnuG9C7iXzedviPvFB2Qm579rq8J+OLpc=";
  };

  patches = [
    # Nix supplies release metadata; take only the fork's production code changes.
    (fetchpatch {
      url = "https://github.com/TheJanusz/jellyfin-plugin-polyglot/commit/57266b1fc05f0df4d51c107554bc016adc35e950.patch";
      includes = [
        "Jellyfin.Plugin.Polyglot/Helpers/PolyglotUserManager.cs"
        "Jellyfin.Plugin.Polyglot/Jellyfin.Plugin.Polyglot.csproj"
      ];
      hash = "sha256-OrqtV1LqS3F3HQzBQVEBr+OYwIoxpZDfvFgaLeXZpGo=";
    })
  ];

  projectFile = "Jellyfin.Plugin.Polyglot/Jellyfin.Plugin.Polyglot.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;

  pluginId = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
  pluginName = "Polyglot";
  targetAbi = "12.0.0.0";
  pluginFiles = [ "Jellyfin.Plugin.Polyglot.dll" ];

  meta = {
    description = "Multi-language Jellyfin metadata through hardlinked libraries";
    homepage = "https://github.com/Maronato/jellyfin-plugin-polyglot";
    license = lib.licenses.gpl3Only;
  };
}
