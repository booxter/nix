{ lib, ... }:
let
  botType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        username = lib.mkOption {
          type = lib.types.strMatching "bot-[a-zA-Z0-9_.-]+";
          default = "bot-${name}";
          description = "Vikunja username for this bot.";
        };
        displayName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Display name for this bot.";
        };
        projects = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.enum [
              "read"
              "read-write"
              "admin"
            ]
          );
          default = { };
          description = "Direct project grants keyed by exact, unique project title.";
        };
        token = {
          title = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = name;
            description = "Title of the bot's managed API token.";
          };
          permissions = lib.mkOption {
            type = with lib.types; attrsOf (listOf nonEmptyStr);
            description = "API token scopes, including mcp.access.";
          };
          expiresAt = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Token expiry as an ISO 8601 timestamp with a timezone.";
          };
        };
      };
    }
  );
in
{
  options.bots = lib.mkOption {
    type = lib.types.attrsOf botType;
    default = { };
    description = "Bot declarations applied explicitly with the vikunja-provision app.";
  };
}
