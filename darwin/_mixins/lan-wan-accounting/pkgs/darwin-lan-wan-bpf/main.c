#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <inttypes.h>
#include <net/if_dl.h>
#include <pcap/pcap.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_INTERFACE "en0"
#define DEFAULT_LAN_CIDR "192.168.0.0/16"
#define DEFAULT_LAN6_CIDR "fe80::/10"
#define DEFAULT_PROMETHEUS_METRIC "host_observability_network_bpf_bytes_total"
#define DEFAULT_TEXTFILE_METRIC "host_observability_network_bytes_total"
#define DEFAULT_TEXTFILE_RATE_METRIC "host_observability_network_bytes_per_second"
#define ETH_ADDR_LEN 6
#define ETH_HEADER_LEN 14
#define ETHERTYPE_IPV4 0x0800
#define ETHERTYPE_IPV6 0x86dd
#define ETHERTYPE_VLAN 0x8100
#define ETHERTYPE_QINQ 0x88a8
#define ETHERTYPE_VLAN_OLD 0x9100
#define IPV4_MIN_HEADER_LEN 20
#define IPV6_HEADER_LEN 40
#define MAX_CIDRS 32
#define MAX_INTERFACES 16
#define INTERFACE_LABEL_LEN 256
#define INTERFACE_RETRY_SECONDS 5

enum direction {
  DIR_RECEIVE = 0,
  DIR_TRANSMIT = 1,
  DIR_COUNT = 2,
};

enum scope {
  SCOPE_LAN = 0,
  SCOPE_WAN = 1,
  SCOPE_COUNT = 2,
};

enum output_format {
  OUTPUT_HUMAN = 0,
  OUTPUT_PROMETHEUS = 1,
  OUTPUT_TEXTFILE = 2,
};

struct cidr {
  uint32_t network;
  uint32_t mask;
  char text[64];
};

struct cidr6 {
  uint8_t network[16];
  uint8_t mask[16];
  char text[96];
};

struct counters {
  uint64_t bytes[DIR_COUNT][SCOPE_COUNT];
  uint64_t packets[DIR_COUNT][SCOPE_COUNT];
  uint64_t ignored_not_ip;
  uint64_t ignored_not_self;
  uint64_t ignored_short;
};

struct context;

struct capture_interface {
  const char *name;
  uint8_t mac[ETH_ADDR_LEN];
  pcap_t *pcap;
  struct context *ctx;
  time_t next_retry;
  time_t next_health_check;
  bool retrying;
};

struct capture_operations {
  bool (*get_interface_mac)(const char *interface, uint8_t out[ETH_ADDR_LEN],
                            bool report_missing);
  bool (*open_capture_interface)(struct capture_interface *iface,
                                 bool report_errors);
  void (*close_capture_interface)(struct capture_interface *iface);
  int (*get_selectable_fd)(pcap_t *pcap);
  int (*dispatch)(pcap_t *pcap, int packet_count, pcap_handler callback,
                  u_char *user);
  const char *(*get_error)(pcap_t *pcap);
};

struct context {
  struct capture_interface interfaces[MAX_INTERFACES];
  size_t interface_count;
  char interface_label[INTERFACE_LABEL_LEN];
  struct cidr cidrs[MAX_CIDRS];
  size_t cidr_count;
  struct cidr6 cidrs6[MAX_CIDRS];
  size_t cidr6_count;
  unsigned print_interval_seconds;
  uint64_t max_accounted_packets;
  uint64_t accounted_packets;
  enum output_format output_format;
  const char *textfile_path;
  const char *metric_name;
  bool metric_name_set;
  struct counters counters;
};

static volatile sig_atomic_t stop_requested = 0;

static void request_stop(int signo) {
  (void)signo;
  stop_requested = 1;
}

static uint16_t read_be16(const uint8_t *p) {
  return ((uint16_t)p[0] << 8) | (uint16_t)p[1];
}

static uint32_t read_be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static bool parse_uint(const char *text, unsigned *out) {
  char *end = NULL;
  errno = 0;
  unsigned long value = strtoul(text, &end, 10);

  if (errno != 0 || end == text || *end != '\0' || value > UINT32_MAX) {
    return false;
  }

  *out = (unsigned)value;
  return true;
}

static bool parse_uint64(const char *text, uint64_t *out) {
  char *end = NULL;
  errno = 0;
  unsigned long long value = strtoull(text, &end, 10);

  if (errno != 0 || end == text || *end != '\0') {
    return false;
  }

  *out = (uint64_t)value;
  return true;
}

static bool parse_cidr(const char *text, struct cidr *out) {
  char address_text[64];
  const char *slash = strchr(text, '/');
  unsigned prefix = 32;

  if (slash == NULL) {
    if (strlen(text) >= sizeof(address_text)) {
      return false;
    }
    strcpy(address_text, text);
  } else {
    size_t address_len = (size_t)(slash - text);

    if (address_len == 0 || address_len >= sizeof(address_text)) {
      return false;
    }

    memcpy(address_text, text, address_len);
    address_text[address_len] = '\0';

    if (!parse_uint(slash + 1, &prefix) || prefix > 32) {
      return false;
    }
  }

  struct in_addr address;
  if (inet_pton(AF_INET, address_text, &address) != 1) {
    return false;
  }

  uint32_t host_address = ntohl(address.s_addr);
  uint32_t mask = prefix == 0 ? 0 : UINT32_MAX << (32 - prefix);

  out->mask = mask;
  out->network = host_address & mask;
  snprintf(out->text, sizeof(out->text), "%s/%u", address_text, prefix);
  return true;
}

