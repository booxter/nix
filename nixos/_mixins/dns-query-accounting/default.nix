{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.dnsQueryAccounting;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  stateDir = "/var/lib/observability-dns-query-accounting";
  exportMetrics = pkgs.writeShellApplication {
    name = "dns-query-accounting-export";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnused
      pkgs.jq
      pkgs.libpsl
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      cursor_file="${stateDir}/journal.cursor"
      counts_file="${stateDir}/counts.tsv"
      domain_counts_file="${stateDir}/domain-counts.tsv"
      leases_file="${cfg.leasesFile}"
      tmp_metrics="$(mktemp ${textfileDir}/dns-query-accounting.prom.XXXXXX)"
      tmp_events="$(mktemp ${stateDir}/events.tsv.XXXXXX)"
      tmp_domain_events="$(mktemp ${stateDir}/domain-events.tsv.XXXXXX)"
      tmp_counts="$(mktemp ${stateDir}/counts.tsv.XXXXXX)"
      tmp_domain_counts="$(mktemp ${stateDir}/domain-counts.tsv.XXXXXX)"
      trap 'rm -f "$tmp_metrics" "$tmp_events" "$tmp_domain_events" "$tmp_counts" "$tmp_domain_counts"' EXIT

      escape_label() {
        local value="$1"
        value="''${value//\\/\\\\}"
        value="''${value//\"/\\\"}"
        value="''${value//$'\n'/\\n}"
        printf '%s' "$value"
      }

      normalize_domain() {
        local qname="$1"
        local reg_domain

        qname="''${qname,,}"
        qname="''${qname%.}"

        if [[ -z "$qname" || "$qname" != *.* ]]; then
          return 1
        fi

        case "$qname" in
          *.in-addr.arpa|*.ip6.arpa|*.local|localhost)
            return 1
            ;;
        esac

        reg_domain="$(printf '%s\n' "$qname" | psl --print-reg-domain --batch 2>/dev/null | head -n 1)"
        [[ -n "$reg_domain" ]] || return 1
        printf '%s\n' "$reg_domain"
      }

      mkdir -p "${stateDir}" "${textfileDir}"
      touch "$counts_file"
      touch "$domain_counts_file"

      if [[ ! -s "$cursor_file" ]]; then
        journalctl -u '${cfg.systemdUnit}' -n 0 --show-cursor --no-pager \
          | sed -n 's/^-- cursor: //p' >"$cursor_file"
      else
        new_cursor=""
        while IFS=$'\t' read -r cursor message; do
          domain=""
          new_cursor="$cursor"

          if [[ "$message" =~ ^[0-9]+\ ([^/]+)/[^[:space:]]+\ query\[([^]]+)\]\ ([^[:space:]]+)\ from\ [^[:space:]]+$ ]]; then
            printf 'query\t%s\t%s\t1\n' "''${BASH_REMATCH[1]}" "''${BASH_REMATCH[2]}" >>"$tmp_events"
            if domain="$(normalize_domain "''${BASH_REMATCH[3]}")"; then
              printf 'query\t%s\t1\n' "$domain" >>"$tmp_domain_events"
            fi
          elif [[ "$message" =~ ^[0-9]+\ ([^/]+)/[^[:space:]]+\ forwarded\ ([^[:space:]]+)\ to\ [^[:space:]]+$ ]]; then
            printf 'forwarded\t%s\t-\t1\n' "''${BASH_REMATCH[1]}" >>"$tmp_events"
            if domain="$(normalize_domain "''${BASH_REMATCH[2]}")"; then
              printf 'forwarded\t%s\t1\n' "$domain" >>"$tmp_domain_events"
            fi
          fi
        done < <(
          journalctl -u '${cfg.systemdUnit}' --after-cursor "$(<"$cursor_file")" -o json --no-pager \
            | jq -r 'select(.MESSAGE != null) | [."__CURSOR", .MESSAGE] | @tsv'
        )

        if [[ -n "$new_cursor" ]]; then
          printf '%s\n' "$new_cursor" >"$cursor_file"
        fi

        awk -F '\t' '
          BEGIN { OFS = "\t" }
          FNR == NR {
            if (NF == 4) {
              counts[$1 OFS $2 OFS $3] = $4
            }
            next
          }
          NF == 4 {
            key = $1 OFS $2 OFS $3
            counts[key] += $4
          }
          END {
            for (key in counts) {
              print key, counts[key]
            }
          }
        ' "$counts_file" "$tmp_events" | sort >"$tmp_counts"

        mv "$tmp_counts" "$counts_file"
        : >"$tmp_counts"

        awk -F '\t' '
          BEGIN { OFS = "\t" }
          FNR == NR {
            if (NF == 3) {
              counts[$1 OFS $2] = $3
            }
            next
          }
          NF == 3 {
            key = $1 OFS $2
            counts[key] += $3
          }
          END {
            for (key in counts) {
              print key, counts[key]
            }
          }
        ' "$domain_counts_file" "$tmp_domain_events" | sort >"$tmp_domain_counts"

        mv "$tmp_domain_counts" "$domain_counts_file"
        : >"$tmp_domain_counts"
      fi

      declare -A client_name_by_ip=()
      declare -A client_mac_by_ip=()
      declare -A client_seen_by_ip=()

      if [[ -f "$leases_file" ]]; then
        while read -r _expiry mac ip name _client_id; do
          [[ -z "$ip" ]] && continue
          client_seen_by_ip["$ip"]=1
          if [[ -n "$name" && "$name" != "*" ]]; then
            client_name_by_ip["$ip"]="$name"
          fi
          if [[ -n "$mac" && "$mac" != "*" ]]; then
            client_mac_by_ip["$ip"]="$mac"
          fi
        done <"$leases_file"
      fi

      {
        printf '%s\n' '# HELP host_observability_dns_client_info Current dnsmasq lease metadata by client IP.'
        printf '%s\n' '# TYPE host_observability_dns_client_info gauge'
        for ip in "''${!client_seen_by_ip[@]}"; do
          name="$(escape_label "''${client_name_by_ip[$ip]:-unknown}")"
          mac="$(escape_label "''${client_mac_by_ip[$ip]:-unknown}")"
          printf 'host_observability_dns_client_info{client_ip="%s",client_name="%s",client_mac="%s"} 1\n' \
            "$(escape_label "$ip")" "$name" "$mac"
        done

        printf '%s\n' '# HELP host_observability_dns_client_queries_total DNS queries observed in dnsmasq logs by client IP, known lease name, and query type.'
        printf '%s\n' '# TYPE host_observability_dns_client_queries_total counter'
        printf '%s\n' '# HELP host_observability_dns_client_forwarded_total DNS queries forwarded upstream by dnsmasq by client IP and known lease name.'
        printf '%s\n' '# TYPE host_observability_dns_client_forwarded_total counter'
        printf '%s\n' '# HELP host_observability_dns_domain_queries_total DNS queries observed in dnsmasq logs by normalized eTLD+1 domain.'
        printf '%s\n' '# TYPE host_observability_dns_domain_queries_total counter'
        printf '%s\n' '# HELP host_observability_dns_domain_forwarded_total DNS queries forwarded upstream by dnsmasq by normalized eTLD+1 domain.'
        printf '%s\n' '# TYPE host_observability_dns_domain_forwarded_total counter'

        while IFS=$'\t' read -r kind ip qtype count; do
          [[ -z "$kind" || -z "$ip" || -z "$count" ]] && continue
          raw_name="''${client_name_by_ip[$ip]:-unknown}"
          name="$(escape_label "$raw_name")"
          ip_label="$(escape_label "$ip")"

          if [[ "$kind" == "query" ]]; then
            printf 'host_observability_dns_client_queries_total{client_ip="%s",client_name="%s",qtype="%s"} %s\n' \
              "$ip_label" "$name" "$(escape_label "$qtype")" "$count"
          elif [[ "$kind" == "forwarded" ]]; then
            printf 'host_observability_dns_client_forwarded_total{client_ip="%s",client_name="%s"} %s\n' \
              "$ip_label" "$name" "$count"
          fi
        done <"$counts_file"

        while IFS=$'\t' read -r kind domain count; do
          [[ -z "$kind" || -z "$domain" || -z "$count" ]] && continue
          domain_label="$(escape_label "$domain")"

          if [[ "$kind" == "query" ]]; then
            printf 'host_observability_dns_domain_queries_total{domain="%s"} %s\n' \
              "$domain_label" "$count"
          elif [[ "$kind" == "forwarded" ]]; then
            printf 'host_observability_dns_domain_forwarded_total{domain="%s"} %s\n' \
              "$domain_label" "$count"
          fi
        done <"$domain_counts_file"
      } >"$tmp_metrics"

      chmod 0644 "$tmp_metrics"
      mv "$tmp_metrics" ${textfileDir}/dns-query-accounting.prom
      trap - EXIT
    '';
  };
