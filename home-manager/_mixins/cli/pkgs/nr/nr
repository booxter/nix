#!/usr/bin/env bash

usage() {
  echo "Usage: $(basename "$0") [-p] [-a] [-s <systems>] [-C] PR_NUMBER"
  echo "  -p: Post the result to GitHub"
  echo "  -a: Approve the PR"
  echo "  -s: Specify systems (default: all)"
  echo "  -C: Enable CUDA support"
}

# Array of key = value strings
extra_config=()

while getopts ":aps:C" opt; do
  case $opt in
    p)
      post_result="--post-result"
      ;;
    a)
      approve_pr="--approve-pr"
      ;;
    C)
      extra_config+=("cudaSupport = true;")
      ;;
    s)
      systems="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

# Default systems if not specified; skip x86_64-darwin because it's f*cking slow
systems=${systems:-"x86_64-linux aarch64-linux aarch64-darwin"}

# join extra_config array into a single string separated by ;
extra_config_str=$(IFS=' '; echo "${extra_config[*]}")

# if extra_config_str is not empty, add it to the extra-nixpkgs-config
if [ -n "$extra_config_str" ]; then
  extra_config="--extra-nixpkgs-config={ ${extra_config_str} }"
else
  extra_config=""
fi

set -x
NP=${NP:-"nixpkgs-review"}
cmd=(
  "$NP"
  pr "$@"
  --no-shell
)
if [ -n "$extra_config" ]; then
  cmd+=("$extra_config")
fi
cmd+=(${post_result} ${approve_pr})
cmd+=(--systems="${systems}")

#### Initialize builders

# Always use community builders
builders='ssh://remote-linux-builder aarch64-linux - 10 20 benchmark,big-parallel,kvm,nixos-test ; ssh://remote-linux-x86-builder x86_64-linux - 5 20 benchmark,big-parallel,kvm,nixos-test ; ssh://darwin-builder x86_64-darwin,aarch64-darwin - 3 20 big-parallel'

for i in {1..3}; do
  builders+=" ; ssh://prox-builder${i}vm x86_64-linux - 5 100 benchmark,big-parallel,kvm,nixos-test"
done

# Pick peer machines as builders.
# We have to be careful not to create a loop, so we exclude the current host. nix doesn't support building on localhost via ssh.
if [ $(hostname) != "mmini" ]; then
  # Use higher speed factor for mac mini
  builders+=' ; ssh://mmini x86_64-darwin,aarch64-darwin - 3 25 big-parallel'
fi
if [ $(hostname) != "mair" ]; then
  # Use lower speed factor for macbook air
  builders+=' ; ssh://mair x86_64-darwin,aarch64-darwin - 3 15 big-parallel'
fi
if [ $(hostname) != "frame" ]; then
  # Use higher speed factor for frame
  builders+=' ; ssh://frame x86_64-linux - 10 200 benchmark,big-parallel,kvm,nixos-test'
fi

#### Execute command
cmd+=(--build-args="--builders \"${builders}\"")
"${cmd[@]}"
