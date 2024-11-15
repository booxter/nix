{ pkgs, ... }: with pkgs; writeShellScriptBin "meetings" ''
  ### Expected output format:
  # <URL> <MEETING-NAME>

  videoServices=("meet.google.com" "kaltura.com")
  calendarName="ihrachys@redhat.com"
  configDir="~/.gcalcli-rh"


  # Use current date if not passed through envVar
  if [ "x" = "x$DATE" ]; then
    if [ ! $# -eq 1 ]; then
      DATE=$(${coreutils}/bin/date "+%Y-%m-%d")
    else
      DATE=$1
    fi
  fi

  function join_by {
    local d=''${1-} f=''${2-}
    if shift 2; then
      printf %s "$f" "''${@/#/$d}"
    fi
  }

  sanitize() {
    sed=${gnused}/bin/sed
    $sed "s/[\/|]/~/g" | $sed "s/:/-/g"
  }

  # This assumed a particular order in the output of gcalcli; may break at one point if they ever change it!
  name() {
    echo $1 | ${gawk}/bin/awk -v FS='\t' -v OFS='\t' '{print $7}' | sanitize
  }

  # Filter out meetings with no expected URLs for services that I expect to be served through video
  url() {
    echo "$1" | ${gnugrep}/bin/grep -Po "https://($(join_by "|" $videoServices))[^\t]+"
  }

  meetings=$(\
    ${gcalcli}/bin/gcalcli --config-folder $configDir --calendar $calendarName \
        agenda "$DATE 00:00" "$DATE 23:59" \
        --detail conference \
        --tsv \
        --nodeclined |\
    ${coreutils}/bin/tail -n +2) # truncate the table header line

  IFS=$'\n'
  for m in $meetings; do
    IFS=$' '
    url=$(url "$m")
    if [ "x" != "x$url" ]; then
      echo $(url "$m") $(name "$m")
    fi
  done
''
