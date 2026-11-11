{
  config,
  lib,
  pinepodsModel,
  pkgs,
  storageIdentities,
  ...
}:
let
  inherit (pinepodsModel)
    aiPort
    aiProvider
    cfg
    downloadsDir
    ollamaTunnelPort
    storageGroup
    user
    ;
  client = config.host.pki.clients.pinepods-ollama;
  serverName = aiProvider.host.web.services.ollama.internal.serverName;
  containerImage = import ../../_lib/oci-image.nix {
    image = import ./ai-image-pin.nix;
    inherit pkgs;
  };
in
{
  config = lib.mkIf (cfg != null) {
    assertions = [
      {
        assertion = aiProvider != null && aiProvider.host.realm == config.host.realm;
        message = "PinePods and its Ollama provider must be in the same realm.";
      }
      {
        assertion = aiProvider != null && aiProvider.host.ollama != null;
        message = "The PinePods AI provider must enable Ollama.";
      }
      {
        assertion =
          aiProvider != null && builtins.hasAttr cfg.adDetectionModel (aiProvider.host.ollama.models or { });
        message = "PinePods must select a model advertised by its Ollama provider.";
      }
    ];

    host.pki.clients.pinepods-ollama = {
      category = "internal";
      commonName = "pinepods.${config.networking.hostName}";
      materializations.default.restartUnits = [ "stunnel.service" ];
    };

    services.stunnel = {
      enable = true;
      logLevel = lib.mkDefault "warning";
      user = null;
      group = null;
      clients.pinepods-ollama = {
        accept = "127.0.0.1:${toString ollamaTunnelPort}";
        connect = "${serverName}:443";
        cert = client.materializations.default.certificatePath;
        key = client.materializations.default.keyPath;
        checkHost = serverName;
        sni = serverName;
        CAFile = "${config.host.pki.authority.rootCaCertificate}";
        verifyChain = true;
        OCSPaia = false;
      };
    };

    host.storage.claims.media.attachments.podman-pinepods-ai = { };
    systemd.tmpfiles.rules = [
      "d /var/lib/pinepods-ai 0750 ${user} ${storageGroup} - -"
    ];

    virtualisation.oci-containers.containers = {
      pinepods.environment.PINEPODS_AI_URL = "http://10.0.2.2:${toString aiPort}";
      pinepods-ai = {
        image = containerImage.ref;
        inherit (containerImage) imageFile;
        pull = "never";
        user = "${toString storageIdentities.users.${user}.uid}:${
          toString config.users.groups.${storageGroup}.gid
        }";
        environment = {
          WHISPER_MODEL = "base";
          WHISPER_DEVICE = "cpu";
          WHISPER_COMPUTE_TYPE = "int8";
        };
        # Both HTTP hops stay on this host; only the authenticated TLS tunnel
        # crosses the network to frame. slirp exposes host loopback as 10.0.2.2.
        ports = [ "127.0.0.1:${toString aiPort}:8100" ];
        networks = [ "slirp4netns:allow_host_loopback=true" ];
        volumes = [
          "${downloadsDir}:/opt/pinepods/downloads:ro"
          "/var/lib/pinepods-ai:/models:rw"
        ];
        extraOptions = [
          "--cap-drop=all"
          "--security-opt=no-new-privileges"
          "--no-healthcheck"
        ];
      };
    };

    systemd.services = {
      stunnel = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };
      podman-pinepods = {
        wants = [ "podman-pinepods-ai.service" ];
        after = [ "podman-pinepods-ai.service" ];
      };
      podman-pinepods-ai = {
        wants = [ "stunnel.service" ];
        after = [ "stunnel.service" ];
      };
    };
  };
}