static bool parse_cidr6(const char *text, struct cidr6 *out) {
  char address_text[96];
  const char *slash = strchr(text, '/');
  unsigned prefix = 128;

  if (slash == NULL) {
    if (strlen(text) >= sizeof(address_text)) {
      return false;
    }
    strcpy(address_text, text);
  } else {
    size_t address_len = (size_t)(slash - text);

    if (address_len == 0 || address_len >= sizeof(address_text)) {
      return false;
    }

    memcpy(address_text, text, address_len);
    address_text[address_len] = '\0';

    if (!parse_uint(slash + 1, &prefix) || prefix > 128) {
      return false;
    }
  }

  struct in6_addr address;
  if (inet_pton(AF_INET6, address_text, &address) != 1) {
    return false;
  }

  memset(out->mask, 0, sizeof(out->mask));
  for (unsigned bit = 0; bit < prefix; bit++) {
    out->mask[bit / 8] |= (uint8_t)(0x80u >> (bit % 8));
  }

  for (size_t i = 0; i < sizeof(out->network); i++) {
    out->network[i] = address.s6_addr[i] & out->mask[i];
  }

  snprintf(out->text, sizeof(out->text), "%s/%u", address_text, prefix);
  return true;
}

static bool add_cidr(struct context *ctx, const char *text) {
  if (ctx->cidr_count >= MAX_CIDRS) {
    fprintf(stderr, "too many LAN CIDRs, max is %u\n", MAX_CIDRS);
    return false;
  }

  if (!parse_cidr(text, &ctx->cidrs[ctx->cidr_count])) {
    fprintf(stderr, "invalid IPv4 CIDR: %s\n", text);
    return false;
  }

  ctx->cidr_count++;
  return true;
}

static bool add_cidr6(struct context *ctx, const char *text) {
  if (ctx->cidr6_count >= MAX_CIDRS) {
    fprintf(stderr, "too many LAN IPv6 CIDRs, max is %u\n", MAX_CIDRS);
    return false;
  }

  if (!parse_cidr6(text, &ctx->cidrs6[ctx->cidr6_count])) {
    fprintf(stderr, "invalid IPv6 CIDR: %s\n", text);
    return false;
  }

  ctx->cidr6_count++;
  return true;
}

static bool add_interface(struct context *ctx, const char *name) {
  if (ctx->interface_count >= MAX_INTERFACES) {
    fprintf(stderr, "too many interfaces, max is %u\n", MAX_INTERFACES);
    return false;
  }

  for (size_t i = 0; i < ctx->interface_count; i++) {
    if (strcmp(ctx->interfaces[i].name, name) == 0) {
      return true;
    }
  }

  struct capture_interface *iface = &ctx->interfaces[ctx->interface_count++];
  iface->name = name;
  iface->ctx = ctx;
  return true;
}

static void build_interface_label(struct context *ctx) {
  size_t used = 0;

  ctx->interface_label[0] = '\0';
  for (size_t i = 0; i < ctx->interface_count; i++) {
    int written = snprintf(ctx->interface_label + used,
                           sizeof(ctx->interface_label) - used, "%s%s",
                           i == 0 ? "" : ",", ctx->interfaces[i].name);
    if (written < 0) {
      ctx->interface_label[0] = '\0';
      return;
    }

    if ((size_t)written >= sizeof(ctx->interface_label) - used) {
      ctx->interface_label[sizeof(ctx->interface_label) - 1] = '\0';
      return;
    }

    used += (size_t)written;
  }
}

static bool cidr_contains(const struct cidr *cidr, uint32_t address) {
  return (address & cidr->mask) == cidr->network;
}

static bool cidr6_contains(const struct cidr6 *cidr, const uint8_t address[16]) {
  for (size_t i = 0; i < 16; i++) {
    if ((address[i] & cidr->mask[i]) != cidr->network[i]) {
      return false;
    }
  }

  return true;
}

static enum scope classify_scope4(const struct context *ctx, uint32_t peer) {
  for (size_t i = 0; i < ctx->cidr_count; i++) {
    if (cidr_contains(&ctx->cidrs[i], peer)) {
      return SCOPE_LAN;
    }
  }

  return SCOPE_WAN;
}

static enum scope classify_scope6(const struct context *ctx,
                                  const uint8_t peer[16]) {
  for (size_t i = 0; i < ctx->cidr6_count; i++) {
    if (cidr6_contains(&ctx->cidrs6[i], peer)) {
      return SCOPE_LAN;
    }
  }

  return SCOPE_WAN;
}

static bool mac_equal(const uint8_t *a, const uint8_t *b) {
  return memcmp(a, b, ETH_ADDR_LEN) == 0;
}

static bool mac_is_broadcast(const uint8_t *mac) {
  for (size_t i = 0; i < ETH_ADDR_LEN; i++) {
    if (mac[i] != 0xff) {
      return false;
    }
  }

  return true;
}

static bool mac_is_multicast(const uint8_t *mac) {
  return (mac[0] & 0x01) != 0;
}

