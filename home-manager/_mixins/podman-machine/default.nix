{
  config,
  isDarwin,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.podman-machine;
  machineConfig = pkgs.writeText "podman-machine.conf" ''
    [machine]
    cpus = ${toString cfg.cpus}
    disk_size = ${toString cfg.diskSizeGiB}
    memory = ${toString cfg.memoryMiB}
    provider = ${builtins.toJSON cfg.provider}
  '';
  podmanMachineEnsure = pkgs.writeShellApplication {
    name = "podman-machine-ensure";
    runtimeInputs = [
      cfg.package
      pkgs.jq
    ];
    text = ''
      machine_name=${lib.escapeShellArg cfg.name}
      expected_provider=${lib.escapeShellArg cfg.provider}
      expected_cpus=${toString cfg.cpus}
      expected_memory=${toString cfg.memoryMiB}
      minimum_disk_size=${toString cfg.diskSizeGiB}
      export CONTAINERS_CONF_OVERRIDE=${lib.escapeShellArg machineConfig}

      all_machines="$(podman machine list --all-providers --format json)"
      matching_machines="$(
        jq --arg name "$machine_name" '[.[] | select(.Name == $name)]' <<<"$all_machines"
      )"
      machine_count="$(jq 'length' <<<"$matching_machines")"

      if (( machine_count > 1 )); then
        printf 'Multiple Podman machines named %s exist across providers; refusing to choose one.\n' \
          "$machine_name" >&2
        exit 1
      fi

      if (( machine_count == 1 )); then
        actual_provider="$(jq -r '.[0].VMType' <<<"$matching_machines")"
        if [[ "$actual_provider" != "$expected_provider" ]]; then
          printf 'Podman machine %s uses provider %s; expected %s.\n' \
            "$machine_name" "$actual_provider" "$expected_provider" >&2
          printf 'Remove or rename it manually before allowing the managed machine to be created.\n' >&2
          exit 1
        fi
      else
        podman machine init \
          --cpus="$expected_cpus" \
          --disk-size="$minimum_disk_size" \
          --memory="$expected_memory" \
          "$machine_name"
      fi

      inspect_machine() {
        podman machine inspect "$machine_name"
      }

      machine_json="$(inspect_machine)"
      actual_cpus="$(jq -r '.[0].Resources.CPUs' <<<"$machine_json")"
      actual_memory="$(jq -r '.[0].Resources.Memory' <<<"$machine_json")"
      actual_disk_size="$(jq -r '.[0].Resources.DiskSize' <<<"$machine_json")"
      state="$(jq -r '.[0].State' <<<"$machine_json")"

      set_args=()
      if [[ "$actual_cpus" != "$expected_cpus" ]]; then
        set_args+=(--cpus="$expected_cpus")
      fi
      if [[ "$actual_memory" != "$expected_memory" ]]; then
        set_args+=(--memory="$expected_memory")
      fi
      if (( actual_disk_size < minimum_disk_size )); then
        set_args+=(--disk-size="$minimum_disk_size")
      fi

      restart_on_error=false
      restart_machine() {
        if [[ "$restart_on_error" == true ]]; then
          podman machine start --quiet "$machine_name" || true
        fi
      }
      trap restart_machine EXIT

      if (( ''${#set_args[@]} > 0 )); then
        if [[ "$state" != stopped ]]; then
          restart_on_error=true
          podman machine stop "$machine_name"
        fi

        podman machine set "''${set_args[@]}" "$machine_name"

        machine_json="$(inspect_machine)"
        actual_cpus="$(jq -r '.[0].Resources.CPUs' <<<"$machine_json")"
        actual_memory="$(jq -r '.[0].Resources.Memory' <<<"$machine_json")"
        actual_disk_size="$(jq -r '.[0].Resources.DiskSize' <<<"$machine_json")"
        if [[ "$actual_cpus" != "$expected_cpus" || "$actual_memory" != "$expected_memory" ]] \
          || (( actual_disk_size < minimum_disk_size )); then
          printf 'Podman machine %s did not converge to the requested resources.\n' "$machine_name" >&2
          exit 1
        fi
        state=stopped
      fi

      trap - EXIT
      restart_on_error=false

      if [[ "$state" != running ]]; then
        exec podman machine start --quiet "$machine_name"
      fi
    '';
  };
in
{
  options.programs.podman-machine = {
    enable = lib.mkEnableOption "declarative Podman machine management on Darwin";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.podman;
      description = "Podman package used to manage the machine.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "podman-machine-default";
      description = "Name of the managed Podman machine.";
    };

    provider = lib.mkOption {
      type = lib.types.enum [
        "applehv"
        "libkrun"
      ];
      default = "libkrun";
      description = "Virtualization provider used by the managed Podman machine.";
    };

    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Number of virtual CPUs assigned to the managed machine.";
    };

    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Memory in MiB assigned to the managed machine.";
    };

    diskSizeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
      description = "Minimum disk size in GiB assigned to the managed machine.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to create, reconcile, and start the machine at login.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isDarwin;
        message = "programs.podman-machine is only supported on Darwin.";
      }
    ];

    home.packages = [
      cfg.package
      podmanMachineEnsure
    ];

    xdg.configFile."containers/containers.conf.d/50-podman-machine.conf".source = machineConfig;

    launchd.agents.podman-machine = lib.mkIf cfg.autoStart {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe podmanMachineEnsure) ];
        RunAtLoad = true;
        AbandonProcessGroup = true;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/podman-machine.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/podman-machine.log";
      };
    };
  };
}
