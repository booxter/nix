#define DARWIN_LAN_WAN_BPF_TEST
#include "main.c"

#include <assert.h>

enum fake_interface_index {
  FAKE_EN0 = 0,
  FAKE_EN7 = 1,
  FAKE_INTERFACE_COUNT = 2,
};

struct fake_capture {
  int fd;
  int dispatch_result;
  unsigned dispatch_count;
};

static bool fake_available[FAKE_INTERFACE_COUNT];
static unsigned fake_open_count[FAKE_INTERFACE_COUNT];
static unsigned fake_close_count[FAKE_INTERFACE_COUNT];
static struct fake_capture fake_captures[FAKE_INTERFACE_COUNT];

static size_t fake_interface_index(const char *name) {
  if (strcmp(name, "en0") == 0) {
    return FAKE_EN0;
  }
  if (strcmp(name, "en7") == 0) {
    return FAKE_EN7;
  }

  assert(false && "unexpected fake interface");
  return 0;
}

static bool fake_get_interface_mac(const char *interface,
                                   uint8_t out[ETH_ADDR_LEN],
                                   bool report_missing) {
  (void)report_missing;
  size_t index = fake_interface_index(interface);
  if (!fake_available[index]) {
    return false;
  }

  memset(out, 0, ETH_ADDR_LEN);
  out[ETH_ADDR_LEN - 1] = (uint8_t)(index + 1);
  return true;
}

static bool fake_open_capture_interface(struct capture_interface *iface,
                                        bool report_errors) {
  (void)report_errors;
  size_t index = fake_interface_index(iface->name);
  fake_open_count[index]++;
  if (!fake_get_interface_mac(iface->name, iface->mac, false)) {
    return false;
  }

  iface->pcap = (pcap_t *)&fake_captures[index];
  return true;
}

static void fake_close_capture_interface(struct capture_interface *iface) {
  if (iface->pcap != NULL) {
    fake_close_count[fake_interface_index(iface->name)]++;
    iface->pcap = NULL;
  }
}

static int fake_get_selectable_fd(pcap_t *pcap) {
  return ((struct fake_capture *)pcap)->fd;
}

static int fake_dispatch(pcap_t *pcap, int packet_count, pcap_handler callback,
                         u_char *user) {
  (void)packet_count;
  (void)callback;
  (void)user;
  struct fake_capture *capture = (struct fake_capture *)pcap;
  capture->dispatch_count++;
  return capture->dispatch_result;
}

static const char *fake_get_error(pcap_t *pcap) {
  (void)pcap;
  return "fake capture error";
}

static const struct capture_operations fake_capture_operations = {
    .get_interface_mac = fake_get_interface_mac,
    .open_capture_interface = fake_open_capture_interface,
    .close_capture_interface = fake_close_capture_interface,
    .get_selectable_fd = fake_get_selectable_fd,
    .dispatch = fake_dispatch,
    .get_error = fake_get_error,
};

static void reset_fakes(void) {
  memset(fake_available, 0, sizeof(fake_available));
  memset(fake_open_count, 0, sizeof(fake_open_count));
  memset(fake_close_count, 0, sizeof(fake_close_count));
  memset(fake_captures, 0, sizeof(fake_captures));
  fake_captures[FAKE_EN0].fd = 3;
  fake_captures[FAKE_EN7].fd = 4;
  fake_captures[FAKE_EN0].dispatch_result = 1;
  fake_captures[FAKE_EN7].dispatch_result = 1;
}

static void setup_context(struct context *ctx) {
  memset(ctx, 0, sizeof(*ctx));
  assert(add_interface(ctx, "en0"));
  assert(add_interface(ctx, "en7"));
}

