/* The POSIX pieces Aether's std does not offer yet (asks/terminal-control.md):
 * raw mode with a saved termios, the window size, SIGWINCH, waiting on input
 * with a timeout, and putting the terminal back however the process ends.
 *
 * Signal dispositions and atexit are process-wide, so the one piece of
 * process-wide state here is the table of terminals to restore: each slot
 * holds a terminal's fd, its original termios and the bytes that undo what
 * the program turned on (alternate screen, mouse, paste, kitty keys). A
 * normal close restores the slot and frees it; exit(), a fatal signal
 * (SIGSEGV, SIGABRT from a panic, SIGBUS, SIGFPE, SIGILL) and a polite one
 * (SIGTERM, SIGHUP, SIGINT, SIGQUIT) restore every open slot before the
 * process goes, with async-signal-safe calls only.
 *
 * Windows is not done here: the console needs SetConsoleMode with
 * ENABLE_VIRTUAL_TERMINAL_INPUT/PROCESSING and ReadConsoleInput; until then
 * every entry point fails with -1 there (see README, "Windows").
 */
#if defined(_WIN32)

int aeterm_open_tty(void) { return -1; }
int aeterm_close_fd(int fd) { (void)fd; return -1; }
int aeterm_is_tty(int fd) { (void)fd; return 0; }
int aeterm_raw_enter(int fd) { (void)fd; return -1; }
int aeterm_set_leave(int slot, const char *b, int n) { (void)slot; (void)b; (void)n; return -1; }
int aeterm_raw_leave(int slot) { (void)slot; return -1; }
int aeterm_cols(int fd) { (void)fd; return -1; }
int aeterm_rows(int fd) { (void)fd; return -1; }
int aeterm_set_size(int fd, int c, int r) { (void)fd; (void)c; (void)r; return -1; }
int aeterm_wait(int fd, int t) { (void)fd; (void)t; return -1; }
int aeterm_take_winch(void) { return 0; }
int aeterm_read(int fd, void *b, int n) { (void)fd; (void)b; (void)n; return -1; }
int aeterm_write(int fd, const char *d, int n) { (void)fd; (void)d; (void)n; return -1; }
long long aeterm_monotonic_ms(void) { return 0; }
int aeterm_openpty(void) { return -1; }
int aeterm_pty_slave(int m) { (void)m; return -1; }
int aeterm_raise(int sig) { (void)sig; return -1; }
/* 1 when fd's line discipline is raw (no echo, no canonical input, no
 * signal keys), 0 when not, -1 when fd is no terminal. For tests. */
int aeterm_is_raw(int fd) {
    struct termios t;
    if (tcgetattr(fd, &t) != 0) return -1;
    return (t.c_lflag & (ECHO | ICANON | ISIG)) == 0 ? 1 : 0;
}

int aeterm_slot_count(void) { return 0; }
int aeterm_is_raw(int fd) { (void)fd; return -1; }

#else

#if defined(__linux__)
#define _DEFAULT_SOURCE 1
#define _XOPEN_SOURCE 700
#endif
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/time.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define SLOTS 8
#define LEAVE_MAX 512

struct slot {
    volatile sig_atomic_t used;
    int fd;
    struct termios saved;
    char leave[LEAVE_MAX];
    volatile sig_atomic_t leave_len;
};

static struct slot slots[SLOTS];
static int winch_pipe[2] = { -1, -1 };
static int installed = 0;
static int atexit_done = 0;

static const int fatal[] = { SIGTERM, SIGHUP, SIGINT, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL };
#define NFATAL ((int)(sizeof fatal / sizeof fatal[0]))
static struct sigaction old_fatal[NFATAL];
static struct sigaction old_winch;

static void write_all(int fd, const char *p, int n) {
    while (n > 0) {
        ssize_t w = write(fd, p, (size_t)n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return;
        }
        p += w;
        n -= (int)w;
    }
}

static void restore_slot(struct slot *s) {
    if (!s->used) return;
    s->used = 0;
    if (s->leave_len > 0) write_all(s->fd, s->leave, s->leave_len);
    /* TCSANOW, not TCSAFLUSH: the latter waits for the output to drain,
     * which never happens when the terminal has gone (SIGHUP) or nobody
     * reads the other end of a pty. Output is processed as it is written,
     * so nothing already sent is reinterpreted. */
    tcflush(s->fd, TCIFLUSH);
    tcsetattr(s->fd, TCSANOW, &s->saved);
}

