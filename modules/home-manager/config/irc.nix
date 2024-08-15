{
  liberachat = {
    nick = "ihrachys";
    server = {
      address = "irc.libera.chat";
      port = 6697;
      autoConnect = true;
    };
    channels = {
      openvswitch.autoJoin = true;
    };
  };
  oftc = {
    nick = "ihrachys";
    server = {
      address = "irc.oftc.net";
      port = 6697;
      autoConnect = true;
    };
    channels = {
      openstack-neutron.autoJoin = true;
      openstack-infra.autoJoin = true;
    };
  };
}