static bool get_interface_mac(const char *interface, uint8_t out[ETH_ADDR_LEN],
                              bool report_missing) {
  struct ifaddrs *ifaddrs_list = NULL;

  if (getifaddrs(&ifaddrs_list) != 0) {
    perror("getifaddrs");
    return false;
  }

  bool found = false;
  for (struct ifaddrs *ifa = ifaddrs_list; ifa != NULL; ifa = ifa->ifa_next) {
    if (ifa->ifa_addr == NULL || strcmp(ifa->ifa_name, interface) != 0 ||
        ifa->ifa_addr->sa_family != AF_LINK) {
      continue;
    }

    const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)ifa->ifa_addr;
    if (sdl->sdl_alen != ETH_ADDR_LEN) {
      continue;
    }

    memcpy(out, LLADDR(sdl), ETH_ADDR_LEN);
    found = true;
    break;
  }

  freeifaddrs(ifaddrs_list);

  if (!found && report_missing) {
    fprintf(stderr, "could not find MAC address for interface %s\n", interface);
  }

  return found;
}

static const char *direction_label(enum direction direction) {
  return direction == DIR_RECEIVE ? "receive" : "transmit";
}

static const char *scope_label(enum scope scope) {
  return scope == SCOPE_LAN ? "lan" : "wan";
}

static void print_mac(FILE *stream, const uint8_t mac[ETH_ADDR_LEN]) {
  fprintf(stream, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2],
          mac[3], mac[4], mac[5]);
}

static bool refresh_interface_mac(struct capture_interface *iface) {
  uint8_t current_mac[ETH_ADDR_LEN];

  if (!get_interface_mac(iface->name, current_mac, false) ||
      mac_equal(current_mac, iface->mac)) {
    return false;
  }

  fprintf(stderr, "interface %s MAC changed from ", iface->name);
  print_mac(stderr, iface->mac);
  fprintf(stderr, " to ");
  print_mac(stderr, current_mac);
  fprintf(stderr, "; refreshing packet classification\n");
  fflush(stderr);

  memcpy(iface->mac, current_mac, ETH_ADDR_LEN);
  return true;
}

static bool classify_packet_direction(struct capture_interface *iface,
                                      const uint8_t *dst_mac,
                                      const uint8_t *src_mac,
                                      enum direction *direction) {
  if (mac_equal(src_mac, iface->mac)) {
    *direction = DIR_TRANSMIT;
    return true;
  }

  if (mac_equal(dst_mac, iface->mac) || mac_is_broadcast(dst_mac) ||
      mac_is_multicast(dst_mac)) {
    *direction = DIR_RECEIVE;
    return true;
  }

  if (!refresh_interface_mac(iface)) {
    return false;
  }

  if (mac_equal(src_mac, iface->mac)) {
    *direction = DIR_TRANSMIT;
    return true;
  }

  if (mac_equal(dst_mac, iface->mac)) {
    *direction = DIR_RECEIVE;
    return true;
  }

  return false;
}

static void format_bytes(double bytes, char *out, size_t out_size) {
  static const char *units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
  size_t unit = 0;

  while (bytes >= 1024.0 && unit + 1 < sizeof(units) / sizeof(units[0])) {
    bytes /= 1024.0;
    unit++;
  }

  if (unit == 0) {
    snprintf(out, out_size, "%.0f %s", bytes, units[unit]);
  } else {
    snprintf(out, out_size, "%.1f %s", bytes, units[unit]);
  }
}

static void format_rate(double bytes_per_second, char *out, size_t out_size) {
  char bytes[32];

  format_bytes(bytes_per_second, bytes, sizeof(bytes));
  snprintf(out, out_size, "%s/s", bytes);
}

static uint64_t counter_delta(uint64_t current, uint64_t previous) {
  return current >= previous ? current - previous : current;
}

static void print_human_header(const struct context *ctx) {
  printf("listening on ");
  for (size_t i = 0; i < ctx->interface_count; i++) {
    if (i > 0) {
      printf("; ");
    }
    printf("%s (", ctx->interfaces[i].name);
    if (ctx->interfaces[i].pcap == NULL) {
      printf("unavailable");
    } else {
      print_mac(stdout, ctx->interfaces[i].mac);
    }
    printf(")");
  }
  printf(", LAN ");
  for (size_t i = 0; i < ctx->cidr_count; i++) {
    printf("%s%s", i == 0 ? "" : ",", ctx->cidrs[i].text);
  }
  printf("; LAN6 ");
  for (size_t i = 0; i < ctx->cidr6_count; i++) {
    printf("%s%s", i == 0 ? "" : ",", ctx->cidrs6[i].text);
  }
  printf("\n");
  printf("%-8s %5s %11s %11s %11s %11s | %10s %10s %10s %10s\n",
         "time", "span", "rx_lan/s", "rx_wan/s", "tx_lan/s", "tx_wan/s",
         "rx_lan", "rx_wan", "tx_lan", "tx_wan");
  fflush(stdout);
}

