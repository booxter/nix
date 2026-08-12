{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  readPublicKey = import ../../../../common/_lib/read-public-key.nix { inherit lib; };
  devCfg = osConfig.host.userEnvironment.features.dev;
  scmCfg = devCfg.scm;
in
lib.mkIf (devCfg.enable && scmCfg.enable) {
  host.hm.ssh.knownHosts."github.com" = {
    hostNames = [ "github.com" ];
    publicKeys = [
      (readPublicKey ./github/known-hosts/ed25519.pub)
      (readPublicKey ./github/known-hosts/rsa.pub)
      (readPublicKey ./github/known-hosts/ecdsa.pub)
    ];
  };

  programs.git.settings = {
    url."git@github.com:".pushInsteadOf = "https://github.com/";

    # Preserve the credential helper that programs.gh normally configures.
    credential = {
      "https://github.com".helper = [
        ""
        "${pkgs.gh}/bin/gh auth git-credential"
      ];
      "https://gist.github.com".helper = [
        ""
        "${pkgs.gh}/bin/gh auth git-credential"
      ];
    };
  };

  # Let gh own its mutable config while retaining the declarative extensions.
  xdg.dataFile."gh/extensions".source = pkgs.linkFarm "gh-extensions" (
    map
      (extension: {
        name = extension.pname;
        path = "${extension}/bin";
      })
      [
        pkgs.gh-dash
        pkgs.gh-poi
      ]
  );

  # Run after Home Manager removes the programs.gh config.yml symlink. This
  # creates a writable config on the first activation and enforces the protocol
  # preference without taking ownership of the file afterward.
  home.activation.configureGh = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    verboseEcho "Configuring GitHub CLI to use SSH"
    run ${lib.getExe pkgs.gh} config set git_protocol ssh
  '';

  programs.gh-dash = {
    enable = true;
    settings.repoPaths.":owner/:repo" = "~/src/:repo";
  };

  programs.ssh.settings."github.com" = {
    HostName = "github.com";
    User = "git";
  };

  home.packages = [ pkgs.gh ];
}
