{
  config,
  lib,
  pkgs,
  ...
}:
let
  directory = "/var/run/darwin-vm-ci";
  keyFile = "${directory}/age-key";
  secretsFile = "${directory}/secrets.yaml";
  fixtures = (pkgs.formats.yaml { }).generate "ci-secrets.yaml" (
    lib.foldl' lib.recursiveUpdate { } (
      map (secret: lib.setAttrByPath (lib.splitString "/" secret.key) "ci-placeholder") (
        builtins.attrValues config.sops.secrets
      )
    )
  );
in
{
  virtualisation.forwardedSockets = lib.mkForce { };

  # The guest cannot use the fleet's builders or sign paths for its caches.
  host.nix.builderClient = lib.mkForce null;

  sops = {
    defaultSopsFile = lib.mkForce secretsFile;
    validateSopsFiles = false;
    age.keyFile = lib.mkForce keyFile;
    age.sshKeyPaths = lib.mkForce [ ];
  };

  # Materialize dummy values with the normal sops-nix installer and templates.
  system.activationScripts.preActivation.text = ''
    (
      umask 077
      mkdir -p ${directory}
      if [ ! -f ${keyFile} ]; then
        ${pkgs.age}/bin/age-keygen -o ${keyFile}
      fi

      recipient="$(${pkgs.age}/bin/age-keygen -y ${keyFile})"
      ${lib.getExe pkgs.sops} --config /dev/null encrypt --age "$recipient" \
        --output ${secretsFile} ${fixtures}
    )
  '';
}