static void print_human_line(const struct context *ctx,
                             const struct counters *previous, time_t previous_at,
                             time_t now) {
  double interval = difftime(now, previous_at);
  if (interval <= 0.0) {
    interval = 1.0;
  }

  char time_text[16];
  struct tm local_time;
  localtime_r(&now, &local_time);
  strftime(time_text, sizeof(time_text), "%H:%M:%S", &local_time);

  char rx_lan_rate[32];
  char rx_wan_rate[32];
  char tx_lan_rate[32];
  char tx_wan_rate[32];
  char rx_lan_total[32];
  char rx_wan_total[32];
  char tx_lan_total[32];
  char tx_wan_total[32];

  format_rate((double)counter_delta(ctx->counters.bytes[DIR_RECEIVE][SCOPE_LAN],
                                    previous->bytes[DIR_RECEIVE][SCOPE_LAN]) /
                  interval,
              rx_lan_rate, sizeof(rx_lan_rate));
  format_rate((double)counter_delta(ctx->counters.bytes[DIR_RECEIVE][SCOPE_WAN],
                                    previous->bytes[DIR_RECEIVE][SCOPE_WAN]) /
                  interval,
              rx_wan_rate, sizeof(rx_wan_rate));
  format_rate((double)counter_delta(ctx->counters.bytes[DIR_TRANSMIT][SCOPE_LAN],
                                    previous->bytes[DIR_TRANSMIT][SCOPE_LAN]) /
                  interval,
              tx_lan_rate, sizeof(tx_lan_rate));
  format_rate((double)counter_delta(ctx->counters.bytes[DIR_TRANSMIT][SCOPE_WAN],
                                    previous->bytes[DIR_TRANSMIT][SCOPE_WAN]) /
                  interval,
              tx_wan_rate, sizeof(tx_wan_rate));

  format_bytes((double)ctx->counters.bytes[DIR_RECEIVE][SCOPE_LAN], rx_lan_total,
               sizeof(rx_lan_total));
  format_bytes((double)ctx->counters.bytes[DIR_RECEIVE][SCOPE_WAN], rx_wan_total,
               sizeof(rx_wan_total));
  format_bytes((double)ctx->counters.bytes[DIR_TRANSMIT][SCOPE_LAN],
               tx_lan_total, sizeof(tx_lan_total));
  format_bytes((double)ctx->counters.bytes[DIR_TRANSMIT][SCOPE_WAN],
               tx_wan_total, sizeof(tx_wan_total));

  printf("%-8s %4.0fs %11s %11s %11s %11s | %10s %10s %10s %10s\n",
         time_text, interval, rx_lan_rate, rx_wan_rate, tx_lan_rate,
         tx_wan_rate, rx_lan_total, rx_wan_total, tx_lan_total, tx_wan_total);
  fflush(stdout);
}

static void print_prometheus_metrics(FILE *stream, const struct context *ctx) {
  time_t now = time(NULL);

  fprintf(stream, "# unix_seconds %lld\n", (long long)now);
  for (enum direction direction = 0; direction < DIR_COUNT; direction++) {
    for (enum scope scope = 0; scope < SCOPE_COUNT; scope++) {
      fprintf(stream,
              "%s{interface=\"%s\",direction=\"%s\",scope=\"%s\"} %" PRIu64
              "\n",
              ctx->metric_name, ctx->interface_label, direction_label(direction),
              scope_label(scope), ctx->counters.bytes[direction][scope]);
      fprintf(stream,
              "host_observability_network_bpf_packets_total{interface=\"%s\",direction=\"%s\",scope=\"%s\"} %" PRIu64
              "\n",
              ctx->interface_label, direction_label(direction), scope_label(scope),
              ctx->counters.packets[direction][scope]);
    }
  }
  fprintf(stream,
          "host_observability_network_bpf_ignored_packets_total{interface=\"%s\",reason=\"not_ip\"} %" PRIu64
          "\n",
          ctx->interface_label, ctx->counters.ignored_not_ip);
  fprintf(stream,
          "host_observability_network_bpf_ignored_packets_total{interface=\"%s\",reason=\"not_self\"} %" PRIu64
          "\n",
          ctx->interface_label, ctx->counters.ignored_not_self);
  fprintf(stream,
          "host_observability_network_bpf_ignored_packets_total{interface=\"%s\",reason=\"short\"} %" PRIu64
          "\n",
          ctx->interface_label, ctx->counters.ignored_short);
  fprintf(stream, "\n");
  fflush(stream);
}

static void print_textfile_metrics(FILE *stream, const struct context *ctx,
                                   const struct counters *previous,
                                   time_t previous_at, time_t now) {
  double interval = difftime(now, previous_at);
  if (interval <= 0.0) {
    interval = 1.0;
  }

  fprintf(stream,
          "# HELP %s Classified host network traffic in bytes.\n",
          ctx->metric_name);
  fprintf(stream, "# TYPE %s counter\n", ctx->metric_name);
  for (enum direction direction = 0; direction < DIR_COUNT; direction++) {
    for (enum scope scope = 0; scope < SCOPE_COUNT; scope++) {
      fprintf(stream, "%s{direction=\"%s\",scope=\"%s\"} %" PRIu64 "\n",
              ctx->metric_name, direction_label(direction), scope_label(scope),
              ctx->counters.bytes[direction][scope]);
    }
  }

  fprintf(stream,
          "# HELP %s Recent classified host network traffic rate in bytes per second.\n",
          DEFAULT_TEXTFILE_RATE_METRIC);
  fprintf(stream, "# TYPE %s gauge\n", DEFAULT_TEXTFILE_RATE_METRIC);
  for (enum direction direction = 0; direction < DIR_COUNT; direction++) {
    for (enum scope scope = 0; scope < SCOPE_COUNT; scope++) {
      double bytes_per_second = 0.0;
      if (previous != NULL) {
        bytes_per_second =
            (double)counter_delta(ctx->counters.bytes[direction][scope],
                                  previous->bytes[direction][scope]) /
            interval;
      }

      fprintf(stream, "%s{direction=\"%s\",scope=\"%s\"} %.3f\n",
              DEFAULT_TEXTFILE_RATE_METRIC, direction_label(direction),
              scope_label(scope), bytes_per_second);
    }
  }
}

