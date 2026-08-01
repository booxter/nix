#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-aurral}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"
package_file="nixos/srvarr/pkgs/aurral/default.nix"
nodejs_selector="apps/package-updates/select-nodejs.py"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ ! -f "$package_file" ]]; then
  echo "aurral package file not found: $package_file" >&2
  exit 1
fi

nix-update --flake --system "$system" --src-only --use-github-releases "$attr"

src_path="$(
  nix build --no-link --print-out-paths ".#packages.$system.$attr.src"
)"
nodejs_requirement="$(jq -r '.engines.node // empty' "$src_path/package.json")"

if [[ -n "$nodejs_requirement" ]]; then
  mapfile -t current_nodejs_attrs < <(
    sed -n -E 's/^  (nodejs_[0-9]+),$/\1/p' "$package_file"
  )
  if [[ "${#current_nodejs_attrs[@]}" -ne 1 ]]; then
    echo "::warning::Could not identify exactly one versioned Node.js argument in $package_file"
  else
    current_nodejs_attr="${current_nodejs_attrs[0]}"
    if nodejs_candidates="$(
      AURRAL_UPDATE_NIX_SYSTEM="$system" \
        nix eval --option eval-cache false --impure --json \
        --expr '
          let
            flake = builtins.getFlake (toString ./.);
            system = builtins.getEnv "AURRAL_UPDATE_NIX_SYSTEM";
            pkgs = builtins.getAttr system flake.inputs.nixpkgs.legacyPackages;
            names = builtins.filter
              (name: builtins.match "nodejs_[0-9]+" name != null)
              (builtins.attrNames pkgs);
            evaluated = map
              (name: {
                inherit name;
                result = builtins.tryEval ((builtins.getAttr name pkgs).version);
              })
              names;
            available = builtins.filter (entry: entry.result.success) evaluated;
          in
          builtins.listToAttrs (map
            (entry: {
              inherit (entry) name;
              value = entry.result.value;
            })
            available)
        '
    )"; then
      if nodejs_selection="$(
        python3 "$nodejs_selector" \
          --requirement "$nodejs_requirement" \
          --current-attribute "$current_nodejs_attr" \
          --candidates-json "$nodejs_candidates"
      )"; then
        selected_nodejs_attr="$(jq -r '.attribute' <<< "$nodejs_selection")"
        selected_nodejs_version="$(jq -r '.version' <<< "$nodejs_selection")"
        if [[ "$selected_nodejs_attr" != "$current_nodejs_attr" ]]; then
          sed -i -E \
            "s#\\b${current_nodejs_attr}\\b#${selected_nodejs_attr}#g" \
            "$package_file"
        fi
        echo "npm engine ${nodejs_requirement}: using ${selected_nodejs_attr} (${selected_nodejs_version})"
      else
        echo "::warning::Leaving ${current_nodejs_attr} unchanged; the update PR needs Node.js version review"
      fi
    else
      echo "::warning::Could not evaluate nixpkgs Node.js candidates; leaving ${current_nodejs_attr} unchanged"
    fi
  fi
fi

npm_deps_hash="$(NPM_FETCHER_VERSION=2 prefetch-npm-deps "$src_path/package-lock.json" | tail -n 1)"
if [[ ! "$npm_deps_hash" =~ ^sha256- ]]; then
  echo "failed to prefetch npm dependencies for $attr: $npm_deps_hash" >&2
  exit 1
fi

sed -i -E \
  's#(npmDepsHash = ")[^"]+(";)#\1'"$npm_deps_hash"'\2#' \
  "$package_file"
