#! /usr/bin/env nix-shell
#! nix-shell -i bash -p git

set -euo pipefail

if [ "$#" -eq 1 ]; then
	REMOTE_HOST="$1"
	scp "$0" "$REMOTE_HOST:~/fetch-config.sh"
	ssh "$REMOTE_HOST" ./fetch-config.sh
	exit 0
fi

mkdir -p ~/src
pushd ~/src
git clone https://github.com/booxter/nix.git
