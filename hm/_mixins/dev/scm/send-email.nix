{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  userEnvironment = config.host.hm.userEnvironment;
  smtpTransport = userEnvironment.smtpTransports.${userEnvironment.sendEmail.transport};
  scmPkgs = import ./pkgs { inherit pkgs; };
in
lib.mkIf osConfig.host.userEnvironment.roles.developer.enable {
  programs.git.settings.sendemail = {
    confirm = "auto";
    smtpServer = smtpTransport.server;
    smtpServerPort = smtpTransport.port;
    smtpUser = smtpTransport.username;
  }
  // lib.optionalAttrs (smtpTransport.encryption != "none") {
    smtpEncryption = smtpTransport.encryption;
  };

  home.packages = lib.optionals (isDarwin && smtpTransport.credentialStore == "macos-keychain") [
    scmPkgs.git-send-email-store-password
  ];
}
