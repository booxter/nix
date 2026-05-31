#!/usr/bin/env bats

make_repo() {
  repo="$BATS_TMPDIR/diff-config-repo-$BATS_TEST_NUMBER"
  rm -rf "$repo"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"

  git -C "$repo" init -q -b main
  cat >"$repo/flake.nix" <<'NIX'
{
  outputs = { self }: {
    nixosConfigurations.frame = {};
    darwinConfigurations.mair = {};
  };
}
NIX
  git -C "$repo" add flake.nix
  git -C "$repo" -c user.name='Test User' -c user.email='test@example.invalid' commit -q -m old
  old_rev="$(git -C "$repo" rev-parse HEAD)"

  cat >"$repo/flake.nix" <<'NIX'
{
  outputs = { self }: {
    nixosConfigurations.frame = {};
    darwinConfigurations.mair = {};
    changed = true;
  };
}
NIX
  git -C "$repo" add flake.nix
  git -C "$repo" -c user.name='Test User' -c user.email='test@example.invalid' commit -q -m new
  new_rev="$(git -C "$repo" rev-parse HEAD)"
}

make_fake_bin() {
  fake_bin="$BATS_TMPDIR/diff-config-bin-$BATS_TEST_NUMBER"
  rm -rf "$fake_bin"
  mkdir -p "$fake_bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'SH'
set -euo pipefail

for arg in "$@"; do
  printf '<%s>\n' "$arg" >>"$NH_ARGS_LOG"
done
printf '%s\n' '---' >>"$NH_ARGS_LOG"

out_link=""
last_arg=""
while [ "$#" -gt 0 ]; do
  last_arg="$1"
  if [ "$1" = "--out-link" ]; then
    shift
    out_link="${1:?}"
  fi
  shift
done

if [ -z "$out_link" ]; then
  echo "missing --out-link" >&2
  exit 2
fi

mkdir -p "$out_link/generated" "$out_link/etc/nix"
printf 'flake=%s\n' "$last_arg" >"$out_link/generated/nix.conf"
ln -s ../../generated/nix.conf "$out_link/etc/nix/nix.conf"
SH
  } >"$fake_bin/nh"
  chmod +x "$fake_bin/nh"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'SH'
set -euo pipefail

printf '<%s>\n' "$@" >"$DIX_ARGS_LOG"
printf '<<< %s\n' "$1"
printf '>>> %s\n' "$2"
printf '\n'
printf 'CHANGED\n'
printf '[U.] package 1.0 -> 2.0\n'
printf '\n'
printf 'SIZE: 1 -> 2\n'
printf 'DIFF: 1\n'
SH
  } >"$fake_bin/dix"
  chmod +x "$fake_bin/dix"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'SH'
set -euo pipefail

printf '%s\n' "${NIX_TARGET_KIND:-darwin}"
SH
  } >"$fake_bin/nix"
  chmod +x "$fake_bin/nix"
}

@test "diff-config shows usage" {
  run bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: diff-config [--details] [--path <relpath>] <machine> <old-rev> <new-rev>"* ]]
}

@test "diff-config builds both revisions with nh and diffs with dix" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-$BATS_TEST_NUMBER" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    .#nixosConfigurations.frame.config.system.build.toplevel \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^---$' "$nh_log")" -eq 2 ]
  grep -F -- '<os>' "$nh_log"
  grep -F -- '<build>' "$nh_log"
  grep -F -- '<--diff>' "$nh_log"
  grep -F -- '<never>' "$nh_log"
  grep -F -- '<--hostname>' "$nh_log"
  grep -F -- '<frame>' "$nh_log"
  grep -F -- "<git+file://$repo?rev=$old_rev>" "$nh_log"
  grep -F -- "<git+file://$repo?rev=$new_rev>" "$nh_log"
  grep -E '^<.*/old>$' "$dix_log"
  grep -E '^<.*/new>$' "$dix_log"
  [[ "$output" != *"<<< "* ]]
  [[ "$output" != *">>> "* ]]
  [[ "$output" == *"CHANGED"* ]]
  [[ "$output" == *"[U.] package 1.0 -> 2.0"* ]]
  [[ "$output" == *"SIZE: 1 -> 2"* ]]
}

@test "diff-config --details appends generated config diff" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-details-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-details-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-details-$BATS_TEST_NUMBER" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    --details \
    --path etc/nix/nix.conf \
    .#nixosConfigurations.frame.config.system.build.toplevel \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGED"* ]]
  [[ "$output" == *"Generated config diff (etc/nix/nix.conf):"* ]]
  [[ "$output" == *"etc/nix/nix.conf"* ]]
  [[ "$output" == *"-flake=git+file://$repo?rev=$old_rev"* ]]
  [[ "$output" == *"+flake=git+file://$repo?rev=$new_rev"* ]]
}

@test "diff-config detects bare darwin targets" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-darwin-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-darwin-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-darwin-$BATS_TEST_NUMBER" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    mair \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^---$' "$nh_log")" -eq 2 ]
  grep -F -- '<darwin>' "$nh_log"
  grep -F -- '<build>' "$nh_log"
  grep -F -- '<--diff>' "$nh_log"
  grep -F -- '<never>' "$nh_log"
  grep -F -- '<--hostname>' "$nh_log"
  grep -F -- '<mair>' "$nh_log"
  grep -F -- "<git+file://$repo?rev=$old_rev>" "$nh_log"
  grep -F -- "<git+file://$repo?rev=$new_rev>" "$nh_log"
  grep -E '^<.*/old>$' "$dix_log"
  grep -E '^<.*/new>$' "$dix_log"
  [[ "$output" != *"<<< "* ]]
  [[ "$output" != *">>> "* ]]
  [[ "$output" == *"CHANGED"* ]]
  [[ "$output" == *"[U.] package 1.0 -> 2.0"* ]]
  [[ "$output" == *"SIZE: 1 -> 2"* ]]
}
