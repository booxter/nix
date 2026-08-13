{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      facts
      lib
      outputs
      pkgs
      ;
  };
  inherit (model) cfg state;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.romm = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      internal.path = "/api";
      public = {
        enable = cfg.publicHostName != null;
        hostName = cfg.publicHostName;
      };
      health.frontend = {
        enable = cfg.publicHostName != null;
        path = "/api/heartbeat";
      };
      displayName = "RomM";
      dashboard = {
        enable = true;
        section = "user";
      };
    };

    systemd.services.nginx = lib.mkIf model.ready {
      wants = [ "romm-web-assets.service" ];
      after = [ "romm-web-assets.service" ];
    };

    services.nginx = lib.mkIf model.ready {
      additionalModules = with pkgs.nginxModules; [
        njs
        zip
      ];
      commonHttpConfig = ''
        js_import ${state.nginxDir}/decode.js;

        map $request_uri $romm_coep_header {
            default "";
            ~^/rom/.*/ejs$ "require-corp";
            ~^/console/rom/[0-9]+/play "require-corp";
        }

        map $request_uri $romm_coop_header {
            default "";
            ~^/rom/.*/ejs$ "same-origin";
            ~^/console/rom/[0-9]+/play "same-origin";
        }

        # RomM resources are authenticated, so retain the upstream cache policy
        # while limiting stored responses to the end user's private cache.
        map $args $romm_resources_cache_control {
            default "private, max-age=3600, must-revalidate";
            "~(^|&)(ts|v)=" "private, max-age=31536000, immutable";
        }
      '';
      virtualHosts."internal-https-romm" = {
        root = state.webDir;
        locations = {
          "/" = {
            tryFiles = "$uri $uri/ /index.html";
            extraConfig = ''
              proxy_redirect off;
              add_header Cache-Control "no-cache";
              add_header Access-Control-Allow-Origin *;
              add_header Access-Control-Allow-Methods *;
              add_header Access-Control-Allow-Headers *;
              add_header Cross-Origin-Embedder-Policy $romm_coep_header;
              add_header Cross-Origin-Opener-Policy $romm_coop_header;
            '';
          };
          "/assets/romm/resources/" = {
            extraConfig = ''
              # Covers and screenshots describe the private library. Reuse
              # RomM's session/API-token validation before serving from disk.
              auth_request /_romm_auth;
              alias ${model.basePath}/resources/;
              add_header Cache-Control $romm_resources_cache_control;
            '';
          };
          "/assets" = {
            tryFiles = "$uri $uri/ =404";
            extraConfig = ''
              add_header Cache-Control "public, max-age=3600, must-revalidate";
            '';
          };
          "~* \"^/assets/[^/]+-[A-Za-z0-9_-]{8,}\\.(js|mjs|css|map|woff2?|ttf|otf|eot|svg|png|jpe?g|gif|webp|avif|ico|json|wasm)$\"" =
            {
              tryFiles = "$uri $uri/ =404";
              extraConfig = ''
                add_header Cache-Control "public, max-age=31536000, immutable";
              '';
            };
          "= /_romm_auth" = {
            proxyPass = "http://127.0.0.1:${toString cfg.port}/api/users/me";
            extraConfig = ''
              internal;
              proxy_set_header Content-Length "";
              proxy_pass_request_body off;
            '';
          };
          "= /openapi.json" = {
            return = "404";
          };
          "/api".extraConfig = ''
            proxy_request_buffering off;
            proxy_buffering off;
            proxy_read_timeout 300s;
          '';
          "~ ^/(ws|netplay)" = {
            proxyPass = "http://127.0.0.1:${toString cfg.port}";
            proxyWebsockets = true;
          };
          "/library/".extraConfig = ''
            internal;
            alias ${model.basePath}/library/;
          '';
          "/cache/".extraConfig = ''
            # RomM redirects resumable multi-file downloads here after
            # assembling the ZIP in its cache.
            internal;
            alias ${model.basePath}/cache/;
          '';
          "/decode".extraConfig = ''
            internal;
            js_content decode.decodeBase64;
          '';
        };
      };
    };
  };
}
