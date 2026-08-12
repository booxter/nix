{ pkgs, ... }:
let
  inherit (pkgs) lib;
  targetOutputs.nixosConfigurations = {
    media.config.host = {
      realm = "test-realm";
      jellyfin = {
        enable = true;
        publicUrl = "https://media.example.invalid";
      };
    };
    games.config.host = {
      realm = "test-realm";
      romm = {
        enable = true;
        publicUrl = "https://games.example.invalid";
      };
    };
  };
  testSupport = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
      };
      networking.hostName = lib.mkOption { type = lib.types.nonEmptyStr; };
      host.realm = lib.mkOption { type = lib.types.nonEmptyStr; };
      host.web.services.goo.public.url = lib.mkOption { type = lib.types.str; };
      host.sso = {
        applications = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        users = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };
  };
  defaults = lib.evalModules {
    modules = [
      ../../nixos/_mixins/degoog/options.nix
      testSupport
      {
        networking.hostName = "search";
        host.realm = "test-realm";
        host.web.services.goo.public.url = "https://search.example.invalid";
      }
    ];
  };
  configuredModules = [
    ../../nixos/_mixins/degoog/assertions.nix
    ../../nixos/_mixins/degoog/options.nix
    testSupport
    {
      networking.hostName = "search";
      host = {
        realm = "test-realm";
        web.services.goo.public.url = "https://search.example.invalid";
        sso = {
          applications.degoog = {
            adminGroup = "search-admins";
            userGroup = "search-users";
          };
          users = {
            admin-user.groups = [
              "search-admins"
              "search-users"
            ];
            regular-user.groups = [ "search-users" ];
          };
        };
        degoog = {
          enable = true;
          catalog = {
            engines.web.extension = "engines/upstream-web";
            features = {
              history.extension = "plugins/upstream-history";
              jellyfin.extension = "plugins/jellyfin";
              romm.extension = "plugins/romm";
              settings-access.extension = "plugins/settings-access";
            };
          };
          engines = [ "web" ];
          features = [ "history" ];
          integrations = {
            jellyfin.host = "media";
            romm.host = "games";
          };
        };
      };
    }
  ];
  evaluated = lib.evalModules {
    specialArgs.outputs = targetOutputs;
    modules = configuredModules;
  };
  unknownSelection = lib.evalModules {
    specialArgs.outputs = targetOutputs;
    modules = configuredModules ++ [
      {
        networking.hostName = "search";
        host.degoog.engines = lib.mkForce [ "missing" ];
      }
    ];
  };
  model = import ../../nixos/_mixins/degoog/model.nix {
    config = evaluated.config;
    inherit lib;
    outputs = targetOutputs;
  };
  failedAssertions = builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions;
  unknownFailures = builtins.filter (
    assertion: !assertion.assertion
  ) unknownSelection.config.assertions;
in
assert defaults.config.host.degoog.engines == [ ];
assert defaults.config.host.degoog.features == [ ];
assert defaults.config.host.degoog.theme == null;
assert builtins.attrNames model.adminUsers == [ "admin-user" ];
assert model.jellyfin.publicUrl == "https://media.example.invalid";
assert model.romm.publicUrl == "https://games.example.invalid";
assert
  model.extensionNames == [
    "engines/upstream-web"
    "plugins/settings-access"
    "plugins/upstream-history"
    "plugins/jellyfin"
    "plugins/romm"
  ];
assert model.unknownEngines == [ ];
assert model.unknownFeatures == [ ];
assert failedAssertions == [ ];
assert
  map (assertion: assertion.message) unknownFailures == [
    "Degoog selects unknown engines: missing"
  ];
pkgs.runCommand "degoog-model-test" { } ''
  touch "$out"
''
