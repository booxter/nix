{ pkgs, ... }: with pkgs; writeShellScriptBin "openstack-logs" ''
  if [ "$#" -ne 1 ]; then
      echo "Usage: $0 URL"
  		exit 1
  fi
  
  URL=$1
  DOWNLOAD_SCRIPT=download-logs.sh
  
  function get_base_url() {
      echo "$''\{1%/*}"
  }
  
  pushd $TMPDIR
  
  curl $(get_base_url $URL)/$DOWNLOAD_SCRIPT -o $DOWNLOAD_SCRIPT
  
  # Remove after https://review.opendev.org/c/zuul/zuul-jobs/+/934665 merges
  ${gnused}/bin/sed -i 's|#!/bin/bash|#!/usr/bin/env bash|' $DOWNLOAD_SCRIPT
  
  chmod +x $DOWNLOAD_SCRIPT
  ./$DOWNLOAD_SCRIPT
  
  popd
''
