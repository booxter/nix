{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.awscli.enable = true;

  home.sessionVariables = {
    AWS_PROFILE = "saml";
    AWS_DEFAULT_REGION = "us-east-2";
    AWS_DEFAULT_OUTPUT = "table";
  };

  home.packages = with pkgs; [
    aws-automation
  ];
}
