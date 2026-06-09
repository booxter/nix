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
  diff_path="$(command -v diff)"

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

mkdir -p \
  "$out_link/bin" \
  "$out_link/generated" \
  "$out_link/etc/nix" \
  "$out_link/etc/nut" \
  "$out_link/etc/profiles/per-user/ihrachyshka/share/man/man5" \
  "$out_link/etc/terminfo/x~nix~case~hack~1"
printf 'activate=%s\n' "$last_arg" >"$out_link/activate"
printf 'switch=%s\n' "$last_arg" >"$out_link/bin/switch-to-configuration"
printf 'flake=%s\n' "$last_arg" >"$out_link/generated/nix.conf"
printf 'store=/nix/store/%s-same-package/bin\n' "$store_hash" >>"$out_link/generated/nix.conf"
chmod 0444 "$out_link/generated/nix.conf"
printf 'Welcome to NixOS %s\n' "$last_arg" >"$out_link/etc/issue"
printf 'readonly=true\n' >"$out_link/etc/nut/ups.conf"
{
  printf 'man-flake=%s\n' "$last_arg"
  printf '\\fB/nix/store/%s\\-source/modules/generic/meta\\-maintainers\\&.nix\\fP\n' "$store_hash"
} >"$out_link/etc/profiles/per-user/ihrachyshka/share/man/man5/home-configuration.nix.5"
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
    printf 'real_diff=%q\n' "$diff_path"
    cat <<'SH'
set -euo pipefail

args=()
for arg in "$@"; do
  if [ -n "${DIFF_ARGS_LOG:-}" ]; then
    printf '<%s>\n' "$arg" >>"$DIFF_ARGS_LOG"
  fi
  case "$arg" in
    --color | --color=*) ;;
    *) args+=("$arg") ;;
  esac
done

exec "$real_diff" "${args[@]}"
SH
  } >"$fake_bin/diff"
  chmod +x "$fake_bin/diff"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'SH'
set -euo pipefail

is_build=false
wants_session_variables=false
for arg in "$@"; do
  if [ "$arg" = "build" ]; then
    is_build=true
  fi
  case "$arg" in
    *sessionVariablesPackage*) wants_session_variables=true ;;
  esac
done

if [ "$is_build" = true ]; then
  mkdir -p "${HM_BUILD_ROOT:?}"
  out="$(mktemp -d "${HM_BUILD_ROOT:?}/hm.XXXXXX")"
  case "${DIFF_CONFIG_FLAKE_REF:?}" in
    *"${DIFF_CONFIG_MACHINE:?}"*) store_hash=33333333333333333333333333333333 ;;
    *) store_hash=44444444444444444444444444444444 ;;
  esac

  if [ "$wants_session_variables" = true ]; then
    mkdir -p "$out/etc/profile.d"
    printf 'session=%s\n' "${DIFF_CONFIG_FLAKE_REF:?}" >"$out/etc/profile.d/hm-session-vars.sh"
    printf 'store=/nix/store/%s-same-session-package/bin\n' "$store_hash" >>"$out/etc/profile.d/hm-session-vars.sh"
    printf '%s\n' "$out"
    exit 0
  fi

  mkdir -p "$out/home-files/.config" "$out/LaunchAgents"
  printf 'activate=%s\n' "${DIFF_CONFIG_FLAKE_REF:?}" >"$out/activate"
  printf 'store=/nix/store/%s-same-activation-package/bin\n' "$store_hash" >>"$out/activate"
  printf 'flake=%s\n' "${DIFF_CONFIG_FLAKE_REF:?}" >"$out/home-files/.config/hm.conf"
  printf 'store=/nix/store/%s-same-home-package/bin\n' "$store_hash" >>"$out/home-files/.config/hm.conf"
  printf 'agent=%s\n' "${DIFF_CONFIG_FLAKE_REF:?}" >"$out/LaunchAgents/org.example.hm.plist"
  printf '%s\n' "$out"
  exit 0
fi

if [ -n "${DIFF_CONFIG_VALIDATE_MACHINE:-}" ]; then
  case "${DIFF_CONFIG_MACHINE:-}" in
    frame | mair | org | srvarr | builder1 | fana) printf '%s\n' true ;;
    *) printf '%s\n' false ;;
  esac
  exit 0
fi

if [ -n "${DIFF_CONFIG_RESOLVE_MACHINE_ALIAS:-}" ]; then
  case "${DIFF_CONFIG_MACHINE:-}" in
    org) printf '%s\n' org ;;
    *) printf '%s\n' "${DIFF_CONFIG_MACHINE:-}" ;;
  esac
  exit 0
fi

if [ -n "${DIFF_CONFIG_TARGET_KIND:-}" ]; then
  printf '%s\n' "${DIFF_CONFIG_HM_USERS:-ihrachyshka}"
else
  if [ -n "${FAKE_OLD_REV:-}" ] && [[ "${DIFF_CONFIG_FLAKE_REF:-}" == *"rev=${FAKE_OLD_REV}"* ]]; then
    case "${DIFF_CONFIG_MACHINE:-}" in
      builder1 | fana | prox-fanavm)
        printf '%s\n' missing
        exit 0
        ;;
      prox-builder1vm)
        printf '%s\n' nixos
        exit 0
        ;;
    esac
  fi

  case "${DIFF_CONFIG_MACHINE:-}" in
    frame | org | srvarr | builder1 | fana)
      printf '%s\n' nixos
      ;;
    mair)
      printf '%s\n' darwin
      ;;
    *)
      printf '%s\n' "${NIX_TARGET_KIND:-darwin}"
      ;;
  esac
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

