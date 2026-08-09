{ lib }:
let
  factsLib = {
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
        raw,
        enrich ? (value: value),
        assertions ? (_: [ ]),
      }:
      let
        checkedFacts = factsLib.requireSerializable "facts module ${name} raw facts" raw;
        enriched = enrich checkedFacts;
        asserted = lib.foldl' (
          result: check:
          assert lib.assertMsg check.assertion check.message;
          result
        ) enriched (assertions enriched);
      in
      factsLib.requireSerializable "facts module ${name} result" asserted;

    callWith =
      availableArgs: value:
      if builtins.isFunction value then
        value (builtins.intersectAttrs (builtins.functionArgs value) availableArgs)
      else
        value;

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
        factLibraries = factsLib.discoverFactLibraries directory;
        facts = lib.mapAttrs (
          name: path:
          let
            availableArgs = commonArgs // {
              inherit facts;
            };
            call = factsLib.callWith availableArgs;
            raw = call (import (path + "/facts.nix"));
            enrich =
              if builtins.pathExists (path + "/enrich.nix") then
                call (import (path + "/enrich.nix"))
              else
                value: value;
            assertions =
              if builtins.pathExists (path + "/asserts.nix") then
                call (import (path + "/asserts.nix"))
              else
                _: [ ];
          in
          factsLib.finalize {
            inherit
              assertions
              enrich
              name
              raw
              ;
          }
        ) factLibraries;
      in
      factsLib.publish directory facts;

    publish =
      directory: value:
      let
        factLibraryNames = builtins.attrNames (factsLib.discoverFactLibraries directory);
        publishedNames = builtins.attrNames value;
      in
      assert lib.assertMsg (publishedNames == factLibraryNames) ''
        published facts attributes must exactly match fact-library directories
        expected: ${lib.concatStringsSep ", " factLibraryNames}
        actual: ${lib.concatStringsSep ", " publishedNames}
      '';
      factsLib.requireSerializable "published facts" value;
  };
in
factsLib
