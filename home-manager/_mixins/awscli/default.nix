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

  # TODO: introduce a better check to disable it on remotes
  home.packages = with pkgs; lib.optionals stdenv.isDarwin [
    aws-automation
  ];
}