static bool write_textfile_metrics(const struct context *ctx,
                                   const struct counters *previous,
                                   time_t previous_at, time_t now) {
  char temp_path[4096];

  if (snprintf(temp_path, sizeof(temp_path), "%s.%ld.tmp", ctx->textfile_path,
               (long)getpid()) >= (int)sizeof(temp_path)) {
    fprintf(stderr, "textfile path is too long: %s\n", ctx->textfile_path);
    return false;
  }

  FILE *stream = fopen(temp_path, "w");
  if (stream == NULL) {
    fprintf(stderr, "open %s: %s\n", temp_path, strerror(errno));
    return false;
  }

  print_textfile_metrics(stream, ctx, previous, previous_at, now);

  if (fflush(stream) != 0) {
    fprintf(stderr, "flush %s: %s\n", temp_path, strerror(errno));
    fclose(stream);
    unlink(temp_path);
    return false;
  }

  if (fsync(fileno(stream)) != 0) {
    fprintf(stderr, "fsync %s: %s\n", temp_path, strerror(errno));
    fclose(stream);
    unlink(temp_path);
    return false;
  }

  if (fclose(stream) != 0) {
    fprintf(stderr, "close %s: %s\n", temp_path, strerror(errno));
    unlink(temp_path);
    return false;
  }

  if (chmod(temp_path, 0644) != 0) {
    fprintf(stderr, "chmod %s: %s\n", temp_path, strerror(errno));
    unlink(temp_path);
    return false;
  }

  if (rename(temp_path, ctx->textfile_path) != 0) {
    fprintf(stderr, "rename %s to %s: %s\n", temp_path, ctx->textfile_path,
            strerror(errno));
    unlink(temp_path);
    return false;
  }

  return true;
}

static void print_status(FILE *stream, const struct context *ctx) {
  fprintf(stream, "listening on ");
  for (size_t i = 0; i < ctx->interface_count; i++) {
    if (i > 0) {
      fprintf(stream, "; ");
    }
    fprintf(stream, "%s, ", ctx->interfaces[i].name);
    if (ctx->interfaces[i].pcap == NULL) {
      fprintf(stream, "unavailable");
    } else {
      fprintf(stream, "MAC ");
      print_mac(stream, ctx->interfaces[i].mac);
    }
  }
  fprintf(stream, ", LAN CIDRs: ");
  for (size_t i = 0; i < ctx->cidr_count; i++) {
    fprintf(stream, "%s%s", i == 0 ? "" : ", ", ctx->cidrs[i].text);
  }
  fprintf(stream, "; LAN IPv6 CIDRs: ");
  for (size_t i = 0; i < ctx->cidr6_count; i++) {
    fprintf(stream, "%s%s", i == 0 ? "" : ", ", ctx->cidrs6[i].text);
  }
  fprintf(stream, "\n");
}

static void close_capture_interface(struct capture_interface *iface) {
  if (iface->pcap != NULL) {
    pcap_close(iface->pcap);
    iface->pcap = NULL;
  }
}

static void close_capture_interfaces(struct context *ctx) {
  for (size_t i = 0; i < ctx->interface_count; i++) {
    close_capture_interface(&ctx->interfaces[i]);
  }
}

static bool open_capture_interface(struct capture_interface *iface,
                                   bool report_errors) {
  if (!get_interface_mac(iface->name, iface->mac, report_errors)) {
    return false;
  }

  char errbuf[PCAP_ERRBUF_SIZE];
  iface->pcap = pcap_open_live(iface->name, 65535, 0, 1000, errbuf);
  if (iface->pcap == NULL) {
    if (report_errors) {
      fprintf(stderr, "pcap_open_live(%s): %s\n", iface->name, errbuf);
    }
    return false;
  }

  if (pcap_datalink(iface->pcap) != DLT_EN10MB) {
    if (report_errors) {
      fprintf(stderr, "unsupported datalink type on %s: %s\n", iface->name,
              pcap_datalink_val_to_name(pcap_datalink(iface->pcap)));
    }
    close_capture_interface(iface);
    return false;
  }

  struct bpf_program filter;
  if (pcap_compile(iface->pcap, &filter, "ip or ip6", 1,
                   PCAP_NETMASK_UNKNOWN) != 0) {
    if (report_errors) {
      fprintf(stderr, "pcap_compile(%s): %s\n", iface->name,
              pcap_geterr(iface->pcap));
    }
    close_capture_interface(iface);
    return false;
  }

  if (pcap_setfilter(iface->pcap, &filter) != 0) {
    if (report_errors) {
      fprintf(stderr, "pcap_setfilter(%s): %s\n", iface->name,
              pcap_geterr(iface->pcap));
    }
    pcap_freecode(&filter);
    close_capture_interface(iface);
    return false;
  }
  pcap_freecode(&filter);

  if (pcap_setnonblock(iface->pcap, 1, errbuf) != 0) {
    if (report_errors) {
      fprintf(stderr, "pcap_setnonblock(%s): %s\n", iface->name, errbuf);
    }
    close_capture_interface(iface);
    return false;
  }

  return true;
}

static const char *get_capture_error(pcap_t *pcap) { return pcap_geterr(pcap); }

static const struct capture_operations system_capture_operations = {
    .get_interface_mac = get_interface_mac,
    .open_capture_interface = open_capture_interface,
    .close_capture_interface = close_capture_interface,
    .get_selectable_fd = pcap_get_selectable_fd,
    .dispatch = pcap_dispatch,
    .get_error = get_capture_error,
};

