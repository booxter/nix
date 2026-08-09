{
  config,
  hostSpec,
  lib,
  pkgs,
  ...
}:
let
  inherit (hostSpec) vnc;
  displayMode = config.hardware.displayMode;
  displayScale = config.hardware.scale;
  displayResolution = "${toString displayMode.width}x${toString displayMode.height}";
  logicalDisplayWidth = builtins.floor (displayMode.width / displayScale);
  logicalDisplayHeight = builtins.floor (displayMode.height / displayScale);
  displays = map (display: {
    name = display.position;
    inherit (display) connector primary;
    scale = displayScale;
    mode = displayMode;
    logical = {
      inherit (display) x;
      y = 0;
      width = logicalDisplayWidth;
      height = logicalDisplayHeight;
    };
  }) config.hardware.displays;

  maxLogicalExtent =
    position: size:
    lib.foldl' (
      maximum: display: lib.max maximum (display.logical.${position} + display.logical.${size})
    ) 0 displays;
  # ReFrame combines normalized VNC pointer coordinates with the physical DRM
  # framebuffer dimensions. Its desktop and monitor offsets must therefore be
  # in physical pixels even though GDM and Hyprland use logical coordinates.
  desktopWidth = builtins.floor (maxLogicalExtent "x" "width" * displayScale);
  desktopHeight = builtins.floor (maxLogicalExtent "y" "height" * displayScale);
  monitorPosition = position: display: builtins.floor (display.logical.${position} * displayScale);

  reframeInstances = lib.listToAttrs (
    lib.imap0 (
      index: display:
      lib.nameValuePair display.name (
        display
        // {
          # Keep the VNC listeners stable while deriving one port per display.
          port = vnc.basePort + index;
        }
      )
    ) displays
  );

  # nixpkgs' edid-generator ships this generic 3840x2160@60 EDID, built from
  # its bundled 594 MHz 4K60 modeline. It is not either monitor's physical
  # model. The generator's assembly template hard-codes `LNX`, the EISA
  # manufacturer ID for "Linux", and the `Linux #0` serial descriptor; the
  # product descriptor is the modeline name. GDM must use these exact decoded
  # identifiers to match its layout to the synthetic outputs.
  # https://github.com/akatrevorjay/edid-generator/blob/476a016d8b488df749bf6d6efbf7b9fbfb2e3cb8/3840x2160.S
  syntheticEdid = {
    filename = "${displayResolution}.bin";
    vendor = "LNX";
    product = displayResolution;
    serial = "Linux #0";
    refreshRate = displayMode.refreshRate;
  };

  reframeConfigPath = instance: "/run/secrets-rendered/reframe-${instance}.conf";
  reframeServer = lib.getExe' pkgs.reframe "reframe-server";
  reframeStreamer = lib.getExe' pkgs.reframe "reframe-streamer";
  xml = pkgs.formats.xml { };

  mkReframeConfig =
    spec@{
      connector,
      logical,
      port,
      ...
    }:
    ''
      [reframe]
      card=${config.hardware.drmCard}
      connector=${connector}
      rotation=0
      desktop-width=${toString desktopWidth}
      desktop-height=${toString desktopHeight}
      monitor-x=${toString (monitorPosition "x" spec)}
      monitor-y=${toString (monitorPosition "y" spec)}
      default-width=${toString logical.width}
      default-height=${toString logical.height}
      resize=true
      # Screen Sharing draws its own local cursor. Do not also composite the
      # DRM cursor plane into the captured image.
      cursor=false
      wakeup=true
      # CPU damage detection is more conservative on this AMD GPU. It avoids
      # the artifacts GPU-based detection can produce, at some CPU cost.
      damage=cpu
      fps=30

      [vnc]
      # SSH forwards this loopback listener. Authentication is still required
      # so an unrelated process on frame cannot attach to the desktop.
      ip=127.0.0.1
      port=${toString port}
      password=${config.sops.placeholder.reframeVncPassword}
      # libvncserver is compatible with macOS's native Screen Sharing client.
      type=libvncserver

      [libvncserver]

      [neatvnc]
      allow-broken-crypto=false
    '';

  # GDM uses Mutter before login. Mutter's monitors.xml v2 format groups each
  # connector and synthetic EDID identity into a logical monitor with the same
  # position and scale that Hyprland uses after login.
  mkGdmLogicalMonitor =
    display:
    {
      inherit (display.logical) x y;
      inherit (display) scale;
      monitor = {
        monitorspec = {
          inherit (display) connector;
          inherit (syntheticEdid) product serial vendor;
        };
        mode = {
          inherit (display.mode) height width;
          rate = syntheticEdid.refreshRate;
        };
      };
    }
    // lib.optionalAttrs display.primary { primary = "yes"; };
  gdmMonitorsXml = xml.generate "monitors.xml" {
    monitors = {
      "@version" = "2";
      policy.stores.store = "system";
      configuration = {
        layoutmode = "logical";
        logicalmonitor = map mkGdmLogicalMonitor displays;
      };
    };
  };
