/* STAND-IN, to be deleted when asks/aether-fs-stat-flock-exclusive.md is
 * answered in std.fs. POSIX file primitives the file tools need and std.fs
 * does not expose yet: a stat with inode, mode bits and nanosecond mtime;
 * advisory whole-file locks (flock) on a lock file kept open; exclusive
 * creation with a mode; write/fchmod/fsync on that descriptor; the error
 * name of an errno in the spelling upstream nib reports (Zig's error names). */
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdint.h>
#include <signal.h>
#include <termios.h>

/* Matches the Aether struct nib.sysgap.Stat field for field. */
typedef struct { int kind; int mode; int64_t ino; int64_t size; int64_t mtime_ns; int64_t dev; } NibStat;

/* kind: 1 file, 2 directory, 3 symlink, 4 other. 0 or errno. */
int nibsys_stat(const char *path, int follow, void *out) {
    struct stat st;
    int rc = follow ? stat(path, &st) : lstat(path, &st);
    if (rc != 0) return errno ? errno : EIO;
    NibStat *s = (NibStat *)out;
    s->kind = S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : S_ISLNK(st.st_mode) ? 3 : 4;
    s->mode = (int)(st.st_mode & 07777);
    s->ino = (int64_t)st.st_ino;
    s->size = (int64_t)st.st_size;
#if defined(__APPLE__)
    s->mtime_ns = (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
    s->mtime_ns = (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
    s->dev = (int64_t)st.st_dev;
    return 0;
}

int nibsys_errno(void) { return errno; }

const char *nibsys_errname(int e) {
    switch (e) {
    case ENOENT: return "FileNotFound";
    case EACCES: case EPERM: return "AccessDenied";
    case EISDIR: return "IsDir";
    case ENOTDIR: return "NotDir";
    case ELOOP: return "SymLinkLoop";
    case ENAMETOOLONG: return "NameTooLong";
    case EEXIST: return "PathAlreadyExists";
    case ENOSPC: return "NoSpaceLeft";
    case EROFS: return "ReadOnlyFileSystem";
    case EXDEV: return "RenameAcrossMountPoints";
    case EBUSY: return "DeviceBusy";
    case EFBIG: return "FileTooBig";
    case EINVAL: return "InvalidArgument";
    default: return "Unexpected";
    }
}

/* A descriptor for the lock file (created 0600, never truncated), or -errno. */
int nibsys_lock_open(const char *path) {
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    return fd < 0 ? -errno : fd;
}

/* 1 locked, 0 held elsewhere, -errno on error. */
int nibsys_try_lock(int fd) {
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) return 1;
    return errno == EWOULDBLOCK ? 0 : -errno;
}

int nibsys_close(int fd) { return close(fd); }

int64_t nibsys_fd_size(int fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    return (int64_t)st.st_size;
}

int nibsys_fd_truncate(int fd, int64_t n) { return ftruncate(fd, (off_t)n) == 0 ? 0 : -errno; }

/* O_EXCL creation; a descriptor or -errno. */
int nibsys_create_excl(const char *path, int mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
    return fd < 0 ? -errno : fd;
}

int nibsys_write_all(int fd, const char *data, int64_t n) {
    int64_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, data + off, (size_t)(n - off));
        if (w < 0) { if (errno == EINTR) continue; return -errno; }
        off += w;
    }
    return 0;
}

/* Positional write of all n bytes at offset (the Session log appends at its
   own offset, so a torn tail is overwritten rather than appended after). */
int nibsys_pwrite_all(int fd, const char *data, int64_t n, int64_t offset) {
    int64_t off = 0;
    while (off < n) {
        ssize_t w = pwrite(fd, data + off, (size_t)(n - off), (off_t)(offset + off));
        if (w < 0) { if (errno == EINTR) continue; return -errno; }
        off += w;
    }
    return 0;
}

int nibsys_fchmod(int fd, int mode) { return fchmod(fd, (mode_t)mode) == 0 ? 0 : -errno; }
int nibsys_fsync(int fd) { return fsync(fd) == 0 ? 0 : -errno; }
int nibsys_rename(const char *from, const char *to) { return rename(from, to) == 0 ? 0 : -errno; }
int nibsys_unlink(const char *path) { return unlink(path) == 0 ? 0 : -errno; }
int nibsys_chmod(const char *path, int mode) { return chmod(path, (mode_t)mode) == 0 ? 0 : -errno; }
int nibsys_mkdir(const char *path, int mode) { return mkdir(path, (mode_t)mode) == 0 ? 0 : -errno; }

/* The process environment, for building a child's (std.os has getenv only). */
extern char **environ;
int nibsys_environ_count(void) { int n = 0; while (environ && environ[n]) n++; return n; }
const char *nibsys_environ_get(int i) { return environ[i]; }

/* SIGINT/SIGTERM as a flag the Session polls (nib ask's cancellation;
   asks/aether-signal-handlers.md). The handler only stores the number. */
static volatile sig_atomic_t nibsys_signal = 0;
static void nibsys_on_signal(int sig) { nibsys_signal = sig; }
int nibsys_watch_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = nibsys_on_signal;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGINT, &sa, 0) != 0) return -errno;
    if (sigaction(SIGTERM, &sa, 0) != 0) return -errno;
    return 0;
}
int nibsys_signal_received(void) { return (int)nibsys_signal; }

/* A child's stdin writer must see EPIPE, not die of SIGPIPE: std.ipc's
   write_some to a full pipe whose reader died raises it
   (asks/aether-ipc-write-sigpipe.md). */
int nibsys_ignore_sigpipe(void) { return signal(SIGPIPE, SIG_IGN) == SIG_ERR ? -errno : 0; }

/* Terminal echo on stdin (nib login's masked key entry). 1 changed, 0 not a tty. */
int nibsys_stdin_echo(int on) {
    struct termios t;
    if (!isatty(0) || tcgetattr(0, &t) != 0) return 0;
    if (on) t.c_lflag |= ECHO; else t.c_lflag &= ~(tcflag_t)ECHO;
    return tcsetattr(0, TCSANOW, &t) == 0 ? 1 : 0;
}