in
{
  options.host.observability.dnsQueryAccounting = {
    enable = lib.mkEnableOption "dnsmasq per-client DNS accounting for Prometheus";

    leasesFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/dnsmasq/dnsmasq.leases";
      description = "Path to the dnsmasq lease file used to enrich client IPs with hostnames.";
    };

    systemdUnit = lib.mkOption {
      type = lib.types.str;
      default = "dnsmasq.service";
      description = "Systemd unit to read dnsmasq query logs from.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = "How often to refresh DNS client accounting metrics.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = lib.mkIf (!config.host.observability.lanWan.enable) {
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
    };

    systemd.tmpfiles.rules =
      lib.optional (!config.host.observability.lanWan.enable) "d ${textfileDir} 0755 root root - -"
      ++ [
        "d ${stateDir} 0755 root root - -"
      ];

    systemd.services.observability-dns-query-accounting = {
      description = "Export per-client dnsmasq accounting metrics for node exporter";
      after = [ cfg.systemdUnit ];
      requires = [ cfg.systemdUnit ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe exportMetrics;
      };
    };

    systemd.timers.observability-dns-query-accounting = {
      description = "Refresh per-client dnsmasq accounting metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.interval;
        Unit = "observability-dns-query-accounting.service";
      };
    };
  };
}
