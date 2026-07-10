{
  lib,
  attic-client,
  coreutils,
  name ? "fleet-cache-warmer",
  nix,
  pushToAttic ? true,
  targetFilter ? "non-work",
  useRemoteBuilders ? true,
  writeShellApplication,
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../../../ci-target-inventory.json);
  hostInventory = import ../../../lib/inventory.nix { inherit lib; };
  workHosts = lib.genAttrs (
    (map (spec: spec.name) (lib.filter (spec: spec.isWork or false) hostInventory.nixosHostSpecs))
    ++ (lib.attrNames (lib.filterAttrs (_: cfg: cfg.isWork or false) hostInventory.darwinHosts))
  ) (_: true);
  isWorkTarget = target: lib.any (host: workHosts.${host} or false) (target.selection.hosts or [ ]);
  matchesTargetFilter =
    target:
    if targetFilter == "work" then
      isWorkTarget target
    else if targetFilter == "non-work" then
      !(isWorkTarget target)
    else
      throw "unknown fleet-cache-warmer targetFilter: ${targetFilter}";
  ciValidatedWarmTargets = map (target: target.attr) (
    lib.filter (target: target.warm && matchesTargetFilter target) (
      inventory.buildTargets ++ inventory.regularChecks ++ inventory.nixosTests
    )
  );
  embeddedTargetAssignments = lib.concatMapStringsSep "\n" (
    target: ''target_suffixes+=("${target}")''
  ) ciValidatedWarmTargets;
in
writeShellApplication {
  inherit name;
  passthru.ciWarmTargets = ciValidatedWarmTargets;
  runtimeInputs = [
    coreutils
    nix
  ]
  ++ lib.optional pushToAttic attic-client;
  text = ''
        set -euo pipefail

        usage() {
          cat <<'EOF'
    Usage: ${name} [--print-targets]

    Build the selected CI-validated fleet outputs.
    The flake reference can be overridden with:

      FLEET_CACHE_WARMER_FLAKE
    ${lib.optionalString pushToAttic ''
      The Attic cache name can be overridden with:

        FLEET_CACHE_WARMER_ATTIC_CACHE
    ''}
    EOF
        }

        flake_ref="''${FLEET_CACHE_WARMER_FLAKE:-github:booxter/nix}"
    ${lib.optionalString pushToAttic ''
      attic_cache="''${FLEET_CACHE_WARMER_ATTIC_CACHE:-default}"
    ''}
        declare -a nix_build_opts=()
    ${lib.optionalString (!useRemoteBuilders) ''
      nix_build_opts+=(--option builders "")
    ''}

        declare -a target_suffixes=()
        ${embeddedTargetAssignments}

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

        out_paths_file="$(${coreutils}/bin/mktemp -t ${name}.XXXXXX)"
        trap '${coreutils}/bin/rm -f "$out_paths_file"' EXIT

        declare -a buildable_targets=()
        skipped_inventory_count=0
        printf 'Resolving %s warm target(s) from %s\n' "''${#targets[@]}" "$flake_ref" >&2
        for i in "''${!targets[@]}"; do
          target="''${targets[$i]}"
          printf 'Resolving target %s/%s: %s\n' "$((i + 1))" "''${#targets[@]}" "$target" >&2
          if ${lib.getExe nix} eval --raw "$target.outPath" >/dev/null 2>&1; then
            buildable_targets+=("$target")
          else
            skipped_inventory_count=$((skipped_inventory_count + 1))
            printf '${name}: target is missing or does not evaluate, skipping: %s\n' "$target" >&2
          fi
        done

        if [ "''${#buildable_targets[@]}" -eq 0 ]; then
          echo "${name}: no warm targets resolved successfully" >&2
          exit 0
        fi

        printf 'Building %s resolved warm target(s) from %s\n' "''${#buildable_targets[@]}" "$flake_ref" >&2
        : >"$out_paths_file"
        if ! ${lib.getExe nix} build "''${nix_build_opts[@]}" -L --keep-going --no-link --print-out-paths "''${buildable_targets[@]}" >>"$out_paths_file"; then
          echo "${name}: batched build reported failures; continuing with any successful outputs" >&2
        fi

        fallback_failed_count=0
        if ! ${coreutils}/bin/test -s "$out_paths_file"; then
          echo "${name}: batched build produced no successful outputs; retrying target-by-target" >&2
          for target in "''${buildable_targets[@]}"; do
            printf 'Warming %s\n' "$target" >&2
            if ! ${lib.getExe nix} build "''${nix_build_opts[@]}" -L --no-link --print-out-paths "$target" >>"$out_paths_file"; then
              fallback_failed_count=$((fallback_failed_count + 1))
              printf '${name}: target failed, skipping: %s\n' "$target" >&2
            fi
          done
        fi

        if ! ${coreutils}/bin/test -s "$out_paths_file"; then
          echo "${name}: no targets built successfully" >&2
          exit 0
        fi

        realized_output_count="$(${coreutils}/bin/sort -u "$out_paths_file" | ${coreutils}/bin/wc -l | ${coreutils}/bin/tr -d ' ')"
    ${lib.optionalString pushToAttic ''
      printf 'Pushing %s warmed output path(s) to Attic cache %s\n' "$realized_output_count" "$attic_cache" >&2
      ${coreutils}/bin/sort -u "$out_paths_file" \
        | ${lib.getExe attic-client} push --ignore-upstream-cache-filter --stdin "$attic_cache"
    ''}
    ${lib.optionalString (!pushToAttic) ''
      printf 'Built %s warmed output path(s); Attic push disabled\n' "$realized_output_count" >&2
    ''}

        if [ "$skipped_inventory_count" -gt 0 ]; then
          printf '${name}: skipped %s missing or unevaluable inventory target(s)\n' "$skipped_inventory_count" >&2
        fi

        if [ "$fallback_failed_count" -gt 0 ]; then
          printf '${name}: completed with %s skipped target failure(s) after batch fallback\n' "$fallback_failed_count" >&2
        fi
  '';
}
