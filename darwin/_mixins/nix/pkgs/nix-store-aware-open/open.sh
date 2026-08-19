#!/bin/bash
set -euo pipefail

chmod_command=@chmod@
cp_command=@cp@
mkdir_command=@mkdir@
mv_command=@mv@
realpath_command=@realpath@
rm_command=@rm@
system_open=@open@

copy_store_app() {
  local source=$1
  local canonical
  local destination
  local destination_parent
  local remainder
  local staging
  local store_path

  if [[ ! -d $source ]]; then
    printf '%s\n' "$source"
    return
  fi

  if ! canonical=$("$realpath_command" "$source" 2>/dev/null); then
    printf '%s\n' "$source"
    return
  fi

  if [[ $canonical != /nix/store/* ]] || [[ $canonical != *.app ]]; then
    printf '%s\n' "$source"
    return
  fi

  remainder=${canonical#/nix/store/}
  store_path=${remainder%%/*}
  if [[ $remainder == "$store_path" ]]; then
    remainder=${canonical##*/}
  else
    remainder=${remainder#*/}
  fi

  destination="${TMPDIR:-/tmp}"
  destination="${destination%/}/nix-open-apps/$store_path/$remainder"
  destination_parent=${destination%/*}

  if [[ ! -d $destination ]]; then
    "$mkdir_command" -p "$destination_parent"
    staging="$destination_parent/.${destination##*/}.$$.tmp"
    trap '"$rm_command" -rf "$staging"' RETURN
    "$cp_command" -R --no-preserve=xattr "$canonical" "$staging"
    "$chmod_command" -R u+w "$staging"
    "$mv_command" -n "$staging" "$destination"
    "$rm_command" -rf "$staging"
    trap - RETURN
  fi

  printf '%s\n' "$destination"
}

args=("$@")
explicit_handler=false

for ((index = 0; index < ${#args[@]}; index++)); do
  case ${args[index]} in
    --args)
      break
      ;;
    -a | -b)
      explicit_handler=true
      ((index += 1))
      ;;
    -e | -t | -h | -R | --reveal)
      explicit_handler=true
      ;;
    --arch | -s | -u | --url | -i | --stdin | -o | --stdout | --stderr | --env)
      ((index += 1))
      ;;
  esac
done

for ((index = 0; index < ${#args[@]}; index++)); do
  case ${args[index]} in
    --args)
      break
      ;;
    -a)
      ((index += 1))
      if ((index < ${#args[@]})); then
        args[index]=$(copy_store_app "${args[index]}")
      fi
      ;;
    --arch | -b | -s | -u | --url | -i | --stdin | -o | --stdout | --stderr | --env)
      ((index += 1))
      ;;
    -*) ;;
    *)
      if [[ $explicit_handler == false ]]; then
        args[index]=$(copy_store_app "${args[index]}")
      fi
      ;;
  esac
done

exec "$system_open" "${args[@]}"
