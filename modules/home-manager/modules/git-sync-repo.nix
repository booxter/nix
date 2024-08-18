{ lib, pkgs, gh-repo, destdir, ... }: lib.hm.dag.entryAfter ["writeBoundary"] ''
  GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh ${pkgs.git}/bin/git clone git@github.com:${gh-repo}.git ${destdir} || true
  pushd ${destdir} && ${pkgs.git}/bin/git config --bool branch.master.sync true && ${pkgs.git}/bin/git config --bool branch.master.syncNewFiles true && popd
  ''
