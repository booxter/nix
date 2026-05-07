{
  lib,
  writeShellApplication,
  coreutils,
  ffmpeg,
  gnused,
}:
writeShellApplication {
  name = "join-media-parts";
  runtimeInputs = [
    coreutils
    ffmpeg
    gnused
  ];
  text = ''
    set -euo pipefail

    usage() {
      cat <<'EOF'
    Usage: join-media-parts [--ext ts|mp4|mkv] [directory] [output.{mkv,mp4,ts}]

    Join ordered media parts in a directory into one file.

    Supported inputs:
      - numbered .ts parts
      - ordered .mp4 parts
      - ordered .mkv parts

    Defaults:
      directory = current directory
      output for .ts  = <directory-basename>.mkv
      output for .mp4 = <directory-basename>.mp4
      output for .mkv = <directory-basename>.mkv

    Examples:
      join-media-parts
      join-media-parts /media/torrents/radarr/Release.Name
      join-media-parts --ext mp4 '/media/torrents/radarr/Succubus(neew)'
      join-media-parts /media/torrents/radarr/Release.Name /media/torrents/radarr/Release.Name.ts
    EOF
    }

    input_ext=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --help)
          usage
          exit 0
          ;;
        --ext)
          if [ "$#" -lt 2 ]; then
            echo "--ext requires a value" >&2
            exit 1
          fi
          input_ext="''${2,,}"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        -*)
          echo "unknown option: $1" >&2
          usage >&2
          exit 1
          ;;
        *)
          break
          ;;
      esac
    done

    if [ "$#" -gt 2 ]; then
      usage >&2
      exit 1
    fi

    input_dir="''${1:-.}"
    if [ ! -d "$input_dir" ]; then
      echo "input directory not found: $input_dir" >&2
      exit 1
    fi
    input_dir="$(realpath "$input_dir")"

    discover_ext() {
      local ext
      local files
      local candidates=()
      for ext in ts mp4 mkv; do
        shopt -s nullglob nocaseglob
        files=( "$input_dir"/*."$ext" )
        shopt -u nullglob nocaseglob
        if [ "''${#files[@]}" -ge 2 ]; then
          candidates+=( "$ext" )
        fi
      done

      case "''${#candidates[@]}" in
        0)
          echo "could not find at least two matching .ts, .mp4, or .mkv files in $input_dir" >&2
          exit 1
          ;;
        1)
          input_ext="''${candidates[0]}"
          ;;
        *)
          printf 'multiple candidate extensions found in %s: %s\n' "$input_dir" "''${candidates[*]}" >&2
          echo "rerun with --ext <ts|mp4|mkv>" >&2
          exit 1
          ;;
      esac
    }

    if [ -z "$input_ext" ]; then
      discover_ext
    fi

    case "$input_ext" in
      ts|mp4|mkv) ;;
      *)
        echo "unsupported input extension: $input_ext" >&2
        exit 1
        ;;
    esac

    shopt -s nullglob nocaseglob
    part_files=( "$input_dir"/*."$input_ext" )
    shopt -u nullglob nocaseglob

    if [ "''${#part_files[@]}" -lt 2 ]; then
      echo "need at least two .$input_ext files in $input_dir" >&2
      exit 1
    fi

    mapfile -t part_files < <(printf '%s\n' "''${part_files[@]}" | sort -V)

    if [ "$#" -ge 2 ]; then
      output_path="$2"
    else
      case "$input_ext" in
        ts) output_ext="mkv" ;;
        mp4) output_ext="mp4" ;;
        mkv) output_ext="mkv" ;;
      esac
      output_path="$input_dir/$(basename "$input_dir").$output_ext"
    fi

    if [ -e "$output_path" ]; then
      echo "output already exists: $output_path" >&2
      exit 1
    fi

    tmp_dir="$(mktemp -d "$input_dir/.join-media-parts.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT

    echo "joining ''${#part_files[@]} .$input_ext parts from $input_dir"
    printf '  %s\n' "''${part_files[@]}"

    write_concat_file() {
      local destination="$1"
      shift

      : > "$destination"
      for part_file in "$@"; do
        case "$part_file" in
          *"'"*)
            echo "filenames containing single quotes are not supported: $part_file" >&2
            exit 1
            ;;
        esac
        printf "file '%s'\n" "$part_file" >> "$destination"
      done
    }

    remux_ts_streams() {
      local output_path="$1"
      local output_ext="$2"
      shift 2
      local -a input_args=( "$@" )
      local stream_index=""
      local codec_type=""
      local codec_name=""
      local -a selected_maps=()
      local -a av_maps=()
      local -a skipped_streams=()

      while IFS=, read -r stream_index codec_name codec_type; do
        [ -n "$stream_index" ] || continue
        case "$codec_type" in
          video|audio)
            selected_maps+=( -map "0:$stream_index" )
            av_maps+=( -map "0:$stream_index" )
            ;;
          subtitle)
            case "$output_ext:$codec_name" in
              mkv:dvb_teletext|mp4:*)
                skipped_streams+=( "$codec_type stream $stream_index ($codec_name)" )
                ;;
              *)
                selected_maps+=( -map "0:$stream_index" )
                ;;
            esac
            ;;
          *)
            skipped_streams+=( "$codec_type stream $stream_index ($codec_name)" )
            ;;
        esac
      done < <(
        ffprobe -hide_banner -loglevel error \
          -show_entries stream=index,codec_type,codec_name \
          -of csv=p=0 \
          "''${input_args[@]}"
      )

      if [ "''${#av_maps[@]}" -eq 0 ]; then
        echo "could not find any audio or video streams in input TS parts" >&2
        exit 1
      fi

      if [ "''${#skipped_streams[@]}" -gt 0 ]; then
        printf 'skipping incompatible streams for .%s output:\n' "$output_ext" >&2
        printf '  %s\n' "''${skipped_streams[@]}" >&2
      fi

      if ffmpeg -hide_banner -loglevel warning -y \
        "''${input_args[@]}" \
        "''${selected_maps[@]}" \
        -c copy \
        "$output_path"
      then
        return 0
      fi

      if [ "''${#selected_maps[@]}" -eq "''${#av_maps[@]}" ]; then
        return 1
      fi

      echo "remux failed with subtitle streams; retrying with video/audio streams only" >&2
      ffmpeg -hide_banner -loglevel warning -y \
        "''${input_args[@]}" \
        "''${av_maps[@]}" \
        -c copy \
        "$output_path"
    }

    output_ext="''${output_path##*.}"
    output_ext="''${output_ext,,}"

    if [ "$input_ext" = "ts" ]; then
      case "$output_ext" in
        ts)
          joined_ts="$tmp_dir/joined.ts"
          cat "''${part_files[@]}" > "$joined_ts"
          mv "$joined_ts" "$output_path"
          ;;
        mkv|mp4)
          concat_file="$tmp_dir/concat.txt"
          write_concat_file "$concat_file" "''${part_files[@]}"
          remux_ts_streams "$output_path" "$output_ext" -f concat -safe 0 -i "$concat_file"
          ;;
        *)
          echo "unsupported output extension for TS input: .$output_ext (expected .mkv, .mp4, or .ts)" >&2
          exit 1
          ;;
      esac
    else
      normalized_dir="$tmp_dir/normalized"
      mkdir -p "$normalized_dir"
      normalized_files=()

      for idx in "''${!part_files[@]}"; do
        part_file="''${part_files[$idx]}"
        normalized_part="$normalized_dir/$(printf '%04d.mkv' "$((idx + 1))")"
        echo "normalizing timestamps for $(basename "$part_file")"
        ffmpeg -hide_banner -loglevel warning -y \
          -fflags +genpts+igndts \
          -i "$part_file" \
          -map 0 \
          -c copy \
          -avoid_negative_ts make_zero \
          "$normalized_part"
        normalized_files+=( "$normalized_part" )
      done

      concat_file="$tmp_dir/concat.txt"
      write_concat_file "$concat_file" "''${normalized_files[@]}"

      case "$output_ext" in
        mkv|mp4)
          ffmpeg -hide_banner -loglevel warning -y -f concat -safe 0 -i "$concat_file" -map 0 -c copy "$output_path"
          ;;
        *)
          echo "unsupported output extension for .$input_ext input: .$output_ext (expected .mkv or .mp4)" >&2
          exit 1
          ;;
      esac
    fi

    echo "wrote $output_path"
  '';
  meta = {
    description = "Join ordered TS/MP4/MKV media parts into one file";
    mainProgram = "join-media-parts";
    platforms = lib.platforms.unix;
  };
}
