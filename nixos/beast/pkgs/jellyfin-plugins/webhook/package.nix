{
  lib,
  buildPlugin,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildPlugin {
  pname = "jellyfin-plugin-webhook";
  version = "22";

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin-plugin-webhook";
    tag = "v22";
    hash = "sha256-FpRfqEJVDLRh+lklC5lMk5bTEGAREU38zfEbWC2oOZA=";
  };

  projectFile = "Jellyfin.Plugin.Webhook/Jellyfin.Plugin.Webhook.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;

  pluginId = "71552a5a-5c5c-4350-a2ae-ebe451a30173";
  pluginName = "Webhook";
  targetAbi = "12.0.0.0";
  pluginFiles = [
    "Jellyfin.Plugin.Webhook.dll"
    "Handlebars.dll"
    "MailKit.dll"
    "MimeKit.dll"
    "BouncyCastle.Cryptography.dll"
    "MQTTnet.dll"
    "MQTTnet.Extensions.ManagedClient.dll"
  ];

  meta = {
    description = "Send Jellyfin notifications through webhooks";
    homepage = "https://github.com/jellyfin/jellyfin-plugin-webhook";
    license = lib.licenses.gpl3Only;
  };
}