static void restore_all(void) {
    for (int i = 0; i < SLOTS; i++) restore_slot(&slots[i]);
}

static void on_fatal(int sig) {
    int saved_errno = errno;
    restore_all();
    /* Back to what was there before us, then let the signal do what it
     * would have: end the process (or run the program's own handler). */
    for (int i = 0; i < NFATAL; i++) {
        if (fatal[i] == sig) {
            sigaction(sig, &old_fatal[i], NULL);
            break;
        }
    }
    errno = saved_errno;
    raise(sig);
}

static void on_winch(int sig) {
    (void)sig;
    int saved_errno = errno;
    char b = 1;
    if (winch_pipe[1] >= 0) (void)!write(winch_pipe[1], &b, 1);
    errno = saved_errno;
}

long long aeterm_monotonic_ms(void);

static int install(void) {
    if (installed) return 0;
    if (winch_pipe[0] < 0) {
        if (pipe(winch_pipe) != 0) return -1;
        for (int i = 0; i < 2; i++) {
            fcntl(winch_pipe[i], F_SETFL, fcntl(winch_pipe[i], F_GETFL) | O_NONBLOCK);
            fcntl(winch_pipe[i], F_SETFD, FD_CLOEXEC);
        }
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sa.sa_handler = on_winch;
    sa.sa_flags = SA_RESTART;
    sigaction(SIGWINCH, &sa, &old_winch);
    for (int i = 0; i < NFATAL; i++) {
        struct sigaction fa;
        memset(&fa, 0, sizeof fa);
        sigemptyset(&fa.sa_mask);
        fa.sa_handler = on_fatal;
        fa.sa_flags = SA_RESETHAND;
        sigaction(fatal[i], &fa, &old_fatal[i]);
    }
    if (!atexit_done) {
        atexit(restore_all);
        atexit_done = 1;
    }
    installed = 1;
    return 0;
}

static void uninstall_if_idle(void) {
    for (int i = 0; i < SLOTS; i++) if (slots[i].used) return;
    if (!installed) return;
    sigaction(SIGWINCH, &old_winch, NULL);
    for (int i = 0; i < NFATAL; i++) sigaction(fatal[i], &old_fatal[i], NULL);
    installed = 0;
}

int aeterm_open_tty(void) {
    return open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
}

int aeterm_close_fd(int fd) { return close(fd); }

int aeterm_is_tty(int fd) { return isatty(fd) ? 1 : 0; }

/* Saves fd's termios, makes it raw (libvaxis's makeRaw: no echo, no
 * canonical input, no signals from keys, no CR/NL translation either way,
 * 8-bit, read returns after one byte) and registers it for restoring.
 * Returns the slot, or -1 (not a terminal, or eight already open). */
int aeterm_raw_enter(int fd) {
    struct termios t;
    if (tcgetattr(fd, &t) != 0) return -1;
    int s = -1;
    for (int i = 0; i < SLOTS; i++) if (!slots[i].used) { s = i; break; }
    if (s < 0) return -1;
    if (install() != 0) return -1;
    slots[s].fd = fd;
    slots[s].saved = t;
    slots[s].leave_len = 0;
    struct termios raw = t;
    raw.c_iflag &= ~(tcflag_t)(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    raw.c_oflag &= ~(tcflag_t)OPOST;
    raw.c_lflag &= ~(tcflag_t)(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    raw.c_cflag &= ~(tcflag_t)(CSIZE | PARENB);
    raw.c_cflag |= CS8;
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcflush(fd, TCIFLUSH);
    if (tcsetattr(fd, TCSANOW, &raw) != 0) return -1;
    slots[s].used = 1;
    return s;
}

/* The bytes written before the termios is restored, on any exit. */
int aeterm_set_leave(int slot, const char *bytes, int len) {
    if (slot < 0 || slot >= SLOTS || len < 0 || len > LEAVE_MAX) return -1;
    slots[slot].leave_len = 0;
    memcpy(slots[slot].leave, bytes, (size_t)len);
    slots[slot].leave_len = len;
    return 0;
}

/* Writes the leave bytes, restores the termios, frees the slot. */
int aeterm_raw_leave(int slot) {
    if (slot < 0 || slot >= SLOTS || !slots[slot].used) return -1;
    restore_slot(&slots[slot]);
    uninstall_if_idle();
    return 0;
}

/* 1 when fd's line discipline is raw (no echo, no canonical input, no
 * signal keys), 0 when not, -1 when fd is no terminal. For tests. */
int aeterm_is_raw(int fd) {
    struct termios t;
    if (tcgetattr(fd, &t) != 0) return -1;
    return (t.c_lflag & (ECHO | ICANON | ISIG)) == 0 ? 1 : 0;
}

int aeterm_slot_count(void) {
    int n = 0;
    for (int i = 0; i < SLOTS; i++) if (slots[i].used) n++;
    return n;
}

int aeterm_cols(int fd) {
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return -1;
    return ws.ws_col;
}

int aeterm_rows(int fd) {
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return -1;
    return ws.ws_row;
}

/* Sets a pty's size (tests drive resizes with it). */
int aeterm_set_size(int fd, int cols, int rows) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

/* Waits up to timeout_ms (-1: forever) for input on fd or a SIGWINCH.
 * Returns 1 for input, 2 for a resize, 3 for both, 0 on timeout, -1 on
 * error. A resize is reported until aeterm_take_winch drains it.
 *
 * select(2), not poll(2): macOS's poll answers POLLNVAL for /dev/tty, so a
 * program reading its controlling terminal would never see a key. */
int aeterm_wait(int fd, int timeout_ms) {
    if (fd < 0 || fd >= FD_SETSIZE || winch_pipe[0] >= FD_SETSIZE) return -1;
    long long deadline = timeout_ms >= 0 ? aeterm_monotonic_ms() + timeout_ms : -1;
    for (;;) {
        fd_set rd;
        FD_ZERO(&rd);
        FD_SET(fd, &rd);
        int top = fd;
        if (winch_pipe[0] >= 0) {
            FD_SET(winch_pipe[0], &rd);
            if (winch_pipe[0] > top) top = winch_pipe[0];
        }
        struct timeval tv, *tvp = NULL;
        if (deadline >= 0) {
            long long left = deadline - aeterm_monotonic_ms();
            if (left < 0) left = 0;
            tv.tv_sec = (time_t)(left / 1000);
            tv.tv_usec = (suseconds_t)((left % 1000) * 1000);
            tvp = &tv;
        }
        int r = select(top + 1, &rd, NULL, NULL, tvp);
        if (r < 0) {
            if (errno == EINTR) {
                /* a SIGWINCH lands here: report it now */
                if (winch_pipe[0] >= 0) {
                    fd_set w;
                    struct timeval zero = { 0, 0 };
                    FD_ZERO(&w);
                    FD_SET(winch_pipe[0], &w);
                    if (select(winch_pipe[0] + 1, &w, NULL, NULL, &zero) > 0) return 2;
                }
                continue;
            }
            return -1;
        }
        int out = 0;
        if (FD_ISSET(fd, &rd)) out |= 1;
        if (winch_pipe[0] >= 0 && FD_ISSET(winch_pipe[0], &rd)) out |= 2;
        return out;
    }
}

/* How many SIGWINCHs arrived since the last call. */
int aeterm_take_winch(void) {
    char buf[64];
    int total = 0;
    if (winch_pipe[0] < 0) return 0;
    for (;;) {
        ssize_t r = read(winch_pipe[0], buf, sizeof buf);
        if (r <= 0) break;
        total += (int)r;
    }
    return total;
}

/* One read(2) of up to cap bytes: the count, 0 at end of input, -1 on error. */
int aeterm_read(int fd, void *buf, int cap) {
    for (;;) {
        ssize_t r = read(fd, buf, (size_t)cap);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        return (int)r;
    }
}

/* Writes all of it: len, or -1. */
int aeterm_write(int fd, const char *data, int len) {
    int left = len;
    while (left > 0) {
        ssize_t w = write(fd, data, (size_t)left);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd p = { fd, POLLOUT, 0 };
                poll(&p, 1, 100);
                continue;
            }
            return -1;
        }
        data += w;
        left -= (int)w;
    }
    return len;
}

long long aeterm_monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* A pseudo-terminal for tests: the master's fd, -1 on failure. */
int aeterm_openpty(void) {
    int m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0) return -1;
    if (grantpt(m) != 0 || unlockpt(m) != 0) {
        close(m);
        return -1;
    }
    fcntl(m, F_SETFD, FD_CLOEXEC);
    return m;
}

/* Opens the slave side of a master from aeterm_openpty. */
int aeterm_pty_slave(int master) {
    char *name = ptsname(master);
    if (name == NULL) return -1;
    return open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
}

int aeterm_raise(int sig) { return raise(sig); }

#endif
