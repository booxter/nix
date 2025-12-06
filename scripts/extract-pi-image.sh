#!/usr/bin/env bash

set -euo pipefail

if ! [ -e pi5.sd/sd-image ]; then
		echo "No sd-image found, please run 'make pi-image' first"
		exit 1
fi

unzstd -d pi5.sd/sd-image/nixos-*img.zst -o nixos-sd-image.img
