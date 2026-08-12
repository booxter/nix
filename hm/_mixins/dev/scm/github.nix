{
  facts,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  scmCfg = devCfg.scm;
in
lib.mkIf (devCfg.enable && scmCfg.enable) {
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

  home.file = {
    ".ssh/config.d/github.com".text = ''
      Host github.com
        Hostname github.com
        HostKeyAlias github.com
        UserKnownHostsFile ~/.ssh/known_hosts.d/github.com
        User git
    '';

    ".ssh/known_hosts.d/github.com".text =
      lib.concatStringsSep "\n" [
        facts.public-keys.hosts."github.com.ed25519"
        facts.public-keys.hosts."github.com.rsa"
        facts.public-keys.hosts."github.com.ecdsa"
      ]
      + "\n";
  };

  home.packages = [ pkgs.gh ];
}