in
{
  assertions = [
    {
      assertion = config.hardware.drmCard != null;
      message = "Frame remote desktop requires hardware.drmCard";
    }
    {
      assertion = displayMode != null;
      message = "Frame remote desktop requires hardware.displayMode";
    }
    {
      assertion = displayScale != null;
      message = "Frame remote desktop requires hardware.scale";
    }
    {
      assertion = displays != [ ];
      message = "Frame remote desktop requires at least one hardware.displays entry";
    }
  ];

  # The KVM removes the monitors' EDIDs when it selects another computer. Use
  # edid-generator's prebuilt standard 128-byte 4K60 EDID firmware blob
  # (monitor identity and timing data, not executable code). NixOS puts it in
  # the initrd and adds drm.edid_firmware for both connectors; the kernel's
  # `video=<connector>:e` argument then keeps those outputs enabled while
  # disconnected. GDM and Hyprland therefore keep rendering frames that
  # ReFrame can capture.
  hardware.display = {
    edid.packages = [ pkgs.edid-generator ];
    outputs = lib.listToAttrs (
      map (
        display:
        lib.nameValuePair display.connector {
          edid = syntheticEdid.filename;
          mode = "e";
        }
      ) displays
    );
  };

  # Match Hyprland's logical layout at the GDM login screen.
  # ReFrame maps pointer coordinates against the same calculated desktop.
  environment.etc."xdg/monitors.xml".source = gdmMonitorsXml;

  services.reframe.enable = true;

  sops.secrets.reframeVncPassword = {
    key = "reframe/vnc/password";
  };

  sops.templates = lib.mapAttrs' (
    instance: spec:
    lib.nameValuePair "reframe-${instance}.conf" {
      path = reframeConfigPath instance;
      # The streamer starts as root but its capability bounding set excludes
      # CAP_DAC_OVERRIDE, so it cannot read a 0400 file owned by `reframe`.
      # Let it read as owner and the unprivileged server read via its group.
      owner = "root";
      group = "reframe";
      mode = "0440";
      content = mkReframeConfig spec;
      restartUnits = [
        "reframe-server@${instance}.service"
        "reframe-streamer@${instance}.service"
      ];
    }
  ) reframeInstances;

  # ReFrame's NixOS module normally writes its configuration to /etc, which
  # would expose the VNC password in the Nix store. `asDropin` makes NixOS add
  # overrides to ReFrame's packaged template units instead of replacing them,
  # preserving their socket dependencies, privilege split, capabilities, and
  # hardening. Define the command override on each concrete instance: systemd
  # did not merge the generic template drop-in with NixOS' instance drop-ins.
  # The empty ExecStart resets the vendor command before the second entry points
  # it at the runtime-only, sops-rendered configuration.
  systemd.services = lib.foldl' (
    services: instance:
    services
    // {
      "reframe-server@${instance}" = {
        overrideStrategy = "asDropin";
        wantedBy = [ "multi-user.target" ];
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        serviceConfig.ExecStart = [
          ""
          "${reframeServer} --config=${reframeConfigPath instance} --socket=%t/reframe/${instance}.sock --session-socket=%t/reframe-session/${instance}.sock"
        ];
      };
      "reframe-streamer@${instance}" = {
        overrideStrategy = "asDropin";
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        serviceConfig.ExecStart = [
          ""
          "${reframeStreamer} --config=${reframeConfigPath instance} --socket=%t/reframe/${instance}.sock"
        ];
      };
    }
  ) { } (builtins.attrNames reframeInstances);
}
