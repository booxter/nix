{
  lib,
  buildPlugin,
  dotnetCorePackages,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-meilisearch";
  version = "1.12.1.7";

  src = fetchFromGitHub {
    owner = "arnesacnussem";
    repo = "jellyfin-plugin-meilisearch";
    tag = "1.12.1.7";
    hash = "sha256-wOuRH1p3OXJkmbkYpo9OiHpj4oWaMY/SqP9tkWQkFQY=";
  };

  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;
  projectFile = "src/Jellyfin.Plugin.Meilisearch.csproj";
  nugetDeps = ./deps.json;

  pluginId = "974395db-b31d-46a2-bc86-ef9aa5ac04dd";
  pluginName = "Meilisearch";
  targetAbi = "12.0.0.0";
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
