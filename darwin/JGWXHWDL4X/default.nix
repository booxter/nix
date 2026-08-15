{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
  maasServer = name: {
    url.secret = "codex/mcp/${name}/url";
    oauth = lib.optionalAttrs (name == "maas_nvbugs") {
      clientId.secret = "codex/mcp/${name}/oauth/client_id";
    };
  };
in
{
  system.stateVersion = 5;

  host.realm = "work";

  host.hardware.isLaptop = true;
  host.network.interfaces = {
    en0.kind = "wireless";
    en7 = { };
  };
  host.nix.builderClient = { };
  host.security.secrets.operator.ageIdentity = {
    backend = "secure-enclave";
    path = "/Users/${username}/Library/Application Support/sops/age/work.txt";
  };
  host.ssh.operator.authorizedKeys = [
    (readPublicKey ../../common/_mixins/ssh/public-keys/jgwxhwdl4x.pub)
    (readPublicKey ../../common/_mixins/ssh/public-keys/jgwxhwdl4x-nix-builder.pub)
  ];
  host.nix.cacheWarmer = { };

  home-manager.users.${username}.host.hm = {
    dev.codex.mcp.httpServers = {
      maas_gitlab = maasServer "maas_gitlab";
      maas_jira = maasServer "maas_jira";
      maas_nvbugs = maasServer "maas_nvbugs";
      maas_redmine = maasServer "maas_redmine";
    };
  };
}
