{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.mailer = {
    relayHost = "smtp.gmail.com";
    relayPort = 587;
    address = "ihar.hrachyshka@gmail.com";
  };
}
