{ config, lib }:
let
  radarr = config.host.radarr;
  controller = if radarr == null then null else radarr.repair.controller;
  planner = config.host.mediaRepair.planner;
  worker = config.host.mediaRepair.worker;
  registeredDownloadClients = config.host.downloads.clients or { };
  selectedDownloadClientNames =
    if controller == null then
      [ ]
    else
      builtins.filter (name: builtins.hasAttr name registeredDownloadClients) controller.downloadClients;
  selectedDownloadClients = map (name: registeredDownloadClients.${name}) selectedDownloadClientNames;
  downloadClient =
    implementation:
    lib.findFirst (client: client.implementation == implementation) null selectedDownloadClients;
in
{
  inherit
    controller
    planner
    radarr
    registeredDownloadClients
    selectedDownloadClientNames
    selectedDownloadClients
    worker
    ;

  transmission = downloadClient "transmission";
  sabnzbd = downloadClient "sabnzbd";
}
