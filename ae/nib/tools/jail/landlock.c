/* Upstream src/tools/bash/jail.zig's Landlock mechanism (restrict, probe),
 * ported as C because Aether has no raw syscalls: a write-only ruleset over
 * the writable roots, PR_SET_NO_NEW_PRIVS, landlock_restrict_self. Called
 * only by `nib __jail <root>... -- <command>...` in the bash child, never in
 * nib's own process. A STAND-IN for an Aether primitive (asks/
 * aether-landlock-write-roots.md); std.sandbox's kernel layer restricts
 * reads, processes and the network too, which nib's workspace mode leaves open. */
#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#include <string.h>
#include <stdint.h>
#ifdef __linux__
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#define __NR_landlock_add_rule 445
#define __NR_landlock_restrict_self 446
#endif
#define LL_CREATE_VERSION 1u
#define LL_RULE_PATH_BENEATH 1
#define LL_WRITE_FILE (1ull << 1)
#define LL_BASE_WRITE ((0x1ffull << 4) | LL_WRITE_FILE)
#define LL_REFER (1ull << 13)
#define LL_TRUNCATE (1ull << 14)
struct nib_ll_attr { uint64_t handled; };
struct __attribute__((packed)) nib_ll_rule { uint64_t allowed; int32_t parent; };

/* 0 available, 1 no Landlock, 2 disabled, 3 ABI below 2. */
int nibjail_probe(void) {
    long abi = syscall(__NR_landlock_create_ruleset, NULL, 0, LL_CREATE_VERSION);
    if (abi < 0) return errno == EOPNOTSUPP ? 2 : 1;
    return abi >= 2 ? 0 : 3;
}

/* roots: '\n'-separated canonical paths. 0 or -1. */
int nibjail_restrict(const char *roots) {
    long abi = syscall(__NR_landlock_create_ruleset, NULL, 0, LL_CREATE_VERSION);
    if (abi < 0) return -1;
    uint64_t handled = LL_BASE_WRITE;
    if (abi >= 2) handled |= LL_REFER;
    if (abi >= 3) handled |= LL_TRUNCATE;
    struct nib_ll_attr attr = { handled };
    long fd = syscall(__NR_landlock_create_ruleset, &attr, sizeof attr, 0);
    if (fd < 0) return -1;
    const char *p = roots;
    char path[4096];
    while (*p) {
        const char *e = strchr(p, '\n');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n > 0 && n < sizeof path) {
            memcpy(path, p, n);
            path[n] = 0;
            int parent = open(path, O_PATH | O_CLOEXEC);
            if (parent >= 0) {
                uint64_t tries[2] = { handled, handled & (LL_WRITE_FILE | LL_TRUNCATE) };
                for (int i = 0; i < 2; i++) {
                    struct nib_ll_rule rule = { tries[i], parent };
                    if (syscall(__NR_landlock_add_rule, fd, LL_RULE_PATH_BENEATH, &rule, 0) == 0) break;
                }
                close(parent);
            }
        }
        if (!e) break;
        p = e + 1;
    }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
    if (syscall(__NR_landlock_restrict_self, fd, 0) != 0) return -1;
    close((int)fd);
    return 0;
}
#else
int nibjail_probe(void) { return 4; }
int nibjail_restrict(const char *roots) { (void)roots; return -1; }
#endif
