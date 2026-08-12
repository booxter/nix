{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  userEnvironment = osConfig.host.userEnvironment;
  devCfg = userEnvironment.features.dev;
  scmCfg = devCfg.scm;
  smtpTransport = userEnvironment.smtpTransports.${scmCfg.sendEmail.transport};
  scmPkgs = import ./pkgs { inherit pkgs; };
in
lib.mkIf (devCfg.enable && scmCfg.enable && scmCfg.sendEmail.enable) {
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
