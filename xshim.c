// xshim.c
#include <X11/Xlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int shim_get_window_size(Display *dpy, Window win, int *w, int *h) {
    XWindowAttributes a;
    if (!XGetWindowAttributes(dpy, win, &a)) return 0;
    *w = a.width;
    *h = a.height;
    return 1;
}

int shim_query_pointer(Display *dpy, Window win, int *x, int *y) {
    Window root, child;
    int root_x, root_y, win_x, win_y;
    unsigned int mask;
    if (!XQueryPointer(dpy, win, &root, &child, &root_x, &root_y, &win_x, &win_y, &mask))
        return 0;
    *x = win_x;
    *y = win_y;
    return 1;
}

static int run_cmd_into_buf(const char *cmd, char *buf, int buflen) {
    if (buflen <= 0) return 0;
    buf[0] = 0;

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        snprintf(buf, buflen, "Failed to run command.");
        return (int)strlen(buf);
    }

    int n = 0;
    while (n < buflen - 1) {
        int c = fgetc(fp);
        if (c == EOF) break;
        buf[n++] = (char)c;
    }
    buf[n] = 0;

    pclose(fp);
    return n;
}

int shim_netstat(char *buf, int buflen) {
    const char *cmd =
        "sh -c '"
        "if command -v netstat >/dev/null 2>&1; then "
        "  netstat -tunap 2>/dev/null | head -n 200; "
        "else "
        "  ss -tunap 2>/dev/null | head -n 200; "
        "fi'";
    return run_cmd_into_buf(cmd, buf, buflen);
}

int shim_ps_tree(char *buf, int buflen) {
    const char *cmd =
        "sh -c 'ps -e --forest -o pid,ppid,tty,stat,cmd --sort pid 2>/dev/null | head -n 400'";
    return run_cmd_into_buf(cmd, buf, buflen);
}

// Read /proc/net/dev and format RX/TX bytes per interface.
int shim_netdev(char *buf, int buflen) {
    if (buflen <= 0) return 0;
    buf[0] = 0;

    FILE *fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        snprintf(buf, buflen, "Failed to open /proc/net/dev");
        return (int)strlen(buf);
    }

    // Skip 2 header lines
    char line[512];
    (void)fgets(line, sizeof(line), fp);
    (void)fgets(line, sizeof(line), fp);

    int n = 0;
    n += snprintf(buf + n, (size_t)(buflen - n),
                  "Interface                 RX_bytes            TX_bytes\n"
                  "------------------------------------------------------\n");

    while (fgets(line, sizeof(line), fp)) {
        // Format: "  eth0: <rx bytes> ... <tx bytes> ..."
        char ifname[64] = {0};
        unsigned long long rx = 0, tx = 0;

        // Parse interface name before ':'
        char *colon = strchr(line, ':');
        if (!colon) continue;
        *colon = 0;

        // Trim spaces
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        snprintf(ifname, sizeof(ifname), "%s", s);

        // Restore and parse numbers after colon
        char *nums = colon + 1;

        // /proc/net/dev after ':' has 16 numbers:
        // receive: bytes packets errs drop fifo frame compressed multicast
        // transmit: bytes packets errs drop fifo colls carrier compressed
        // We only need rx bytes (#1) and tx bytes (#9)
        unsigned long long vals[16] = {0};
        int got = sscanf(nums,
                         " %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                         &vals[0], &vals[1], &vals[2], &vals[3], &vals[4], &vals[5], &vals[6], &vals[7],
                         &vals[8], &vals[9], &vals[10], &vals[11], &vals[12], &vals[13], &vals[14], &vals[15]);
        if (got < 10) continue;

        rx = vals[0];
        tx = vals[8];

        if (n < buflen - 1) {
            n += snprintf(buf + n, (size_t)(buflen - n),
                          "%-20s %20llu %20llu\n", ifname, rx, tx);
        }
        if (n >= buflen - 1) break;
    }

    fclose(fp);
    return n;
}

// Count number of lines in text (NUL-terminated).
int shim_count_lines(const char *text) {
    if (!text || !*text) return 0;
    int lines = 1;
    for (const char *p = text; *p; p++) {
        if (*p == '\n') lines++;
    }
    return lines;
}

// Copy a slice of lines into dst:
// start_line is 0-based. Copies up to max_lines lines.
// Returns bytes written (excluding NUL).
int shim_slice_lines(const char *src, char *dst, int dstlen, int start_line, int max_lines) {
    if (!dst || dstlen <= 0) return 0;
    dst[0] = 0;
    if (!src || !*src || max_lines <= 0) return 0;
    if (start_line < 0) start_line = 0;

    // Advance to start_line
    const char *p = src;
    int cur = 0;
    while (*p && cur < start_line) {
        if (*p == '\n') cur++;
        p++;
    }

    int written = 0;
    int lines_out = 0;
    while (*p && written < dstlen - 1 && lines_out < max_lines) {
        char c = *p++;
        dst[written++] = c;
        if (c == '\n') lines_out++;
    }
    dst[written] = 0;
    return written;
}
