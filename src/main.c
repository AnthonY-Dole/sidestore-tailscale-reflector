#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define PACKET_SIZE 65536

static volatile sig_atomic_t running = 1;

static void stop_handler(int sig)
{
    (void)sig;
    running = 0;
}

static int create_tun(char *name)
{
    struct ifreq ifr;
    int fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC);

    if (fd < 0) {
        perror("open /dev/net/tun");
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;

    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("TUNSETIFF");
        close(fd);
        return -1;
    }

    snprintf(name, IFNAMSIZ, "%s", ifr.ifr_name);
    return fd;
}

static int reflect_packet(
    unsigned char *packet,
    ssize_t length,
    uint32_t reflect_ip)
{
    if (length < 20)
        return 0;

    if ((packet[0] >> 4) != 4)
        return 0;

    size_t ihl = (packet[0] & 0x0f) * 4;

    if (ihl < 20 || ihl > (size_t)length)
        return 0;

    uint16_t total_length =
        ((uint16_t)packet[2] << 8) | packet[3];

    if (total_length < ihl || total_length > (size_t)length)
        return 0;

    uint32_t destination;
    memcpy(&destination, packet + 16, 4);

    if (destination != reflect_ip)
        return 0;

    /* Swap IPv4 source and destination. */
    unsigned char tmp[4];

    memcpy(tmp, packet + 12, 4);
    memcpy(packet + 12, packet + 16, 4);
    memcpy(packet + 16, tmp, 4);

    /*
     * No checksum adjustment is necessary:
     * swapping source and destination preserves the
     * one's-complement checksum sums, including the
     * TCP/UDP IPv4 pseudo-header.
     */

    return total_length;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr,
            "Usage: %s <tun-name> <reflect-ipv4>\n"
            "Example: %s sidestore 10.7.0.1\n",
            argv[0], argv[0]);
        return 2;
    }

    char tun_name[IFNAMSIZ] = {0};
    struct in_addr reflect_addr;

    if (strlen(argv[1]) >= IFNAMSIZ) {
        fprintf(stderr, "TUN name too long\n");
        return 2;
    }

    strcpy(tun_name, argv[1]);

    if (inet_pton(AF_INET, argv[2], &reflect_addr) != 1) {
        fprintf(stderr, "Invalid IPv4 address\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);
    {
        struct sigaction sa;

        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = stop_handler;
        sigemptyset(&sa.sa_mask);
        /*
         * No SA_RESTART: read() must return EINTR so the loop re-checks
         * `running` and exits cleanly. Otherwise procd has to send
         * SIGKILL and the TUN interface is left behind.
         */
        sa.sa_flags = 0;

        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
    }

    int fd = create_tun(tun_name);
    if (fd < 0)
        return 1;

    fprintf(stderr,
        "SideStore reflector started: tun=%s reflect=%s\n",
        tun_name, argv[2]);

    unsigned char packet[PACKET_SIZE];
    unsigned long received = 0;
    unsigned long reflected = 0;

    while (running) {
        ssize_t n = read(fd, packet, sizeof(packet));

        if (n < 0) {
            if (errno == EINTR)
                continue;

            perror("TUN read");
            break;
        }

        if (n == 0)
            continue;

        received++;

        int out_len = reflect_packet(
            packet, n, reflect_addr.s_addr);

        if (out_len <= 0)
            continue;

        ssize_t written = write(fd, packet, out_len);

        if (written != out_len) {
            if (written < 0)
                perror("TUN write");
            else
                fprintf(stderr, "Incomplete TUN write\n");
            continue;
        }

        reflected++;

        if (reflected % 100 == 0) {
            fprintf(stderr,
                "received=%lu reflected=%lu\n",
                received, reflected);
        }
    }

    close(fd);
    fprintf(stderr, "Reflector stopped\n");
    return 0;
}
