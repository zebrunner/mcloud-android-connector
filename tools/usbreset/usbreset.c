// usbreset: resets a USB device; the connector resets the USB device of its Android device when adb loses it
// (entrypoint.sh, DEVICE_BUS). Built in the image (Dockerfile): cc -Wall -Wextra -O2 usbreset.c -o usbreset
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

enum reset_mode {
    MODE_IOCTL,      /* USBDEVFS_RESET on a usbfs device node (default) */
    MODE_UNBIND,     /* sysfs driver unbind/bind, target = bus-id, e.g. 1-3.4 */
    MODE_AUTHORIZED  /* sysfs authorized 0/1 toggle, target = bus-id */
};

static unsigned int wait_ms = 200; /* delay between the two halves of -u/-a */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [-i|-u|-a] [-w ms] <target> [<target> ...]\n"
        "       %s -h | --help\n"
        "\n"
        "Reset USB devices using one of three strategies:\n"
        "\n"
        "  -i   USBDEVFS_RESET ioctl (default). Logical bus reset only.\n"
        "       target = usbfs device node, e.g. /dev/bus/usb/001/004\n"
        "\n"
        "  -u   Driver unbind/bind via sysfs.\n"
        "       target = bus-id, e.g. 1-3.4 (see: readlink /sys/class/usb/... or\n"
        "       basename of /sys/bus/usb/devices/*)\n"
        "\n"
        "  -a   'authorized' toggle via sysfs (0 then 1). Closest to a real\n"
        "       unplug/replug without cutting power.\n"
        "       target = bus-id, same as -u\n"
        "\n"
        "  -w ms   delay between the two halves of -u/-a (default: %u)\n"
        "\n"
        "-i requires write access to the device node. -u/-a require root\n"
        "(or a udev rule granting write access to the relevant sysfs files).\n"
        "\n"
        "Finding target values:\n"
        "\n"
        "  lsusb                          list all devices with bus/device numbers\n"
        "  lsusb -d <vid>:<pid>           filter to one vendor:product ID\n"
        "\n"
        "  -i target (usbfs node):\n"
        "    /dev/bus/usb/<bus, 3 digits>/<device, 3 digits>\n"
        "    e.g. 'Bus 001 Device 004' -> /dev/bus/usb/001/004\n"
        "\n"
        "  -u/-a target (bus-id, e.g. 1-3.4):\n"
        "    udevadm info -q path -n /dev/bus/usb/001/004\n"
        "    -> take the last path component, e.g. .../usb1/1-3/1-3.4 -> 1-3.4\n"
        "    or: ls /sys/bus/usb/devices/ | grep -v ':'  (lists all device-level ids;\n"
        "        entries with a colon, e.g. 1-3.4:1.0, are interfaces, not targets)\n",
        prog, prog, wait_ms);
}

static int write_sysfs(const char *path, const char *value)
{
    int fd, rc;
    size_t len = strlen(value);

    fd = open(path, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "%s: open: %s\n", path, strerror(errno));
        return -1;
    }

    rc = write(fd, value, len);
    if (rc < 0 || (size_t)rc != len) {
        fprintf(stderr, "%s: write: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }

    close(fd);
    return 0;
}

static int reset_ioctl(const char *filename)
{
    int fd, rc;

    fd = open(filename, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "%s: open: %s\n", filename, strerror(errno));
        return 1;
    }

    printf("Resetting USB device %s (ioctl)\n", filename);
    rc = ioctl(fd, USBDEVFS_RESET, 0);
    if (rc < 0) {
        fprintf(stderr, "%s: ioctl(USBDEVFS_RESET): %s\n", filename, strerror(errno));
        close(fd);
        return 1;
    }

    printf("Reset successful: %s\n", filename);
    close(fd);
    return 0;
}

static int reset_unbind(const char *busid)
{
    printf("Unbinding %s\n", busid);
    if (write_sysfs("/sys/bus/usb/drivers/usb/unbind", busid))
        return 1;

    usleep(wait_ms * 1000);

    printf("Rebinding %s\n", busid);
    if (write_sysfs("/sys/bus/usb/drivers/usb/bind", busid))
        return 1;

    printf("Reset successful: %s\n", busid);
    return 0;
}

static int reset_authorized(const char *busid)
{
    char path[256];
    int n = snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/authorized", busid);
    if (n < 0 || (size_t)n >= sizeof(path)) {
        fprintf(stderr, "%s: bus-id too long\n", busid);
        return 1;
    }

    printf("Deauthorizing %s\n", busid);
    if (write_sysfs(path, "0"))
        return 1;

    usleep(wait_ms * 1000);

    printf("Reauthorizing %s\n", busid);
    if (write_sysfs(path, "1"))
        return 1;

    printf("Reset successful: %s\n", busid);
    return 0;
}

int main(int argc, char **argv)
{
    enum reset_mode mode = MODE_IOCTL;
    int mode_set = 0;
    int opt, i, ret = 0;

    /* handle --help before getopt, since it has no short-option equivalent */
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        }
    }

    while ((opt = getopt(argc, argv, "iuaw:h")) != -1) {
        switch (opt) {
        case 'i':
            if (mode_set && mode != MODE_IOCTL) {
                fprintf(stderr, "%s: -i/-u/-a are mutually exclusive\n", argv[0]);
                return 1;
            }
            mode = MODE_IOCTL;
            mode_set = 1;
            break;
        case 'u':
            if (mode_set && mode != MODE_UNBIND) {
                fprintf(stderr, "%s: -i/-u/-a are mutually exclusive\n", argv[0]);
                return 1;
            }
            mode = MODE_UNBIND;
            mode_set = 1;
            break;
        case 'a':
            if (mode_set && mode != MODE_AUTHORIZED) {
                fprintf(stderr, "%s: -i/-u/-a are mutually exclusive\n", argv[0]);
                return 1;
            }
            mode = MODE_AUTHORIZED;
            mode_set = 1;
            break;
        case 'w':
            wait_ms = (unsigned int)strtoul(optarg, NULL, 10);
            break;
        case 'h':
            usage(argv[0]);
            return 0;
        default:
            usage(argv[0]);
            return 1;
        }
    }

    if (optind >= argc) {
        usage(argv[0]);
        return 1;
    }

    for (i = optind; i < argc; i++) {
        switch (mode) {
        case MODE_IOCTL:
            ret |= reset_ioctl(argv[i]);
            break;
        case MODE_UNBIND:
            ret |= reset_unbind(argv[i]);
            break;
        case MODE_AUTHORIZED:
            ret |= reset_authorized(argv[i]);
            break;
        }
    }

    return ret ? 1 : 0;
}
