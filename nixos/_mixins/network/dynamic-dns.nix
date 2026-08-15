{ config, lib, ... }:
let
  ingress = config.host.web.ingress;
  wireguard = config.host.wireguard.server;
  policies = lib.unique (
    builtins.filter (policy: policy != null) [
      (if ingress == null then null else ingress.dynamicDns)
      (if wireguard == null then null else wireguard.dynamicDns)
    ]
  );
  policy = if builtins.length policies == 1 then builtins.head policies else null;
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.length policies <= 1;
          message = "Web ingress and WireGuard must not request conflicting dynamic DNS policies";
        }
      ];
    }
    (lib.mkIf (policy != null) {
      # Keep ddclient on a stable user: its generated preStart script may run
      # before dynamic runtime state is ready during switch-to-configuration.
      users.groups = {
        ddclient = { };
        ddclient-secrets = { };
      };
      users.users.ddclient = {
        isSystemUser = true;
        group = "ddclient";
      };

      sops = {
        useSystemdActivation = lib.mkDefault true;
        secrets.dynamicDnsPassword = {
          key = "ddns/dynu/password";
          group = "ddclient-secrets";
          mode = "0440";
        };
      };

      services.ddclient = {
        enable = true;
        interval = "3min";
        protocol = "dyndns2";
        server = "api.dynu.com";
        inherit (policy) username;
        passwordFile = config.sops.secrets.dynamicDnsPassword.path;
        domains = [ policy.hostname ];
        ssl = true;
        quiet = true;
        usev4 = "webv4,webv4=checkip.dynu.com/,webv4-skip='IP Address'";
        usev6 = "";
      };

      systemd.services.ddclient = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "ddclient";
          Group = "ddclient";
          SupplementaryGroups = [ "ddclient-secrets" ];
        };
      };
    })
  ];
}
