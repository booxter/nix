{
  config,
  lib,
  osConfig,
  ...
}:
let
  shared = import ../shared.nix { inherit lib osConfig; };
in
{
  programs.claude-code =
    lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.claude.enable)
      {
        enable = true;
        context = shared.context;
        skills = shared.skills;

        settings = {
          env = {
            DISABLE_AUTOUPDATER = "1";
            inherit (config.home.sessionVariables) SSH_ASKPASS;
            SSH_ASKPASS_REQUIRE = "force";
          };
          pluginConfigs."cc-plugin-agents-md@builtin".options.instructionFiles = "claude-md-and-agents-md";
        };
      };
}
