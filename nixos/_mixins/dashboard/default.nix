{ lib, ... }:
{
  options.host.dashboard.entries = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, name, ... }:
        {
          options = {
            title = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = lib.strings.toSentenceCase name;
              description = "Human-readable dashboard entry title.";
            };

            icon = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "sh:${name}";
              description = "Dashboard icon identifier or URL.";
            };

            section = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Dashboard section containing this entry.";
            };

            url = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "URL opened from the dashboard.";
            };

            checkUrl = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = config.url;
              description = "URL used to check entry availability.";
            };
          };
        }
      )
    );
    default = { };
    description = "Internal non-web resources contributed to the fleet dashboard catalog.";
  };
}
