#include "rcl_bridge.h"

#include <rcl/rcl.h>
#include <rcl/publisher.h>
// rcl_error_string_t / rcl_get_error_string / rcl_reset_error (capture_error()).
// Included explicitly for the symbols this TU uses rather than relying on the
// CRos2 module re-exporting it: the modulemap declares CRos2.h as a
// plain (non-umbrella) header, so `#include <rcl/...>` resolves textually and
// only brings what each header transitively pulls in.
#include <rcl/error_handling.h>
// rcl_serialized_message_t is typedef'd in <rcl/types.h>, pulled in by <rcl/rcl.h>.
// There is no standalone <rcl/serialized_message.h> in this distribution.
#include <rmw/qos_profiles.h>
#include <rmw/serialized_message.h>
#include <rcutils/allocator.h>
#include <rosidl_runtime_c/message_type_support_struct.h>
#include <rmw/rmw.h>                              // rmw_serialize
#include <rosidl_runtime_c/string_functions.h>   // rosidl_runtime_c__String__assign / __fini
// Publisher struct body + crcl__set_error / crcl__capture_rcl_error definitions.
// (crcl_marshal_resolve_typesupport is declared via crcl_marshal.h, pulled in
// by rcl_bridge.h above.)
#include "crcl_internal.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

struct crcl_context_s {
    rcl_context_t ctx;
    rcl_init_options_t opts;
};
// struct crcl_node_s lives in crcl_internal.h (shared with rcl_subscription.c).

#ifdef _Thread_local
#define CRCL_THREAD_LOCAL _Thread_local
#elif defined(__GNUC__) || defined(__clang__)
#define CRCL_THREAD_LOCAL __thread
#else
#define CRCL_THREAD_LOCAL
#endif
static CRCL_THREAD_LOCAL char g_err[1024] = {0};

static void capture_error(void) {
    rcl_error_string_t s = rcl_get_error_string();
    strncpy(g_err, s.str, sizeof(g_err) - 1);
    g_err[sizeof(g_err) - 1] = '\0';
    rcl_reset_error();
}
const char *crcl_last_error(void) { return g_err; }

// Error helpers shared with the other bridge C sources (crcl_internal.h).
void crcl__set_error(const char *msg) {
    strncpy(g_err, msg, sizeof(g_err) - 1);
    g_err[sizeof(g_err) - 1] = '\0';
}
void crcl__capture_rcl_error(void) { capture_error(); }

// Type-name -> typesupport table. Delegates to the generated registry
// (crcl_marshal_resolve_typesupport) so every emitted type resolves without a
// hand-maintained switch here.
static const rosidl_message_type_support_t *resolve_typesupport(const char *ros_type_name) {
    return crcl_marshal_resolve_typesupport(ros_type_name);
}

crcl_context_t *crcl_context_create(size_t domain_id) {
    crcl_context_t *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->opts = rcl_get_zero_initialized_init_options();
    c->ctx = rcl_get_zero_initialized_context();
    rcl_allocator_t alloc = rcl_get_default_allocator();
    if (rcl_init_options_init(&c->opts, alloc) != RCL_RET_OK) {
        capture_error();
        free(c);
        return NULL;
    }
    if (rcl_init_options_set_domain_id(&c->opts, domain_id) != RCL_RET_OK) {
        capture_error();
        (void)rcl_init_options_fini(&c->opts);
        free(c);
        return NULL;
    }
    if (rcl_init(0, NULL, &c->opts, &c->ctx) != RCL_RET_OK) {
        capture_error();
        (void)rcl_init_options_fini(&c->opts);
        free(c);
        return NULL;
    }
    return c;
}

void crcl_context_destroy(crcl_context_t *c) {
    if (!c) return;
    if (rcl_context_is_valid(&c->ctx)) {
        (void)rcl_shutdown(&c->ctx);
    }
    (void)rcl_context_fini(&c->ctx);
    (void)rcl_init_options_fini(&c->opts);
    free(c);
}

crcl_node_t *crcl_node_create(crcl_context_t *c, const char *name, const char *ns) {
    if (!c) return NULL;
    crcl_node_t *n = calloc(1, sizeof(*n));
    if (!n) return NULL;
    n->node = rcl_get_zero_initialized_node();
    n->ctx = &c->ctx;  // Jazzy has no rcl_node_get_context(); see crcl_internal.h.
    rcl_node_options_t nopts = rcl_node_get_default_options();
    if (rcl_node_init(&n->node, name, ns, &c->ctx, &nopts) != RCL_RET_OK) {
        capture_error();
        free(n);
        return NULL;
    }
    return n;
}

void crcl_node_destroy(crcl_node_t *n) {
    if (!n) return;
    (void)rcl_node_fini(&n->node);
    free(n);
}

crcl_publisher_t *crcl_publisher_create(
    crcl_node_t *n, const char *ros_type_name, const char *topic, crcl_qos_t q) {
    if (!n) return NULL;
    const rosidl_message_type_support_t *ts = resolve_typesupport(ros_type_name);
    if (!ts) {
        // Not an rcl error — no rcl error state to clear; set g_err directly.
        snprintf(g_err, sizeof(g_err), "unsupported type: %s", ros_type_name);
        return NULL;
    }
    crcl_publisher_t *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->pub = rcl_get_zero_initialized_publisher();
    p->node = &n->node;
    rcl_publisher_options_t popts = rcl_publisher_get_default_options();
    popts.qos = rmw_qos_profile_default;
    popts.qos.reliability =
        q.reliability ? RMW_QOS_POLICY_RELIABILITY_RELIABLE : RMW_QOS_POLICY_RELIABILITY_BEST_EFFORT;
    popts.qos.durability =
        q.durability ? RMW_QOS_POLICY_DURABILITY_TRANSIENT_LOCAL : RMW_QOS_POLICY_DURABILITY_VOLATILE;
    popts.qos.history =
        q.history ? RMW_QOS_POLICY_HISTORY_KEEP_ALL : RMW_QOS_POLICY_HISTORY_KEEP_LAST;
    popts.qos.depth = q.depth;
    if (rcl_publisher_init(&p->pub, &n->node, ts, topic, &popts) != RCL_RET_OK) {
        capture_error();
        free(p);
        return NULL;
    }
    return p;
}

void crcl_publisher_destroy(crcl_publisher_t *p) {
    if (!p) return;
    (void)rcl_publisher_fini(&p->pub, p->node);
    free(p);
}

int crcl_publisher_subscription_count(crcl_publisher_t *p) {
    if (!p) {
        snprintf(g_err, sizeof(g_err), "crcl_publisher_subscription_count: NULL publisher");
        return -1;
    }
    size_t count = 0;
    if (rcl_publisher_get_subscription_count(&p->pub, &count) != RCL_RET_OK) {
        capture_error();
        return -1;
    }
    return count > (size_t)INT_MAX ? INT_MAX : (int)count;
}

int crcl_publish_serialized(crcl_publisher_t *p, const uint8_t *data, size_t len) {
    if (!p) return -1;
    rcl_serialized_message_t ser = rmw_get_zero_initialized_serialized_message();
    // Borrow the caller's buffer; rcl_publish_serialized_message only reads it.
    ser.buffer = (uint8_t *)data;
    ser.buffer_length = len;
    ser.buffer_capacity = len;
    ser.allocator = rcutils_get_default_allocator();
    rcl_ret_t ret = rcl_publish_serialized_message(&p->pub, &ser, NULL);
    if (ret != RCL_RET_OK) {
        capture_error();
        return (int)ret;
    }
    return 0;
}
