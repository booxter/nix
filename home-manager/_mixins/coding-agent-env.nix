{
  config,
  lib,
  isDarwin,
}:

lib.optionalAttrs isDarwin {
  inherit (config.home.sessionVariables) SSH_ASKPASS;
  SSH_ASKPASS_REQUIRE = "force";
}
