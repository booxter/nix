#!/usr/bin/env bats

setup() {
  selector="apps/package-updates/select-nodejs.py"
  candidates='{"nodejs_20":"20.20.2","nodejs_22":"22.23.1","nodejs_24":"24.18.0","nodejs_26":"26.5.1"}'
}

@test "selects the Node.js line required by an npm x-range" {
  run python3 "$selector" \
    --requirement '22.23.x' \
    --current-attribute nodejs_24 \
    --candidates-json "$candidates"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.attribute' <<< "$output")" = nodejs_22 ]
  [ "$(jq -r '.version' <<< "$output")" = 22.23.1 ]
}

@test "keeps the current Node.js line when it satisfies the engine" {
  run python3 "$selector" \
    --requirement '>=22 <26' \
    --current-attribute nodejs_24 \
    --candidates-json "$candidates"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.attribute' <<< "$output")" = nodejs_24 ]
}

@test "reports when pinned nixpkgs has no compatible Node.js" {
  run python3 "$selector" \
    --requirement '23.x' \
    --current-attribute nodejs_24 \
    --candidates-json "$candidates"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no available nixpkgs Node.js version satisfies"* ]]
}
