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

case "$out_link" in
  */old) store_hash=11111111111111111111111111111111 ;;
  *) store_hash=22222222222222222222222222222222 ;;
esac

mkdir -p "$out_link/generated" "$out_link/etc/nix" "$out_link/etc/nut" "$out_link/etc/terminfo/x~nix~case~hack~1"
printf 'flake=%s\n' "$last_arg" >"$out_link/generated/nix.conf"
printf 'store=/nix/store/%s-same-package/bin\n' "$store_hash" >>"$out_link/generated/nix.conf"
chmod 0444 "$out_link/generated/nix.conf"
printf 'readonly=true\n' >"$out_link/etc/nut/ups.conf"
ln -s ../../generated/nix.conf "$out_link/etc/nix/nix.conf"
ln -s missing-target "$out_link/etc/terminfo/x~nix~case~hack~1/xterm-xfree86"
chmod 0555 "$out_link/etc/nut"
SH
  } >"$fake_bin/nh"
  chmod +x "$fake_bin/nh"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'SH'
set -euo pipefail

printf '<%s>\n' "$@" >"$DIX_ARGS_LOG"

old_path=""
new_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --color)
      shift 2
      ;;
    *)
      old_path="$new_path"
      new_path="$1"
      shift
      ;;
  esac
done

printf '<<< %s\n' "$old_path"
printf '>>> %s\n' "$new_path"
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

is_build=false
for arg in "$@"; do
  if [ "$arg" = "build" ]; then
    is_build=true
    break
  fi
done

if [ "$is_build" = true ]; then
  mkdir -p "${HM_BUILD_ROOT:?}"
  out="$(mktemp -d "${HM_BUILD_ROOT:?}/hm.XXXXXX")"
  case "${DIFF_CONFIG_FLAKE_REF:?}" in
    *"${DIFF_CONFIG_MACHINE:?}"*) store_hash=33333333333333333333333333333333 ;;
    *) store_hash=44444444444444444444444444444444 ;;
  esac
  mkdir -p "$out/home-files/.config" "$out/LaunchAgents"
  printf 'flake=%s\n' "${DIFF_CONFIG_FLAKE_REF:?}" >"$out/home-files/.config/hm.conf"
  printf 'store=/nix/store/%s-same-home-package/bin\n' "$store_hash" >>"$out/home-files/.config/hm.conf"
  printf 'agent=%s\n' "${DIFF_CONFIG_FLAKE_REF:?}" >"$out/LaunchAgents/org.example.hm.plist"
  printf '%s\n' "$out"
  exit 0
fi

if [ -n "${DIFF_CONFIG_TARGET_KIND:-}" ]; then
  printf '%s\n' "${DIFF_CONFIG_HM_USERS:-ihrachyshka}"
else
  printf '%s\n' "${NIX_TARGET_KIND:-darwin}"
fi
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
  grep -F -- '<--color>' "$dix_log"
  grep -F -- '<auto>' "$dix_log"
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
    HM_BUILD_ROOT="$BATS_TMPDIR/diff-config-hm-details-$BATS_TEST_NUMBER" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    --details \
    --path etc/nix/nix.conf \
    --path etc/terminfo \
    .#nixosConfigurations.frame.config.system.build.toplevel \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGED"* ]]
  [[ "$output" == *"Generated config diff (etc/nix/nix.conf etc/terminfo):"* ]]
  [[ "$output" == *"diff -ruN old/etc/nix/nix.conf new/etc/nix/nix.conf"* ]]
  [[ "$output" == *"etc/nix/nix.conf"* ]]
  [[ "$output" == *"-flake=git+file://$repo?rev=$old_rev"* ]]
  [[ "$output" == *"+flake=git+file://$repo?rev=$new_rev"* ]]
  [[ "$output" == *"/nix/store/<path>/bin"* ]]
  [[ "$output" == *"Home Manager diff (ihrachyshka; paths: home-files LaunchAgents):"* ]]
  [[ "$output" == *"diff -ruN old/home-files/.config/hm.conf new/home-files/.config/hm.conf"* ]]
  [[ "$output" == *"home-files/.config/hm.conf"* ]]
  [[ "$output" == *"LaunchAgents/org.example.hm.plist"* ]]
  [[ "$output" == *"/nix/store/<path>/bin"* ]]
  [[ "$output" != *"same-package"* ]]
  [[ "$output" != *"same-home-package"* ]]
  [[ "$output" != *"11111111111111111111111111111111"* ]]
  [[ "$output" != *"22222222222222222222222222222222"* ]]
  [[ "$output" != *"33333333333333333333333333333333"* ]]
  [[ "$output" != *"44444444444444444444444444444444"* ]]
  [[ "$output" != *"Permission denied"* ]]
  [[ "$output" != *"cannot stat"* ]]
  [[ "$output" != *"No such file or directory"* ]]
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