static void schedule_capture_retry(struct capture_interface *iface,
                                   time_t now,
                                   const struct capture_operations *operations) {
  operations->close_capture_interface(iface);
  iface->retrying = true;
  iface->next_retry = now + INTERFACE_RETRY_SECONDS;
}

static void try_open_capture_interface(struct capture_interface *iface,
                                       time_t now,
                                       const struct capture_operations *operations) {
  if (iface->pcap != NULL || now < iface->next_retry) {
    return;
  }

  bool was_retrying = iface->retrying;
  if (!operations->open_capture_interface(iface, !was_retrying)) {
    schedule_capture_retry(iface, now, operations);
    return;
  }

  iface->retrying = false;
  iface->next_retry = 0;
  iface->next_health_check = now + INTERFACE_RETRY_SECONDS;
  if (was_retrying) {
    fprintf(stderr, "capture restored on interface %s\n", iface->name);
  }
}

static void maintain_capture_interface(struct capture_interface *iface,
                                       time_t now,
                                       const struct capture_operations *operations) {
  if (iface->pcap == NULL) {
    try_open_capture_interface(iface, now, operations);
    return;
  }

  if (now < iface->next_health_check) {
    return;
  }
  iface->next_health_check = now + INTERFACE_RETRY_SECONDS;

  uint8_t current_mac[ETH_ADDR_LEN];
  if (!operations->get_interface_mac(iface->name, current_mac, false)) {
    fprintf(stderr, "interface %s disappeared; retrying capture\n",
            iface->name);
    schedule_capture_retry(iface, now, operations);
    return;
  }

  if (!mac_equal(current_mac, iface->mac)) {
    fprintf(stderr, "interface %s MAC changed from ", iface->name);
    print_mac(stderr, iface->mac);
    fprintf(stderr, " to ");
    print_mac(stderr, current_mac);
    fprintf(stderr, "; refreshing packet classification\n");
    fflush(stderr);
    memcpy(iface->mac, current_mac, ETH_ADDR_LEN);
  }
}

static time_t next_capture_maintenance(const struct context *ctx) {
  time_t next = 0;

  for (size_t i = 0; i < ctx->interface_count; i++) {
    const struct capture_interface *iface = &ctx->interfaces[i];
    time_t candidate = iface->pcap == NULL ? iface->next_retry
                                           : iface->next_health_check;
    if (next == 0 || candidate < next) {
      next = candidate;
    }
  }

  return next;
}

static int collect_capture_fds(const struct context *ctx, fd_set *readfds,
                               const struct capture_operations *operations) {
  int max_fd = -1;

  FD_ZERO(readfds);
  for (size_t i = 0; i < ctx->interface_count; i++) {
    const struct capture_interface *iface = &ctx->interfaces[i];
    if (iface->pcap == NULL) {
      continue;
    }

    int fd = operations->get_selectable_fd(iface->pcap);
    if (fd >= 0) {
      FD_SET(fd, readfds);
      if (fd > max_fd) {
        max_fd = fd;
      }
    }
  }

  return max_fd;
}

static uint64_t total_packets(const struct counters *counters) {
  uint64_t total = 0;

  for (enum direction direction = 0; direction < DIR_COUNT; direction++) {
    for (enum scope scope = 0; scope < SCOPE_COUNT; scope++) {
      total += counters->packets[direction][scope];
    }
  }

  return total;
}

static void handle_packet(u_char *user, const struct pcap_pkthdr *header,
                          const u_char *packet) {
  struct capture_interface *iface = (struct capture_interface *)user;
  struct context *ctx = iface->ctx;

  if (header->caplen < ETH_HEADER_LEN) {
    ctx->counters.ignored_short++;
    return;
  }

  const uint8_t *dst_mac = packet;
  const uint8_t *src_mac = packet + ETH_ADDR_LEN;
  enum direction direction;

  if (!classify_packet_direction(iface, dst_mac, src_mac, &direction)) {
    ctx->counters.ignored_not_self++;
    return;
  }

  size_t offset = ETH_HEADER_LEN;
  uint16_t ethertype = read_be16(packet + 12);

  while (ethertype == ETHERTYPE_VLAN || ethertype == ETHERTYPE_QINQ ||
         ethertype == ETHERTYPE_VLAN_OLD) {
    if (header->caplen < offset + 4) {
      ctx->counters.ignored_short++;
      return;
    }

    ethertype = read_be16(packet + offset + 2);
    offset += 4;
  }

  uint64_t accounted_bytes = 0;
  enum scope scope;

  if (ethertype == ETHERTYPE_IPV4) {
    if (header->caplen < offset + IPV4_MIN_HEADER_LEN) {
      ctx->counters.ignored_short++;
      return;
    }

    uint8_t version_ihl = packet[offset];
    uint8_t version = version_ihl >> 4;
    uint8_t ihl = (uint8_t)((version_ihl & 0x0f) * 4);

    if (version != 4 || ihl < IPV4_MIN_HEADER_LEN ||
        header->caplen < offset + ihl) {
      ctx->counters.ignored_short++;
      return;
    }

    uint16_t ip_total_len = read_be16(packet + offset + 2);
    if (ip_total_len < ihl) {
      ctx->counters.ignored_short++;
      return;
    }

    uint32_t src_ip = read_be32(packet + offset + 12);
    uint32_t dst_ip = read_be32(packet + offset + 16);
    uint32_t peer_ip = direction == DIR_TRANSMIT ? dst_ip : src_ip;
    scope = classify_scope4(ctx, peer_ip);
    accounted_bytes = ip_total_len;
  } else if (ethertype == ETHERTYPE_IPV6) {
    if (header->caplen < offset + IPV6_HEADER_LEN) {
      ctx->counters.ignored_short++;
      return;
    }

    uint8_t version = packet[offset] >> 4;
    if (version != 6) {
      ctx->counters.ignored_short++;
      return;
    }

    uint16_t payload_len = read_be16(packet + offset + 4);
    const uint8_t *src_ip = packet + offset + 8;
    const uint8_t *dst_ip = packet + offset + 24;
    const uint8_t *peer_ip = direction == DIR_TRANSMIT ? dst_ip : src_ip;
    scope = classify_scope6(ctx, peer_ip);
    accounted_bytes = IPV6_HEADER_LEN + payload_len;
  } else {
    ctx->counters.ignored_not_ip++;
    return;
  }

  ctx->counters.bytes[direction][scope] += accounted_bytes;
  ctx->counters.packets[direction][scope]++;
  ctx->accounted_packets++;

  if (ctx->max_accounted_packets > 0 &&
      ctx->accounted_packets >= ctx->max_accounted_packets) {
    stop_requested = 1;
    pcap_breakloop(iface->pcap);
  }
}

