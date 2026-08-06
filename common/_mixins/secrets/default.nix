{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkMerge [
    {
      sops.age.keyFile = "/var/lib/sops-nix/key.txt";
      sops.defaultSopsFile = lib.mkDefault (
        ../../../secrets + "/${config.host.secretDomain}/${config.networking.hostName}.yaml"
      );
    }
    (lib.mkIf config.host.isSecretsOperator {
      programs.yubi.age.enable = config.host.hasYubiAgeIdentity;

      environment.systemPackages =
        with pkgs;
        [
          age
          sops
          sops-tools
        ]
        ++ lib.optional config.host.hasTouchId age-plugin-se;
    })
  ];
}
