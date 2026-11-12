/* STAND-IN, to be deleted when asks/aether-quickjs-async-eval-and-interrupt.md
 * lands in contrib.quickjs. Three things a nib Run needs that contrib.quickjs
 * does not expose yet:
 *   - global eval with JS_EVAL_FLAG_ASYNC (top-level await AND the script's
 *     completion value, which a module eval does not give);
 *   - an interrupt handler the host controls (a cancel flag and a deadline it
 *     moves itself, so the JS budget accumulates across entries instead of
 *     restarting per entry);
 *   - JS_PromiseState on a handle.
 * It mirrors contrib.quickjs's AeQjs layout (aether_quickjs.c, 0.909.0) and
 * declares the few QuickJS entry points it calls rather than including
 * quickjs.h, which no include path reaches from here. 64-bit only, like the
 * mirror. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct JSRuntime JSRuntime;
typedef struct JSContext JSContext;
typedef union { int32_t int32; double float64; void *ptr; int32_t sbi; } NibJSValueUnion;
typedef struct { NibJSValueUnion u; int64_t tag; } NibJSValue;
#define NIB_JS_TAG_EXCEPTION 6
#define NIB_JS_EVAL_FLAG_ASYNC (1 << 7)

typedef struct { void *fn; void *env; } NibAeClosure;
typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    NibJSValue *vals;
    unsigned char *used;
    int cap;
    int *free_list;
    int nfree;
    int live;
    NibAeClosure *fns;
    int nfns, capfns;
    int64_t limit_ms;
    int64_t deadline_ms;
} NibAeQjsMirror;

extern NibJSValue JS_Eval(JSContext *ctx, const char *input, size_t len, const char *filename, int flags);
extern NibJSValue JS_GetGlobalObject(JSContext *ctx);
extern int JS_SetPropertyStr(JSContext *ctx, NibJSValue this_obj, const char *prop, NibJSValue val);
extern void JS_FreeValue(JSContext *ctx, NibJSValue v);
extern NibJSValue JS_GetException(JSContext *ctx);
extern int JS_PromiseState(JSContext *ctx, NibJSValue promise);
extern void JS_SetInterruptHandler(JSRuntime *rt, int (*cb)(JSRuntime *, void *), void *opaque);
extern void JS_UpdateStackTop(JSRuntime *rt);
extern int64_t aether_sync_atomic_load(void *cell);

typedef struct {
    NibAeQjsMirror *q;
    void *cancel;          /* std.sync cell, nonzero = canceled; may be NULL */
    int64_t deadline_ns;   /* 0 = no JS running */
    int reason;            /* 0 none, 1 deadline, 2 cancel */
} NibWatch;

static int64_t nib_now_ns_(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int nib_interrupt_(JSRuntime *rt, void *opaque) {
    NibWatch *w = (NibWatch *)opaque;
    (void)rt;
    if (w->cancel && aether_sync_atomic_load(w->cancel) != 0) { if (!w->reason) w->reason = 2; return 1; }
    if (w->deadline_ns != 0 && nib_now_ns_() >= w->deadline_ns) { if (!w->reason) w->reason = 1; return 1; }
    return 0;
}

void *nibqjs_watch(void *qp, void *cancel_cell) {
    NibWatch *w = (NibWatch *)calloc(1, sizeof(NibWatch));
    if (!w) return NULL;
    w->q = (NibAeQjsMirror *)qp;
    w->cancel = cancel_cell;
    JS_SetInterruptHandler(w->q->rt, nib_interrupt_, w);
    return w;
}

void nibqjs_unwatch(void *wp) {
    NibWatch *w = (NibWatch *)wp;
    if (!w) return;
    JS_SetInterruptHandler(w->q->rt, NULL, NULL);
    free(w);
}

/* JS may run until `remaining_ns` from now (<= 0: stop at the next check). */
void nibqjs_begin(void *wp, int64_t remaining_ns) {
    NibWatch *w = (NibWatch *)wp;
    int64_t now = nib_now_ns_();
    w->deadline_ns = remaining_ns > 0 ? now + remaining_ns : now;
    JS_UpdateStackTop(w->q->rt);
}

void nibqjs_end(void *wp) { ((NibWatch *)wp)->deadline_ns = 0; }
int nibqjs_reason(void *wp) { return ((NibWatch *)wp)->reason; }
int64_t nibqjs_now_ns(void) { return nib_now_ns_(); }

/* Global eval with top-level await. 0: globalThis[result_name] is the Run's
 * promise (resolving to { value }). -1: globalThis[exc_name] is the thrown
 * value (a SyntaxError, or an interrupt). */
int nibqjs_eval_async(void *wp, const char *code, const char *filename,
                      const char *result_name, const char *exc_name) {
    NibWatch *w = (NibWatch *)wp;
    JSContext *ctx = w->q->ctx;
    NibJSValue v = JS_Eval(ctx, code, strlen(code), filename, NIB_JS_EVAL_FLAG_ASYNC);
    NibJSValue g = JS_GetGlobalObject(ctx);
    int rc = 0;
    if (v.tag == NIB_JS_TAG_EXCEPTION) {
        JS_SetPropertyStr(ctx, g, exc_name, JS_GetException(ctx));
        rc = -1;
    } else {
        JS_SetPropertyStr(ctx, g, result_name, v);
    }
    JS_FreeValue(ctx, g);
    return rc;
}

/* globalThis[name] = the settled value of promise handle h. */
extern NibJSValue JS_PromiseResult(JSContext *ctx, NibJSValue promise);
void nibqjs_promise_result_to_global(void *wp, int h, const char *name) {
    NibWatch *w = (NibWatch *)wp;
    NibAeQjsMirror *q = w->q;
    if (h <= 0 || h >= q->cap || !q->used[h]) return;
    NibJSValue g = JS_GetGlobalObject(q->ctx);
    JS_SetPropertyStr(q->ctx, g, name, JS_PromiseResult(q->ctx, q->vals[h]));
    JS_FreeValue(q->ctx, g);
}

/* -1 not a promise, 0 pending, 1 fulfilled, 2 rejected. */
int nibqjs_promise_state(void *wp, int h) {
    NibWatch *w = (NibWatch *)wp;
    NibAeQjsMirror *q = w->q;
    if (h <= 0 || h >= q->cap || !q->used[h]) return -1;
    return JS_PromiseState(q->ctx, q->vals[h]);
}
