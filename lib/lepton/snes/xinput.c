/*
 * lepton-xinput: reads an XInput game controller (an Xbox 360 pad, and the
 * many made like it: Logitech's F310/F710 in their X mode, 8BitDo's in X
 * mode, ...) straight from USB, for Lepton.SNES.Pads. The kernel Lepton
 * runs has no driver for these (no xpad), and their reports are simple:
 *
 *   lepton-xinput /dev/bus/usb/BBB/DDD INTERFACE IN_ENDPOINT OUT_ENDPOINT
 *
 * It claims the interface, lights the pad's first LED, and writes each
 * report the pad sends to its standard output as a packet: a 4-byte
 * big-endian length, then the report (Erlang's {packet, 4}). It ends when
 * the pad goes (unplugged) or its standard input closes.
 *
 * Built with the snes app's tcc, as lepton-snes is (Lepton.SNES).
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* <linux/usbdevice_fs.h>, which the app's headers don't have. */
struct usbdevfs_urb {
  unsigned char type, endpoint;
  int status;
  unsigned int flags;
  void *buffer;
  int buffer_length, actual_length, start_frame, number_of_packets, error_count;
  unsigned int signr;
  void *usercontext;
};

#define URB_TYPE_INTERRUPT 1
#define USBDEVFS_SUBMITURB _IOR('U', 10, struct usbdevfs_urb)
#define USBDEVFS_REAPURBNDELAY _IOW('U', 13, void *)
#define USBDEVFS_CLAIMINTERFACE _IOR('U', 15, unsigned int)
#define USBDEVFS_RELEASEINTERFACE _IOR('U', 16, unsigned int)

static int fd;

static int submit(struct usbdevfs_urb *u, unsigned char ep, void *buf, int len) {
  memset(u, 0, sizeof *u);
  u->type = URB_TYPE_INTERRUPT;
  u->endpoint = ep;
  u->buffer = buf;
  u->buffer_length = len;
  return ioctl(fd, USBDEVFS_SUBMITURB, u);
}

static void put(const unsigned char *data, int n) {
  unsigned char head[4] = {n >> 24, n >> 16, n >> 8, n};
  if (write(1, head, 4) != 4 || write(1, data, n) != n) exit(0);
}

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: lepton-xinput DEVICE INTERFACE IN OUT\n"); return 2; }
  fd = open(argv[1], O_RDWR);
  if (fd < 0) { fprintf(stderr, "lepton-xinput: %s: %s\n", argv[1], strerror(errno)); return 1; }
  unsigned int iface = (unsigned)atoi(argv[2]);
  unsigned char in = (unsigned char)strtol(argv[3], 0, 16), out = (unsigned char)strtol(argv[4], 0, 16);
  if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &iface) < 0) { fprintf(stderr, "lepton-xinput: claim: %s\n", strerror(errno)); return 1; }

  /* The first LED lit (some pads report only once they've been told something). */
  static unsigned char led[3] = {0x01, 0x03, 0x06};
  struct usbdevfs_urb led_urb;
  if (out) submit(&led_urb, out, led, 3);

  static unsigned char buf[64];
  struct usbdevfs_urb urb;
  if (submit(&urb, in | 0x80, buf, sizeof buf) < 0) { fprintf(stderr, "lepton-xinput: read: %s\n", strerror(errno)); return 1; }

  for (;;) {
    struct pollfd p[2] = {{fd, POLLOUT, 0}, {0, POLLIN, 0}};
    if (poll(p, 2, -1) < 0) { if (errno == EINTR) continue; return 1; }
    if (p[1].revents & (POLLIN | POLLHUP | POLLERR)) {
      char c;
      if (read(0, &c, 1) <= 0) break; /* Lepton is done with it */
    }
    if (p[0].revents & (POLLERR | POLLHUP)) break; /* unplugged */
    if (!(p[0].revents & POLLOUT)) continue;

    struct usbdevfs_urb *done = 0;
    while (ioctl(fd, USBDEVFS_REAPURBNDELAY, &done) == 0 && done) {
      if (done == &urb) {
        if (urb.status == -ENODEV || urb.status == -ESHUTDOWN) return 0;
        if (urb.status == 0 && urb.actual_length > 0) put(buf, urb.actual_length);
        if (submit(&urb, in | 0x80, buf, sizeof buf) < 0) return 0;
      }
      done = 0;
    }
    if (errno == ENODEV) return 0;
  }

  ioctl(fd, USBDEVFS_RELEASEINTERFACE, &iface);
  return 0;
}
