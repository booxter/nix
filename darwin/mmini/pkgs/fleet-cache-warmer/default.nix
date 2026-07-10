{
  lib,
  attic-client,
  coreutils,
  nix,
  stdenv,
  writeShellApplication,
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../../../../ci-target-inventory.json);
  hostInventory = import ../../../../lib/inventory.nix { inherit lib; };
  workHosts = lib.genAttrs (
    (map (spec: spec.name) (lib.filter (spec: spec.isWork or false) hostInventory.nixosHostSpecs))
    ++ (lib.attrNames (lib.filterAttrs (_: cfg: cfg.isWork or false) hostInventory.darwinHosts))
  ) (_: true);
  isWorkTarget = target: lib.any (host: workHosts.${host} or false) (target.selection.hosts or [ ]);
  ciValidatedWarmTargets = map (target: target.attr) (
    lib.filter (target: target.warm && !(isWorkTarget target)) (
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
            inventory_source=flake
            printf 'Loaded %s warm target(s) from %s\n' "''${#target_suffixes[@]}" "$inventory_ref" >&2
            return 0
          fi

          echo "fleet-cache-warmer: failed to load target inventory from $inventory_ref; falling back to embedded target list" >&2
          inventory_source=embedded
          target_suffixes=()
          ${embeddedTargetAssignments}
        }

        inventory_source=embedded
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

        declare -a buildable_targets=()
        skipped_inventory_count=0
        if [ "$inventory_source" = "flake" ]; then
          buildable_targets=("''${targets[@]}")
          printf 'Using %s warm target(s) directly from %s inventory; skipping preflight evaluation\n' "''${#buildable_targets[@]}" "$flake_ref" >&2
        else
          printf 'Resolving %s warm target(s) from %s\n' "''${#targets[@]}" "$flake_ref" >&2
          for i in "''${!targets[@]}"; do
            target="''${targets[$i]}"
            printf 'Resolving target %s/%s: %s\n' "$((i + 1))" "''${#targets[@]}" "$target" >&2
            if ${lib.getExe nix} eval --raw "$target.outPath" >/dev/null 2>&1; then
              buildable_targets+=("$target")
            else
              skipped_inventory_count=$((skipped_inventory_count + 1))
              printf 'fleet-cache-warmer: target is missing or does not evaluate, skipping: %s\n' "$target" >&2
            fi
          done
        fi

        if [ "''${#buildable_targets[@]}" -eq 0 ]; then
          echo "fleet-cache-warmer: no warm targets resolved successfully; skipping cache push" >&2
          exit 0
        fi

        printf 'Building %s resolved warm target(s) from %s\n' "''${#buildable_targets[@]}" "$flake_ref" >&2
        : >"$out_paths_file"
        if ! ${lib.getExe nix} build -L --keep-going --no-link --print-out-paths "''${buildable_targets[@]}" >>"$out_paths_file"; then
          echo "fleet-cache-warmer: batched build reported failures; continuing with any successful outputs" >&2
        fi

        fallback_failed_count=0
        if ! ${coreutils}/bin/test -s "$out_paths_file"; then
          echo "fleet-cache-warmer: batched build produced no successful outputs; retrying target-by-target" >&2
          for target in "''${buildable_targets[@]}"; do
            printf 'Warming %s\n' "$target" >&2
            if ! ${lib.getExe nix} build -L --no-link --print-out-paths "$target" >>"$out_paths_file"; then
              fallback_failed_count=$((fallback_failed_count + 1))
              printf 'fleet-cache-warmer: target failed, skipping: %s\n' "$target" >&2
            fi
          done
        fi

        if ! ${coreutils}/bin/test -s "$out_paths_file"; then
          echo "fleet-cache-warmer: no targets built successfully; skipping cache push" >&2
          exit 0
        fi

        realized_output_count="$(${coreutils}/bin/sort -u "$out_paths_file" | ${coreutils}/bin/wc -l | ${coreutils}/bin/tr -d ' ')"
        printf 'Pushing %s warmed output path(s) to Attic cache %s\n' "$realized_output_count" "$attic_cache" >&2
        ${coreutils}/bin/sort -u "$out_paths_file" \
          | ${lib.getExe attic-client} push --ignore-upstream-cache-filter --stdin "$attic_cache"

        if [ "$skipped_inventory_count" -gt 0 ]; then
          printf 'fleet-cache-warmer: skipped %s missing or unevaluable inventory target(s)\n' "$skipped_inventory_count" >&2
        fi

        if [ "$fallback_failed_count" -gt 0 ]; then
          printf 'fleet-cache-warmer: completed with %s skipped target failure(s) after batch fallback\n' "$fallback_failed_count" >&2
        fi
  '';
}
