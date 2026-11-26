{
  lib,
  buildPlugin,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-language-tags";
  version = "0.5.3.0";

  src = fetchFromGitHub {
    owner = "TheXaman";
    repo = "jellyfin-plugin-languageTags";
    tag = "v0.5.3.0";
    hash = "sha256-gF/Vx4VOM0gP7kkBgU2cOmfyOklSNHX83DKb4oUYn38=";
  };

  projectFile = "Jellyfin.Plugin.LanguageTags/Jellyfin.Plugin.LanguageTags.csproj";
  nugetDeps = ./deps.json;

  pluginId = "e6ee25c2-d12c-4382-a48c-66ee9c1c33cb";
  pluginName = "Language Tags";
  targetAbi = "10.11.0.0";
  pluginFiles = [ "Jellyfin.Plugin.LanguageTags.dll" ];

  meta = {
    description = "Tag Jellyfin media with its audio and subtitle languages";
    homepage = "https://github.com/TheXaman/jellyfin-plugin-languageTags";
    license = lib.licenses.gpl3Only;
  };
}