static void dispatch_capture_interfaces(
    struct context *ctx, int ready, const fd_set *readfds, time_t now,
    const struct capture_operations *operations) {
  for (size_t i = 0; i < ctx->interface_count; i++) {
    struct capture_interface *iface = &ctx->interfaces[i];
    if (iface->pcap == NULL) {
      continue;
    }

    int fd = operations->get_selectable_fd(iface->pcap);
    if (fd >= 0 && (ready == 0 || !FD_ISSET(fd, readfds))) {
      continue;
    }

    int rc = operations->dispatch(iface->pcap, -1, handle_packet,
                                  (u_char *)iface);
    if (rc == PCAP_ERROR_BREAK) {
      break;
    }

    if (rc == PCAP_ERROR) {
      fprintf(stderr, "pcap_dispatch(%s): %s\n", iface->name,
              operations->get_error(iface->pcap));
      schedule_capture_retry(iface, now, operations);
    }
  }
}

static void usage(FILE *stream, const char *program_name) {
  fprintf(stream,
          "Usage: %s [-i interface]... [-l cidr] [-p seconds] [-n packets]\n"
          "\n"
          "Capture IP packets on a Darwin interface with libpcap/BPF and\n"
          "emit LAN/WAN byte and packet counters.\n"
          "\n"
          "Options:\n"
          "  -i interface  Interface to capture. Repeatable. Default: %s\n"
          "  -l cidr       LAN IPv4 CIDR. Repeatable. Default: %s\n"
          "  -6 cidr       LAN IPv6 CIDR. Repeatable. Default: %s\n"
          "  -p seconds    Print interval, default: 5\n"
          "  -n packets    Stop after this many accounted IP packets\n"
          "  --prometheus  Emit Prometheus text format instead of CLI table\n"
          "  --textfile path\n"
          "                Keep capturing and atomically write node-exporter textfile metrics\n"
          "  --metric-name name\n"
          "                Byte counter metric name. Defaults to %s, or %s with --textfile\n"
          "  -h            Show this help\n",
          program_name, DEFAULT_INTERFACE, DEFAULT_LAN_CIDR, DEFAULT_LAN6_CIDR,
          DEFAULT_PROMETHEUS_METRIC, DEFAULT_TEXTFILE_METRIC);
}

