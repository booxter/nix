{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.mailer = {
    smtp = {
      host = "smtp.gmail.com";
      port = 587;
      username = "ihar.hrachyshka@gmail.com";
    };
    fromAddress = "ihar.hrachyshka@gmail.com";
  };
}
