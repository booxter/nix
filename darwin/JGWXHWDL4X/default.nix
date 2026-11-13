{
  config,
  fleetInventory,
  lib,
  pkgs,
  sshKeys,
  ...
}:
let
  username = config.host.username;
  maasServer = name: {
    instructions = ''
      Only use the NVInfo MaaS MCP when the user explicitly requests NVIDIA
      internal information or interaction with NVIDIA internal services.
    '';
    url.secret = "codex/mcp/${name}/url";
    startupTimeoutSec = 60;
    oauth =
      lib.optionalAttrs
        (lib.elem name [
          "maas_nvbugs"
          "maas_outlook"
          "maas_teams"
        ])
        {
          clientIds = {
            codex.secret = "codex/mcp/maas/oauth/client_id";
            claude.secret = "claude/mcp/maas/oauth/client_id";
          };
        };
  };
in
{
  system.stateVersion = 5;

  host.realm = "work";

  host.hardware.isLaptop = true;
  host.network.homeCacheDns.enable = true;
  host.network.interfaces = {
    en0.kind = "wireless";
    en7 = { };
  };
  host.nix.builderClient = { };
  host.security.secrets.operator.ageIdentity = {
    backend = "yubikey";
    # These are public device handles; the private keys remain on the YubiKeys.
    path = toString (
      pkgs.writeText "work-yubikey-identities" (
        lib.concatMapStrings builtins.readFile [
          fleetInventory.yubikeys.work.main.ageIdentity
          fleetInventory.yubikeys.work.laptop.ageIdentity
        ]
      )
    );
  };
  sops.secrets.jiratuiGitRepositories = {
    key = "jiratui/gitRepositories";
    owner = username;
    group = "staff";
    mode = "0400";
  };
  host.ssh = {
    credentials = {
      backend = "yubikey";
      yubikey.identityFiles = [
        "id_ed25519_sk_work_main"
        "id_ed25519_sk_work_laptop"
      ];
    };
    operator.authorizedKeys = sshKeys.operators.JGWXHWDL4X;
  };
  home-manager.users.${username}.host.hm = {
    dev.agents.mcp.httpServers = {
      maas_artifactory = maasServer "maas_artifactory";
      maas_confluence = maasServer "maas_confluence";
      maas_gitlab = maasServer "maas_gitlab";
      maas_glean = maasServer "maas_glean";
      maas_jira = maasServer "maas_jira";
      maas_nvbugs = maasServer "maas_nvbugs";
      maas_outlook = maasServer "maas_outlook";
      maas_ovnk = maasServer "maas_ovnk";
      maas_redmine = maasServer "maas_redmine";
      maas_teams = maasServer "maas_teams";
    };
  };
}
