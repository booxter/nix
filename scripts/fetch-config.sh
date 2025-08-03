#! /usr/bin/env nix-shell
#! nix-shell -i bash -p git

mkdir -p ~/src
pushd ~/src
git clone https://github.com/booxter/nix.git
