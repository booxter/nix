{ ... } : {
  # TODO: use launchd.user.agents.iterm2.serviceConfig instead?
  environment.userLaunchAgents.iterm2 = {
    source = ./iterm2-login.plist;
    target = "iterm2.plist";
  };
}
