{ lib, osConfig, ... }:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  pushDisabledGitHubRepos = [
    "NixOS/nixpkgs"
    "ovn-kubernetes/ovn-kubernetes"
  ];
in
lib.mkIf (devCfg.enable && devCfg.scm.enable) {
  programs.git.settings.url = builtins.listToAttrs (
    map (repo: {
      name = "file:///dev/null/git-push-disabled/${repo}";
      value.pushInsteadOf = [
        "git@github.com:${repo}.git"
        "https://github.com/${repo}.git"
      ];
    }) pushDisabledGitHubRepos
  );
}