@test "diff-config resolves short VM names before building" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-alias-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-alias-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-alias-$BATS_TEST_NUMBER" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    NIX_TARGET_KIND=nixos \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    org \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  grep -F -- '<os>' "$nh_log"
  grep -F -- '<--hostname>' "$nh_log"
  grep -F -- '<org>' "$nh_log"
  [[ "$output" == *"CHANGED"* ]]
}

@test "diff-config compares old prox VM attrs with new short attrs" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-legacy-vm-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-legacy-vm-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-legacy-vm-$BATS_TEST_NUMBER" \
    FAKE_OLD_REV="$old_rev" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    builder1 \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^---$' "$nh_log")" -eq 2 ]
  grep -F -- '<--hostname>' "$nh_log"
  grep -F -- '<prox-builder1vm>' "$nh_log"
  grep -F -- '<builder1>' "$nh_log"
  [[ "$output" == *"CHANGED"* ]]
}

@test "diff-config reports new-only machines without failing" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-new-only-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-new-only-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-new-only-$BATS_TEST_NUMBER" \
    FAKE_OLD_REV="$old_rev" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    fana \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [ "$output" = "Machine 'fana' is present only in the new revision; no old configuration exists to diff." ]
  [ ! -e "$nh_log" ]
  [ ! -e "$dix_log" ]
}

@test "diff-config --details appends generated config diff" {
  make_repo
  make_fake_bin

  nh_log="$BATS_TMPDIR/diff-config-nh-details-$BATS_TEST_NUMBER.log"
  dix_log="$BATS_TMPDIR/diff-config-dix-details-$BATS_TEST_NUMBER.log"
  diff_log="$BATS_TMPDIR/diff-config-diff-details-$BATS_TEST_NUMBER.log"
  rm -f "$nh_log" "$dix_log" "$diff_log"

  run env \
    DIFF_CONFIG_REPO_ROOT="$repo" \
    DIFF_CONFIG_DIFF_COLOR=always \
    XDG_CACHE_HOME="$BATS_TMPDIR/diff-config-cache-details-$BATS_TEST_NUMBER" \
    HM_BUILD_ROOT="$BATS_TMPDIR/diff-config-hm-details-$BATS_TEST_NUMBER" \
    NH_ARGS_LOG="$nh_log" \
    DIX_ARGS_LOG="$dix_log" \
    DIFF_ARGS_LOG="$diff_log" \
    PATH="$fake_bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../scripts/diff-config.sh" \
    --details \
    --path etc/nix/nix.conf \
    --path etc/terminfo \
    .#nixosConfigurations.frame.config.system.build.toplevel \
    "$old_rev" \
    "$new_rev"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^<--color=always>$' "$diff_log")" -eq 1 ]
  [[ "$output" == *"CHANGED"* ]]
  [[ "$output" != *"Detailed config diff:"* ]]
  [[ "$output" == *"diff -ruN old/system/etc/nix/nix.conf new/system/etc/nix/nix.conf"* ]]
  [[ "$output" == *"diff -ruN old/system/activate new/system/activate"* ]]
  [[ "$output" == *"diff -ruN old/system/bin/switch-to-configuration new/system/bin/switch-to-configuration"* ]]
  [[ "$output" != *"old/system/etc/issue"* ]]
  [[ "$output" != *"home-configuration.nix.5"* ]]
  [[ "$output" != *"man-flake"* ]]
  [[ "$output" == *"etc/nix/nix.conf"* ]]
  [[ "$output" == *"-flake=git+file://$repo?rev=$old_rev"* ]]
  [[ "$output" == *"+flake=git+file://$repo?rev=$new_rev"* ]]
  [[ "$output" == *"/nix/store/<path>/bin"* ]]
  [[ "$output" != *"Home Manager diff ("* ]]
  [[ "$output" != *"Building Home Manager activation package"* ]]
  [[ "$output" == *"diff -ruN old/home-manager/ihrachyshka/activate new/home-manager/ihrachyshka/activate"* ]]
  [[ "$output" == *"diff -ruN old/home-manager/ihrachyshka/home-files/.config/hm.conf new/home-manager/ihrachyshka/home-files/.config/hm.conf"* ]]
  [[ "$output" == *"diff -ruN old/home-manager/ihrachyshka/session-vars/etc/profile.d/hm-session-vars.sh new/home-manager/ihrachyshka/session-vars/etc/profile.d/hm-session-vars.sh"* ]]
  [[ "$output" == *"home-files/.config/hm.conf"* ]]
  [[ "$output" == *"LaunchAgents/org.example.hm.plist"* ]]
  [[ "$output" == *"session-vars/etc/profile.d/hm-session-vars.sh"* ]]
  [[ "$output" == *"/nix/store/<path>/bin"* ]]
  [[ "$output" != *"same-package"* ]]
  [[ "$output" != *"same-home-package"* ]]
  [[ "$output" != *"same-session-package"* ]]
  [[ "$output" != *"same-activation-package"* ]]
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
