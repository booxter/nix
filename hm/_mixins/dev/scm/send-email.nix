{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  env = config.host.hm.env;
  smtpTransport = env.smtpTransports.${env.sendEmail.transport};
  scmPkgs = import ./pkgs { inherit pkgs; };
in
lib.mkIf (config.host.hm.env.preset != null) {
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
