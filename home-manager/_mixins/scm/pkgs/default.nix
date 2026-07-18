{ pkgs }:
{
  check-commit-message = pkgs.callPackage ./check-commit-message.nix { };

  git-send-email-store-password = pkgs.writeShellApplication {
    name = "git-send-email-store-password";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = builtins.readFile ./git-send-email-store-password.sh;

    meta = {
      description = "Store the configured Git SMTP password in macOS Keychain";
      license = pkgs.lib.licenses.mit;
      maintainers = with pkgs.lib.maintainers; [ booxter ];
      mainProgram = "git-send-email-store-password";
      platforms = pkgs.lib.platforms.darwin;
    };
  };

  glab-mr-create = pkgs.writeShellApplication {
    name = "glab-mr-create";
    runtimeInputs = [ pkgs.glab ];
    text = ''
      exec glab mr create --fill --remove-source-branch --push "$@"
    '';

    meta = {
      description = "Create a filled GitLab merge request and push its source branch";
      license = pkgs.lib.licenses.mit;
      maintainers = with pkgs.lib.maintainers; [ booxter ];
      mainProgram = "glab-mr-create";
    };
  };
}
