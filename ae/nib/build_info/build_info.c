/* The commit the binary was built from: ae/nib/build_info/commit.h, which
   .build.ae writes (gitignored) before it builds; none without it. */
#if defined(__has_include)
#if __has_include("commit.h")
#include "commit.h"
#endif
#endif
#ifndef NIB_COMMIT
#define NIB_COMMIT ""
#endif
const char *nib_build_commit(void) { return NIB_COMMIT; }
