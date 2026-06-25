{
  coreutils,
  curl,
  jq,
  lib,
  writeShellApplication,
}:
writeShellApplication {
  name = "audiobookshelf-oidc-bootstrap";
  runtimeInputs = [
    coreutils
    curl
    jq
  ];
  text = ''
    set -euo pipefail

    usage() {
      cat <<'EOF'
    Usage:
      audiobookshelf-oidc-bootstrap --url URL --api-token-file PATH --client-secret-file PATH --settings-file PATH --changed-file PATH
    EOF
    }

    die() {
      echo "audiobookshelf-oidc-bootstrap: $*" >&2
      exit 1
    }

    url=
    api_token_file=
    client_secret_file=
    settings_file=
    changed_file=
    wait_seconds=120

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --url)
          url="''${2:-}"
          shift 2
          ;;
        --api-token-file)
          api_token_file="''${2:-}"
          shift 2
          ;;
        --client-secret-file)
          client_secret_file="''${2:-}"
          shift 2
          ;;
        --settings-file)
          settings_file="''${2:-}"
          shift 2
          ;;
        --changed-file)
          changed_file="''${2:-}"
          shift 2
          ;;
        --wait-seconds)
          wait_seconds="''${2:-}"
          shift 2
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          usage >&2
          die "unknown argument: $1"
          ;;
      esac
    done

    [ -n "$url" ] || die "missing --url"
    [ -n "$api_token_file" ] || die "missing --api-token-file"
    [ -n "$client_secret_file" ] || die "missing --client-secret-file"
    [ -n "$settings_file" ] || die "missing --settings-file"
    [ -n "$changed_file" ] || die "missing --changed-file"
    [ -r "$api_token_file" ] || die "cannot read API token file: $api_token_file"
    [ -r "$client_secret_file" ] || die "cannot read client secret file: $client_secret_file"
    [ -r "$settings_file" ] || die "cannot read settings file: $settings_file"

    mkdir -p "$(dirname "$changed_file")"
    rm -f "$changed_file"

    api_token="$(jq -rRs 'sub("\n$"; "")' < "$api_token_file")"
    header_file="$(mktemp)"
    desired_file="$(mktemp)"
    response_file="$(mktemp)"
    trap 'rm -f "$header_file" "$desired_file" "$response_file"' EXIT

    chmod 0600 "$header_file" "$desired_file" "$response_file"
    printf 'Authorization: Bearer %s\n' "$api_token" > "$header_file"
    jq --rawfile clientSecret "$client_secret_file" \
      '.authOpenIDClientSecret = ($clientSecret | sub("\n$"; ""))' \
      "$settings_file" > "$desired_file"

    deadline=$((SECONDS + wait_seconds))
    while true; do
      status="$(
        curl -sS -o "$response_file" -w '%{http_code}' \
          -H "@$header_file" \
          "$url/api/auth-settings" || true
      )"
      if [ "$status" = 200 ]; then
        break
      fi
      if [ "$status" = 401 ] || [ "$status" = 403 ]; then
        die "Audiobookshelf API token was rejected"
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        die "Audiobookshelf API did not become ready; last HTTP status: $status"
      fi
      sleep 2
    done

    current="$(cat "$response_file")"
    if jq -e --slurpfile desired "$desired_file" \
      '. as $current | all($desired[0] | keys[]; $current[.] == $desired[0][.])' \
      >/dev/null <<< "$current"; then
      echo "Audiobookshelf OIDC settings are already up to date."
      exit 0
    fi

    status="$(
      curl -sS -o "$response_file" -w '%{http_code}' \
        -X PATCH \
        -H "@$header_file" \
        -H "Content-Type: application/json" \
        --data-binary "@$desired_file" \
        "$url/api/auth-settings" || true
    )"
    case "$status" in
      2*) ;;
      *)
        die "failed to update Audiobookshelf OIDC settings; HTTP status: $status"
        ;;
    esac

    touch "$changed_file"
    echo "Updated Audiobookshelf OIDC settings."
  '';

  meta = {
    description = "Configure Audiobookshelf OIDC settings through the app admin API";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "audiobookshelf-oidc-bootstrap";
    platforms = lib.platforms.linux;
  };
}