static void test_missing_interface_keeps_available_capture(void) {
  reset_fakes();
  struct context ctx;
  setup_context(&ctx);
  fake_available[FAKE_EN0] = true;

  try_open_capture_interface(&ctx.interfaces[FAKE_EN0], 100,
                             &fake_capture_operations);
  try_open_capture_interface(&ctx.interfaces[FAKE_EN7], 100,
                             &fake_capture_operations);

  assert(ctx.interfaces[FAKE_EN0].pcap != NULL);
  assert(ctx.interfaces[FAKE_EN7].pcap == NULL);
  assert(ctx.interfaces[FAKE_EN7].retrying);
  assert(ctx.interfaces[FAKE_EN7].next_retry == 105);

  fd_set readfds;
  int max_fd = collect_capture_fds(&ctx, &readfds, &fake_capture_operations);
  assert(max_fd == 3);
  assert(FD_ISSET(3, &readfds));
  assert(!FD_ISSET(4, &readfds));

  dispatch_capture_interfaces(&ctx, 1, &readfds, 100,
                              &fake_capture_operations);
  assert(fake_captures[FAKE_EN0].dispatch_count == 1);
  assert(fake_captures[FAKE_EN7].dispatch_count == 0);
}

static void test_disappearing_interface_recovers_independently(void) {
  reset_fakes();
  struct context ctx;
  setup_context(&ctx);
  fake_available[FAKE_EN0] = true;
  fake_available[FAKE_EN7] = true;

  try_open_capture_interface(&ctx.interfaces[FAKE_EN0], 100,
                             &fake_capture_operations);
  try_open_capture_interface(&ctx.interfaces[FAKE_EN7], 100,
                             &fake_capture_operations);
  fake_available[FAKE_EN7] = false;

  maintain_capture_interface(&ctx.interfaces[FAKE_EN0], 105,
                             &fake_capture_operations);
  maintain_capture_interface(&ctx.interfaces[FAKE_EN7], 105,
                             &fake_capture_operations);
  assert(ctx.interfaces[FAKE_EN0].pcap != NULL);
  assert(ctx.interfaces[FAKE_EN7].pcap == NULL);
  assert(fake_close_count[FAKE_EN0] == 0);
  assert(fake_close_count[FAKE_EN7] == 1);
  assert(ctx.interfaces[FAKE_EN7].next_retry == 110);

  fake_available[FAKE_EN7] = true;
  maintain_capture_interface(&ctx.interfaces[FAKE_EN7], 109,
                             &fake_capture_operations);
  assert(ctx.interfaces[FAKE_EN7].pcap == NULL);
  maintain_capture_interface(&ctx.interfaces[FAKE_EN7], 110,
                             &fake_capture_operations);
  assert(ctx.interfaces[FAKE_EN7].pcap != NULL);
  assert(!ctx.interfaces[FAKE_EN7].retrying);
  assert(fake_open_count[FAKE_EN7] == 2);
}

static void test_dispatch_error_isolated_to_failed_interface(void) {
  reset_fakes();
  struct context ctx;
  setup_context(&ctx);
  fake_available[FAKE_EN0] = true;
  fake_available[FAKE_EN7] = true;

  try_open_capture_interface(&ctx.interfaces[FAKE_EN0], 200,
                             &fake_capture_operations);
  try_open_capture_interface(&ctx.interfaces[FAKE_EN7], 200,
                             &fake_capture_operations);
  fake_captures[FAKE_EN7].dispatch_result = PCAP_ERROR;

  fd_set readfds;
  int max_fd = collect_capture_fds(&ctx, &readfds, &fake_capture_operations);
  assert(max_fd == 4);
  dispatch_capture_interfaces(&ctx, 2, &readfds, 200,
                              &fake_capture_operations);

  assert(fake_captures[FAKE_EN0].dispatch_count == 1);
  assert(fake_captures[FAKE_EN7].dispatch_count == 1);
  assert(ctx.interfaces[FAKE_EN0].pcap != NULL);
  assert(ctx.interfaces[FAKE_EN7].pcap == NULL);
  assert(ctx.interfaces[FAKE_EN7].next_retry == 205);
  assert(fake_close_count[FAKE_EN0] == 0);
  assert(fake_close_count[FAKE_EN7] == 1);
}

int main(void) {
  test_missing_interface_keeps_available_capture();
  test_disappearing_interface_recovers_independently();
  test_dispatch_error_isolated_to_failed_interface();
  puts("darwin-lan-wan-bpf tests passed");
  return 0;
}
