{ pkgs }:
let
  packageUpdateTools = import ./package.nix { inherit pkgs; };

  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  testSource = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = ./.;
  };
  mkBatsCheck =
    {
      nativeCheckInputs ? [ ],
      shellScripts,
      tests,
    }:
    {
      derivationArgs = {
        doCheck = true;
        inherit nativeCheckInputs;
      };
      checkPhase = ''
        runHook preCheck
        cd ${testSource}
        ${pkgs.lib.getExe pkgs.bash} -n "$target" ${pkgs.lib.escapeShellArgs shellScripts}
        ${pkgs.lib.getExe pkgs.shellcheck} "$target" ${pkgs.lib.escapeShellArgs shellScripts}
        ${pkgs.lib.getExe pkgs.bats} --print-output-on-failure ${pkgs.lib.escapeShellArgs tests}
        runHook postCheck
      '';
    };

  updatePackages = pkgs.writeShellApplication {
    name = "update-packages";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnused
      jq
      nix
      nix-update
      prefetch-npm-deps
      (python3.withPackages (pythonPackages: [ pythonPackages.semantic-version ]))
    ];
    text = ''
      export UPDATE_SUMMARY_LIB="''${UPDATE_SUMMARY_LIB:-${./update-summary-lib.sh}}"
      export PACKAGE_UPDATE_TARGETS_FILE="''${PACKAGE_UPDATE_TARGETS_FILE:-${./targets.json}}"
      exec ${pkgs.bash}/bin/bash ${./update-packages.sh} "$@"
    '';
    inherit
      (mkBatsCheck {
        shellScripts = [
          "apps/package-updates/update-packages.sh"
          "apps/package-updates/update-summary-lib.sh"
        ];
        tests = [
          "apps/package-updates/update-packages.bats"
          "apps/package-updates/select-nodejs.bats"
        ];
        nativeCheckInputs = with pkgs; [
          git
          jq
          (python3.withPackages (pythonPackages: [ pythonPackages.semantic-version ]))
        ];
      })
      checkPhase
      derivationArgs
      ;
  };

  updateOciImages = pkgs.writeShellApplication {
    name = "update-oci-images";
    runtimeInputs = with pkgs; [
      coreutils
      cosign
      git
      gnugrep
      jq
      nix-prefetch-docker
      skopeo
    ];
    text = ''
      export UPDATE_SUMMARY_LIB="''${UPDATE_SUMMARY_LIB:-${./update-summary-lib.sh}}"
      exec ${pkgs.bash}/bin/bash ${./update-oci-images.sh} "$@"
    '';
    inherit
      (mkBatsCheck {
        shellScripts = [
          "apps/package-updates/update-oci-images.sh"
          "apps/package-updates/update-summary-lib.sh"
        ];
        tests = [ "apps/package-updates/update-oci-images.bats" ];
        nativeCheckInputs = with pkgs; [
          git
          jq
        ];
      })
      checkPhase
      derivationArgs
      ;
  };
in
{
  packages = {
    package-update-tools = packageUpdateTools;
    update-packages = updatePackages;
    update-oci-images = updateOciImages;
  };
  apps = {
    update-packages = mkApp "${updatePackages}/bin/update-packages" "Update selected fetched packages and write a changelog-linked PR summary.";
    update-oci-images = mkApp "${updateOciImages}/bin/update-oci-images" "Update selected OCI image tags and write a changelog-linked PR summary.";
  };
}
