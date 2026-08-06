{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.host.isSecretsOperator {
    programs.yubi.age.enable = config.host.hasYubiAgeIdentity;

    environment.systemPackages =
      with pkgs;
      [
        age
        sops
        sops-tools
      ]
      ++ lib.optional (config.host.isDarwin && config.host.isLaptop) age-plugin-se;
  };
}
