{
  lib,
  buildPlugin,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-meilisearch";
  version = "1.11.1.15";

  src = fetchFromGitHub {
    owner = "arnesacnussem";
    repo = "jellyfin-plugin-meilisearch";
    tag = "1.11.1.15";
    hash = "sha256-Sebgm8QnfsrtjApr8YnY9UCS6qML0FBX7J7NjNI9qFc=";
  };

  projectFile = "src/Jellyfin.Plugin.Meilisearch.csproj";
  nugetDeps = ./deps.json;

  pluginId = "974395db-b31d-46a2-bc86-ef9aa5ac04dd";
  pluginName = "Meilisearch";
  targetAbi = "10.11.7.0";
  pluginFiles = [
    "Jellyfin.Plugin.Meilisearch.dll"
    "Meilisearch.dll"
    "Microsoft.IdentityModel.Abstractions.dll"
    "Microsoft.IdentityModel.JsonWebTokens.dll"
    "Microsoft.IdentityModel.Logging.dll"
    "Microsoft.IdentityModel.Tokens.dll"
    "System.IdentityModel.Tokens.Jwt.dll"
  ];

  meta = {
    description = "Use Meilisearch for Jellyfin library searches";
    homepage = "https://github.com/arnesacnussem/jellyfin-plugin-meilisearch";
    license = lib.licenses.gpl3Only;
  };
}
