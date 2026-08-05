{ pkgs }:
{
  check-commit-message = pkgs.callPackage ./check-commit-message { };

  git-send-email-store-password = pkgs.callPackage ./git-send-email-store-password { };

  glab-mr-create = pkgs.callPackage ./glab-mr-create { };
}
