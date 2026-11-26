{
  lib,
  buildPlugin,
  fetchFromGitHub,
}:
buildPlugin {
  pname = "jellyfin-plugin-webhook";
  version = "21";

  src = fetchFromGitHub {
    owner = "jellyfin";
    repo = "jellyfin-plugin-webhook";
    tag = "v21";
    hash = "sha256-a51Ff9G5LP+obf0ELzV6VEXParwU3Jv9zbCF61cC3UY=";
  };

  projectFile = "Jellyfin.Plugin.Webhook/Jellyfin.Plugin.Webhook.csproj";
  nugetDeps = ./deps.json;

  pluginId = "71552a5a-5c5c-4350-a2ae-ebe451a30173";
  pluginName = "Webhook";
  targetAbi = "10.11.8.0";
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
