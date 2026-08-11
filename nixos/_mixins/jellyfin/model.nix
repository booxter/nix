{ config, outputs }:
let
  localHost = config.networking.hostName;
  configurations =
    map (configuration: configuration.config) (
      builtins.attrValues (removeAttrs outputs.nixosConfigurations [ localHost ])
    )
    ++ [ config ];
  contributions = builtins.concatLists (
    map (
      hostConfig:
      builtins.attrValues (
        builtins.mapAttrs (name: contribution: contribution // { inherit name; }) (
          hostConfig.host.jellyfin.declarativeConfigContributions
        )
      )
    ) configurations
  );
  targetedContributions = builtins.filter (
    contribution: contribution.targetHost == localHost
  ) contributions;
in
{
  inherit targetedContributions;
  contributionNames = map (contribution: contribution.name) targetedContributions;
}
