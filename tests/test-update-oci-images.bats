#!/usr/bin/env bats

setup() {
  export TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$TEST_BIN"
  export PATH="${TEST_BIN}:${PATH}"

  {
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
set -euo pipefail

if [[ "$1" == "list-tags" && "$2" == "docker://docker.io/example/romm" ]]; then
  cat <<'JSON'
{
  "Tags": [
    "latest",
    "4.9.1",
    "4.10.0",
    "4.10.0-beta.1",
    "5"
  ]
}
JSON
  exit 0
fi

if [[ "$1" == "inspect" && "$2" == "--config" ]]; then
  case "$3" in
    docker://docker.io/example/romm@sha256:old)
      revision="oldrev"
      ;;
    docker://docker.io/example/romm@sha256:new)
      revision="newrev"
      ;;
    *)
      echo "unexpected skopeo inspect ref: $3" >&2
      exit 1
      ;;
  esac
  jq -n --arg revision "$revision" '{
    config: {
      Labels: {
        "org.opencontainers.image.source": "https://github.com/example/romm",
        "org.opencontainers.image.revision": $revision
      }
    }
  }'
  exit 0
fi

if [[ "$1" != "list-tags" || "$2" != "docker://docker.io/example/romm" ]]; then
  echo "unexpected skopeo args: $*" >&2
  exit 1
fi
EOF
  } > "${TEST_BIN}/skopeo"
  chmod +x "${TEST_BIN}/skopeo"

  {
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
set -euo pipefail

image_name=""
image_tag=""
final_image_name=""
final_image_tag=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --image-name)
      image_name="$2"
      shift 2
      ;;
    --image-tag)
      image_tag="$2"
      shift 2
      ;;
    --final-image-name)
      final_image_name="$2"
      shift 2
      ;;
    --final-image-tag)
      final_image_tag="$2"
      shift 2
      ;;
    --json | --quiet | --os | --arch)
      if [[ "$1" == "--os" || "$1" == "--arch" ]]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      echo "unexpected nix-prefetch-docker arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$image_name" != "docker.io/example/romm" || "$image_tag" != "4.10.0" ]]; then
  echo "unexpected nix-prefetch-docker image: ${image_name}:${image_tag}" >&2
  exit 1
fi

jq -n \
  --arg imageName "$image_name" \
  --arg finalImageName "$final_image_name" \
  --arg finalImageTag "$final_image_tag" \
  '{
    imageName: $imageName,
    imageDigest: "sha256:new",
    hash: "sha256-newhash",
    finalImageName: $finalImageName,
    finalImageTag: $finalImageTag
  }'
EOF
  } > "${TEST_BIN}/nix-prefetch-docker"
  chmod +x "${TEST_BIN}/nix-prefetch-docker"
}

@test "updates selected OCI image tag from registry tags" {
  pins_file="${BATS_TEST_TMPDIR}/oci-images.json"
  summary_file="${BATS_TEST_TMPDIR}/summary.md"
  cat > "$pins_file" <<'JSON'
{
  "other": {
    "image": "docker.io/example/other",
    "tag": "1.0.0",
    "digest": "sha256:other",
    "hash": "sha256-otherhash",
    "tagRegex": "^[0-9]+\\.[0-9]+\\.[0-9]+$"
  },
  "romm": {
    "image": "docker.io/example/romm",
    "tag": "4.9.1",
    "digest": "sha256:old",
    "hash": "sha256-oldhash",
    "tagRegex": "^[0-9]+\\.[0-9]+\\.[0-9]+$",
    "changelog": "https://example.invalid/releases/{tag}"
  }
}
JSON

  run bash apps/package-updates/update-oci-images.sh \
    --pins-file "$pins_file" \
    --summary-file "$summary_file" \
    --target romm

  if [ "$status" -ne 0 ]; then
    printf 'status: %s\n%s\n' "$status" "$output" >&3
    return 1
  fi
  [ "$(jq -r '.romm.tag' "$pins_file")" = "4.10.0" ]
  [ "$(jq -r '.romm.digest' "$pins_file")" = "sha256:new" ]
  [ "$(jq -r '.romm.hash' "$pins_file")" = "sha256-newhash" ]
  [ "$(jq -r '.other.tag' "$pins_file")" = "1.0.0" ]
  [ "$(jq -r '.other.digest' "$pins_file")" = "sha256:other" ]
  [ "$(jq -r '.other.hash' "$pins_file")" = "sha256-otherhash" ]
  grep -F '| `romm` | `docker.io/example/romm` | `4.9.1 -> 4.10.0` | `sha256:old -> sha256:new` | `sha256-oldhash -> sha256-newhash` | [link](https://example.invalid/releases/4.10.0) | [compare](https://github.com/example/romm/compare/oldrev...newrev) |' "$summary_file"
}

@test "updates selected OCI image digest when tag is unchanged" {
  pins_file="${BATS_TEST_TMPDIR}/oci-images.json"
  summary_file="${BATS_TEST_TMPDIR}/summary.md"
  cat > "$pins_file" <<'JSON'
{
  "romm": {
    "image": "docker.io/example/romm",
    "tag": "4.10.0",
    "digest": "sha256:old",
    "hash": "sha256-oldhash",
    "tagRegex": "^[0-9]+\\.[0-9]+\\.[0-9]+$",
    "changelog": "https://example.invalid/releases/{tag}"
  }
}
JSON

  run bash apps/package-updates/update-oci-images.sh \
    --pins-file "$pins_file" \
    --summary-file "$summary_file" \
    --target romm

  if [ "$status" -ne 0 ]; then
    printf 'status: %s\n%s\n' "$status" "$output" >&3
    return 1
  fi
  [ "$(jq -r '.romm.tag' "$pins_file")" = "4.10.0" ]
  [ "$(jq -r '.romm.digest' "$pins_file")" = "sha256:new" ]
  [ "$(jq -r '.romm.hash' "$pins_file")" = "sha256-newhash" ]
  grep -F '| `romm` | `docker.io/example/romm` | `4.10.0` | `sha256:old -> sha256:new` | `sha256-oldhash -> sha256-newhash` | [link](https://example.invalid/releases/4.10.0) | not set |' "$summary_file"
}

@test "lists OCI image targets" {
  pins_file="${BATS_TEST_TMPDIR}/oci-images.json"
  cat > "$pins_file" <<'JSON'
{
  "romm": {
    "image": "docker.io/example/romm",
    "tag": "4.9.1",
    "digest": "sha256:old",
    "hash": "sha256-oldhash"
  }
}
JSON

  run bash apps/package-updates/update-oci-images.sh \
    --pins-file "$pins_file" \
    --list-targets

  [ "$status" -eq 0 ]
  [ "$output" = $'romm\tdocker.io/example/romm:4.9.1' ]
}
