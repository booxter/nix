{ lib }:
let
  inventoryLib = {
    requireSerializable =
      boundary: value:
      assert lib.assertMsg (builtins.isAttrs value) "${boundary} must return an attribute set";
      let
        json = builtins.addErrorContext "while checking ${boundary} for JSON serialization\n" (
          builtins.toJSON value
        );
      in
      builtins.seq json value;

    finalize =
      {
        name,
        facts,
        enrich ? (value: value),
        assertions ? (_: [ ]),
      }:
      let
        checkedFacts = inventoryLib.requireSerializable "inventory fact library ${name} facts" facts;
        enriched = enrich checkedFacts;
        asserted = lib.foldl' (
          result: check:
          assert lib.assertMsg check.assertion check.message;
          result
        ) enriched (assertions enriched);
      in
      inventoryLib.requireSerializable "inventory fact library ${name} result" asserted;

    evalModule = name: value: inventoryLib.requireSerializable "inventory module ${name} result" value;

    discoverFactLibraries =
      directory:
      lib.mapAttrs (name: _: directory + "/${name}") (
        lib.filterAttrs (
          name: type: type == "directory" && builtins.pathExists (directory + "/${name}/facts.nix")
        ) (builtins.readDir directory)
      );

    loadModules =
      {
        commonArgs,
        directory,
      }:
      let
        factLibraries = inventoryLib.discoverFactLibraries directory;
        inventory = lib.mapAttrs (
          name: path:
          let
            module = import path;
            availableArgs = commonArgs // {
              factLibraryName = name;
              inherit inventory inventoryLib;
            };
            moduleArgs = builtins.intersectAttrs (builtins.functionArgs module) availableArgs;
          in
          inventoryLib.evalModule name (module moduleArgs)
        ) factLibraries;
      in
      inventoryLib.publish directory inventory;

    publish =
      directory: value:
      let
        factLibraryNames = builtins.attrNames (inventoryLib.discoverFactLibraries directory);
        publishedNames = builtins.attrNames value;
      in
      assert lib.assertMsg (publishedNames == factLibraryNames) ''
        published inventory attributes must exactly match fact-library directories
        expected: ${lib.concatStringsSep ", " factLibraryNames}
        actual: ${lib.concatStringsSep ", " publishedNames}
      '';
      inventoryLib.requireSerializable "published inventory" value;
  };
in
inventoryLib
