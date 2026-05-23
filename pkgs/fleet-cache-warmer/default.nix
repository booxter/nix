{
  lib,
  attic-client,
  coreutils,
  nix,
  stdenv,
  writeShellApplication,
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../../ci-target-inventory.json);
  ciValidatedWarmTargets = map (target: target.attr) (
    lib.filter (target: target.warm) (
      inventory.buildTargets ++ inventory.regularChecks ++ inventory.nixosTests
    )
  );
  embeddedTargetAssignments = lib.concatMapStringsSep "\n" (
    target: ''target_suffixes+=("${target}")''
  ) ciValidatedWarmTargets;
  targetInventoryAttr = "packages.${stdenv.hostPlatform.system}.fleet-cache-warmer.ciWarmTargets";
in
writeShellApplication {
  name = "fleet-cache-warmer";
  passthru.ciWarmTargets = ciValidatedWarmTargets;
  runtimeInputs = [
    attic-client
    coreutils
    nix
  ];
  text = ''
        set -euo pipefail

        usage() {
          cat <<'EOF'
    Usage: fleet-cache-warmer [--print-targets]

    Build and push the CI-validated fleet outputs to the local Attic cache.
    The flake reference and cache name can be overridden with:

      FLEET_CACHE_WARMER_FLAKE
      FLEET_CACHE_WARMER_ATTIC_CACHE
    EOF
        }

        flake_ref="''${FLEET_CACHE_WARMER_FLAKE:-github:booxter/nix}"
        attic_cache="''${FLEET_CACHE_WARMER_ATTIC_CACHE:-default}"

        load_target_suffixes() {
          local inventory_ref
          inventory_ref="''${flake_ref}#${targetInventoryAttr}"

          if mapfile -t target_suffixes < <(
            ${lib.getExe nix} eval "$inventory_ref" \
              --apply 'xs: builtins.concatStringsSep "\n" xs' \
              --raw 2>/dev/null
          ) && [ "''${#target_suffixes[@]}" -gt 0 ]; then
            printf 'Loaded %s warm target(s) from %s\n' "''${#target_suffixes[@]}" "$inventory_ref" >&2
            return 0
          fi

          echo "fleet-cache-warmer: failed to load target inventory from $inventory_ref; falling back to embedded target list" >&2
          target_suffixes=()
          ${embeddedTargetAssignments}
        }

        declare -a target_suffixes=()
        load_target_suffixes

        declare -a targets=()
        for suffix in "''${target_suffixes[@]}"; do
          targets+=("''${flake_ref}#''${suffix}")
        done

        case "''${1:-run}" in
          --print-targets)
            printf '%s\n' "''${targets[@]}"
            exit 0
            ;;
          --help|-h)
            usage
            exit 0
            ;;
          run)
            ;;
          *)
            usage >&2
            exit 1
            ;;
        esac

        out_paths_file="$(${coreutils}/bin/mktemp -t fleet-cache-warmer.XXXXXX)"
        trap '${coreutils}/bin/rm -f "$out_paths_file"' EXIT

        success_count=0
        failed_count=0

        printf 'Building %s CI-validated warm target(s) from %s\n' "''${#targets[@]}" "$flake_ref" >&2
        : >"$out_paths_file"
        for target in "''${targets[@]}"; do
          printf 'Warming %s\n' "$target" >&2
          if ${lib.getExe nix} build -L --no-link --print-out-paths "$target" >>"$out_paths_file"; then
            success_count=$((success_count + 1))
          else
            failed_count=$((failed_count + 1))
            printf 'fleet-cache-warmer: target failed, skipping: %s\n' "$target" >&2
          fi
        done

        if ! ${coreutils}/bin/test -s "$out_paths_file"; then
          echo "fleet-cache-warmer: no targets built successfully; skipping cache push" >&2
          exit 0
        fi

        printf 'Pushing warmed closures for %s successful target(s) to Attic cache %s\n' "$success_count" "$attic_cache" >&2
        ${coreutils}/bin/sort -u "$out_paths_file" \
          | ${lib.getExe attic-client} push --ignore-upstream-cache-filter --stdin "$attic_cache"

        if [ "$failed_count" -gt 0 ]; then
          printf 'fleet-cache-warmer: completed with %s skipped target failure(s)\n' "$failed_count" >&2
        fi
  '';
}