#ifndef DARWIN_LAN_WAN_BPF_TEST
int main(int argc, char **argv) {
  struct context ctx = {
      .print_interval_seconds = 5,
      .metric_name = DEFAULT_PROMETHEUS_METRIC,
  };
  bool custom_cidr_seen = false;
  bool custom_cidr6_seen = false;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      usage(stdout, argv[0]);
      return 0;
    } else if (strcmp(argv[i], "-i") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "-i requires an interface\n");
        usage(stderr, argv[0]);
        return 2;
      }
      if (!add_interface(&ctx, argv[i])) {
        return 2;
      }
    } else if (strcmp(argv[i], "-l") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "-l requires an IPv4 CIDR\n");
        usage(stderr, argv[0]);
        return 2;
      }
      custom_cidr_seen = true;
      if (!add_cidr(&ctx, argv[i])) {
        return 2;
      }
    } else if (strcmp(argv[i], "-6") == 0 || strcmp(argv[i], "--lan6") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "-6 requires an IPv6 CIDR\n");
        usage(stderr, argv[0]);
        return 2;
      }
      custom_cidr6_seen = true;
      if (!add_cidr6(&ctx, argv[i])) {
        return 2;
      }
    } else if (strcmp(argv[i], "-p") == 0) {
      if (++i >= argc ||
          !parse_uint(argv[i], &ctx.print_interval_seconds) ||
          ctx.print_interval_seconds == 0) {
        fprintf(stderr, "-p requires a positive integer interval\n");
        usage(stderr, argv[0]);
        return 2;
      }
    } else if (strcmp(argv[i], "-n") == 0) {
      if (++i >= argc || !parse_uint64(argv[i], &ctx.max_accounted_packets)) {
        fprintf(stderr, "-n requires a non-negative integer packet count\n");
        usage(stderr, argv[0]);
        return 2;
      }
    } else if (strcmp(argv[i], "--prometheus") == 0) {
      ctx.output_format = OUTPUT_PROMETHEUS;
    } else if (strcmp(argv[i], "--textfile") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "--textfile requires a path\n");
        usage(stderr, argv[0]);
        return 2;
      }
      ctx.output_format = OUTPUT_TEXTFILE;
      ctx.textfile_path = argv[i];
    } else if (strcmp(argv[i], "--metric-name") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "--metric-name requires a metric name\n");
        usage(stderr, argv[0]);
        return 2;
      }
      ctx.metric_name = argv[i];
      ctx.metric_name_set = true;
    } else {
      fprintf(stderr, "unknown argument: %s\n", argv[i]);
      usage(stderr, argv[0]);
      return 2;
    }
  }

  if (!custom_cidr_seen && !add_cidr(&ctx, DEFAULT_LAN_CIDR)) {
    return 2;
  }

  if (!custom_cidr6_seen && !add_cidr6(&ctx, DEFAULT_LAN6_CIDR)) {
    return 2;
  }

  if (ctx.interface_count == 0 && !add_interface(&ctx, DEFAULT_INTERFACE)) {
    return 2;
  }
  build_interface_label(&ctx);

  if (ctx.output_format == OUTPUT_TEXTFILE && !ctx.metric_name_set) {
    ctx.metric_name = DEFAULT_TEXTFILE_METRIC;
  }

  time_t started_at = time(NULL);
  for (size_t i = 0; i < ctx.interface_count; i++) {
    try_open_capture_interface(&ctx.interfaces[i], started_at,
                               &system_capture_operations);
  }

  signal(SIGINT, request_stop);
  signal(SIGTERM, request_stop);

  struct counters previous_counters = ctx.counters;
  time_t previous_print = time(NULL);

  if (ctx.output_format == OUTPUT_PROMETHEUS) {
    print_status(stderr, &ctx);
    print_prometheus_metrics(stdout, &ctx);
  } else if (ctx.output_format == OUTPUT_TEXTFILE) {
    print_status(stderr, &ctx);
    if (!write_textfile_metrics(&ctx, NULL, previous_print, previous_print)) {
      close_capture_interfaces(&ctx);
      return 1;
    }
  } else {
    print_human_header(&ctx);
  }

  time_t next_print = previous_print + (time_t)ctx.print_interval_seconds;
  while (!stop_requested) {
    time_t loop_started_at = time(NULL);
    for (size_t i = 0; i < ctx.interface_count; i++) {
      maintain_capture_interface(&ctx.interfaces[i], loop_started_at,
                                 &system_capture_operations);
    }

    fd_set readfds;
    int max_fd =
        collect_capture_fds(&ctx, &readfds, &system_capture_operations);

    time_t before_select = time(NULL);
    time_t next_wakeup = next_print;
    time_t next_maintenance = next_capture_maintenance(&ctx);
    if (next_maintenance < next_wakeup) {
      next_wakeup = next_maintenance;
    }
    time_t wait_seconds =
        next_wakeup > before_select ? next_wakeup - before_select : 0;
    struct timeval timeout = {
        .tv_sec = wait_seconds,
        .tv_usec = 0,
    };

    int ready = select(max_fd + 1, &readfds, NULL, NULL, &timeout);
    if (ready < 0) {
      if (errno == EINTR) {
        continue;
      }

      fprintf(stderr, "select: %s\n", strerror(errno));
      time_t failed_at = time(NULL);
      for (size_t i = 0; i < ctx.interface_count; i++) {
        struct capture_interface *iface = &ctx.interfaces[i];
        if (iface->pcap != NULL) {
          schedule_capture_retry(iface, failed_at,
                                 &system_capture_operations);
          iface->next_retry = failed_at;
        }
      }
      continue;
    }

    dispatch_capture_interfaces(&ctx, ready, &readfds, time(NULL),
                                &system_capture_operations);

    time_t now = time(NULL);
    if (now >= next_print) {
      if (ctx.output_format == OUTPUT_PROMETHEUS) {
        print_prometheus_metrics(stdout, &ctx);
      } else if (ctx.output_format == OUTPUT_TEXTFILE) {
        if (!write_textfile_metrics(&ctx, &previous_counters, previous_print,
                                    now)) {
          close_capture_interfaces(&ctx);
          return 1;
        }
        previous_counters = ctx.counters;
        previous_print = now;
      } else {
        print_human_line(&ctx, &previous_counters, previous_print, now);
        previous_counters = ctx.counters;
        previous_print = now;
      }
      do {
        next_print += (time_t)ctx.print_interval_seconds;
      } while (next_print <= now);
    }
  }

  time_t final_print = time(NULL);
  if (ctx.output_format == OUTPUT_PROMETHEUS) {
    print_prometheus_metrics(stdout, &ctx);
  } else if (ctx.output_format == OUTPUT_TEXTFILE) {
    if (!write_textfile_metrics(&ctx, &previous_counters, previous_print,
                                final_print)) {
      close_capture_interfaces(&ctx);
      return 1;
    }
  } else if (final_print > previous_print ||
             ctx.accounted_packets > total_packets(&previous_counters)) {
    print_human_line(&ctx, &previous_counters, previous_print, final_print);
  }
  close_capture_interfaces(&ctx);
  return 0;
}
#endif
