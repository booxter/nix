{
  config,
  isDarwin,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkMerge [
    {
      sops.age.keyFile = "/var/lib/sops-nix/key.txt";
      sops.defaultSopsFile =
        ../../../secrets + "/${config.host.realm}/${config.networking.hostName}.yaml";
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
        ++ lib.optional (isDarwin && config.host.hardware.hasTouchId) age-plugin-se;
    })
  ];
}
