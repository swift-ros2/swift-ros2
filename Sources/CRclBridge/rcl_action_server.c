#include "rcl_bridge.h"

#include <rcl/rcl.h>
#include <rcl/guard_condition.h>
#include <rcl/time.h>  // rcl_ros_clock_init / rcl_clock_fini
#include <rcl/wait.h>
// rcl_reset_error for the wait-thread loop (rcl/rcutils error state is
// thread-local, so failures on the wait thread only need a reset there).
#include <rcl/error_handling.h>
#include <rcl_action/action_server.h>
#include <rcl_action/goal_handle.h>
#include <rcl_action/types.h>
#include <rcl_action/wait.h>
#include <rmw/rmw.h>  // rmw_serialize / rmw_deserialize
#include <rmw/serialized_message.h>
#include <rmw/types.h>  // rmw_request_id_t
#include <rcutils/allocator.h>
// crcl_node_s body (stored rcl_context_t*) + crcl__set_error /
// crcl__capture_rcl_error + the shared request-id blob pack helpers.
#include "crcl_internal.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct crcl_action_server_s {
    rcl_action_server_t server;
    rcl_node_t *node;  // borrowed; node must outlive the action server
    rcl_clock_t clock;
    const crcl_action_entry_t *entry;
    // action_msgs/srv/CancelGoal — the cancel half rides the M7 srv registry
    // (request/response message typesupports + __create/__destroy wrappers).
    const crcl_srv_entry_t *cancel_entry;
    rcl_guard_condition_t stop_gc;
    rcl_wait_set_t wait_set;
    pthread_t thread;
    atomic_bool stop;
    // Serializes the wait thread's takes / expiry against every caller-thread
    // rcl_action_* call (sends, feedback/status publishes, goal bookkeeping) —
    // rcl_action documents none of those pairings as thread-safe. Same M7
    // doctrine: held only across the rcl call, never across rcl_wait or the
    // callback.
    pthread_mutex_t io_mutex;
    crcl_action_server_callback_t cb;
    void *cb_ctx;
};

// Find the rcl-tracked goal handle for a 16-byte goal id. Must be called with
// io_mutex held — the handle array is invalidated by rcl_action_expire_goals
// on the wait thread. Returns NULL when the goal is not tracked.
static rcl_action_goal_handle_t *crcl__find_goal_handle(
    crcl_action_server_t *s, const uint8_t *uuid) {
    rcl_action_goal_handle_t **handles = NULL;
    size_t num_goals = 0;
    if (rcl_action_server_get_goal_handles(&s->server, &handles, &num_goals) != RCL_RET_OK) {
        // Reset the thread-local rcl error state: the caller reports its own
        // "unknown goal id" diagnostic and a stale error would otherwise
        // pollute (or trigger overwrite warnings on) later captures.
        rcl_reset_error();
        return NULL;
    }
    for (size_t i = 0; i < num_goals; i++) {
        rcl_action_goal_info_t info = rcl_action_get_zero_initialized_goal_info();
        if (rcl_action_goal_handle_get_info(handles[i], &info) != RCL_RET_OK) {
            rcl_reset_error();
            continue;
        }
        if (memcmp(info.goal_id.uuid, uuid, 16) == 0) {
            return handles[i];
        }
    }
    return NULL;
}

// One drained take for a request role: allocate the serialized buffer and the
// typed struct BEFORE the take (M4 pattern — an allocation failure leaves the
// request queued in the middleware), take under io_mutex, rmw_serialize, and
// hand the bytes + packed request id to the callback. Returns false when the
// drain loop for this role should stop (nothing pending, or a failure).
static bool crcl__action_server_take_one(
    crcl_action_server_t *s, int role,
    void *(*create_fn)(void), void (*destroy_fn)(void *),
    const rosidl_message_type_support_t *(*ts_fn)(void),
    rcl_ret_t (*take_fn)(const rcl_action_server_t *, rmw_request_id_t *, void *)) {
    rcl_serialized_message_t msg = rmw_get_zero_initialized_serialized_message();
    rcutils_allocator_t alloc = crcl__zeroing_allocator();
    if (rmw_serialized_message_init(&msg, 0, &alloc) != RMW_RET_OK) {
        rcl_reset_error();
        return false;
    }
    void *request = create_fn();
    if (!request) {
        (void)rmw_serialized_message_fini(&msg);
        return false;  // allocation failure — back to waiting
    }
    rmw_request_id_t header;
    memset(&header, 0, sizeof(header));
    pthread_mutex_lock(&s->io_mutex);
    rcl_ret_t take = take_fn(&s->server, &header, request);
    pthread_mutex_unlock(&s->io_mutex);
    if (take != RCL_RET_OK) {
        destroy_fn(request);
        (void)rmw_serialized_message_fini(&msg);
        // RCL_RET_ACTION_SERVER_TAKE_FAILED == nothing pending (not an
        // error); anything else is a real failure — either way stop draining
        // this role and go back to waiting.
        rcl_reset_error();
        return false;
    }
    if (rmw_serialize(request, ts_fn(), &msg) == RMW_RET_OK) {
        uint8_t blob[CRCL_REQUEST_ID_SIZE];
        crcl__pack_request_id(&header, blob);
        s->cb(s->cb_ctx, role, blob, msg.buffer, msg.buffer_length);
    } else {
        rcl_reset_error();
    }
    (void)rmw_serialized_message_fini(&msg);
    destroy_fn(request);
    return true;
}

// Per-action-server wait thread: rcl_wait on {3 services + expiry timer via
// rcl_action_wait_set_add_action_server, stop guard condition} with a 100 ms
// timeout, then drain every ready role (serialize-shim, spec §20.6). The wait
// set is touched by this thread only; crcl_action_server_destroy joins it
// before any fini. Caller-thread rcl_action calls overlap only under io_mutex
// (see struct comment).
static void *crcl__action_server_thread_main(void *arg) {
    crcl_action_server_t *s = arg;
    const int64_t timeout_ns = 100LL * 1000 * 1000;  // 100 ms
    while (!atomic_load(&s->stop)) {
        if (rcl_wait_set_clear(&s->wait_set) != RCL_RET_OK) {
            rcl_reset_error();
            break;  // wait set unusable — stop delivering rather than spin
        }
        if (rcl_action_wait_set_add_action_server(&s->wait_set, &s->server, NULL) != RCL_RET_OK) {
            rcl_reset_error();
            break;
        }
        if (rcl_wait_set_add_guard_condition(&s->wait_set, &s->stop_gc, NULL) != RCL_RET_OK) {
            rcl_reset_error();
            break;
        }
        rcl_ret_t ret = rcl_wait(&s->wait_set, timeout_ns);
        if (ret == RCL_RET_TIMEOUT) continue;
        if (ret != RCL_RET_OK) {
            rcl_reset_error();
            continue;
        }
        if (atomic_load(&s->stop)) break;
        bool goal_ready = false;
        bool cancel_ready = false;
        bool result_ready = false;
        bool goal_expired = false;
        if (rcl_action_server_wait_set_get_entities_ready(
                &s->wait_set, &s->server, &goal_ready, &cancel_ready, &result_ready, &goal_expired)
            != RCL_RET_OK) {
            rcl_reset_error();
            continue;
        }
        if (goal_expired) {
            // Terminal goals past result_timeout: let rcl drop them (this
            // also recalculates the expiry timer). The Swift side keeps no
            // per-goal state that needs the expired ids.
            pthread_mutex_lock(&s->io_mutex);
            if (rcl_action_expire_goals(&s->server, NULL, 0, NULL) != RCL_RET_OK) {
                rcl_reset_error();
            }
            pthread_mutex_unlock(&s->io_mutex);
        }
        // Drain each ready role until the middleware reports nothing pending,
        // re-checking the stop flag per take (M4 pattern — bounds destroy
        // latency under sustained load).
        if (goal_ready) {
            while (!atomic_load(&s->stop)
                   && crcl__action_server_take_one(
                       s, CRCL_ACTION_SERVER_GOAL_REQUEST,
                       s->entry->send_goal_request_create, s->entry->send_goal_request_destroy,
                       s->entry->send_goal_request_typesupport, rcl_action_take_goal_request)) {
            }
        }
        if (cancel_ready) {
            while (!atomic_load(&s->stop)
                   && crcl__action_server_take_one(
                       s, CRCL_ACTION_SERVER_CANCEL_REQUEST,
                       s->cancel_entry->request_create, s->cancel_entry->request_destroy,
                       s->cancel_entry->request_typesupport, rcl_action_take_cancel_request)) {
            }
        }
        if (result_ready) {
            while (!atomic_load(&s->stop)
                   && crcl__action_server_take_one(
                       s, CRCL_ACTION_SERVER_RESULT_REQUEST,
                       s->entry->get_result_request_create, s->entry->get_result_request_destroy,
                       s->entry->get_result_request_typesupport, rcl_action_take_result_request)) {
            }
        }
    }
    return NULL;
}

crcl_action_server_t *crcl_action_server_create(
    crcl_node_t *n, const char *action_type_name, const char *action_name,
    const crcl_qos_t *q, crcl_action_server_callback_t cb, void *ctx) {
    if (!n || !q || !cb) {
        crcl__set_error("crcl_action_server_create: NULL node/qos/callback");
        return NULL;
    }
    const crcl_action_entry_t *entry = crcl_action_registry_lookup(action_type_name);
    if (!entry) {
        // Not an rcl error — no rcl error state to capture; set the message directly.
        char msg[256];
        snprintf(
            msg, sizeof(msg), "unsupported action type: %s",
            action_type_name ? action_type_name : "(null)");
        crcl__set_error(msg);
        return NULL;
    }
    const crcl_srv_entry_t *cancel_entry = crcl_srv_registry_lookup("action_msgs/srv/CancelGoal");
    if (!cancel_entry) {
        crcl__set_error("crcl_action_server_create: action_msgs/srv/CancelGoal missing from srv registry");
        return NULL;
    }
    crcl_action_server_t *s = calloc(1, sizeof(*s));
    if (!s) {
        crcl__set_error("crcl_action_server_create: out of memory");
        return NULL;
    }
    s->node = &n->node;
    s->entry = entry;
    s->cancel_entry = cancel_entry;
    s->cb = cb;
    s->cb_ctx = ctx;
    atomic_init(&s->stop, false);

    // rcl_action_server_init requires a clock (goal-info stamps + the
    // result_timeout expiry timer). ROS time matches the rclcpp default.
    rcl_allocator_t allocator = rcl_get_default_allocator();
    if (rcl_ros_clock_init(&s->clock, &allocator) != RCL_RET_OK) {
        crcl__capture_rcl_error();
        free(s);
        return NULL;
    }

    s->server = rcl_action_get_zero_initialized_server();
    rcl_action_server_options_t sopts = rcl_action_server_get_default_options();
    // The four crcl_qos_t fields override the three service profiles and the
    // feedback topic. The status topic keeps rcl's status default
    // (transient_local, keep_last 1) — exactly what the wire transports pin.
    rmw_qos_profile_t *profiles[] = {
        &sopts.goal_service_qos, &sopts.cancel_service_qos, &sopts.result_service_qos,
        &sopts.feedback_topic_qos,
    };
    for (size_t i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++) {
        profiles[i]->reliability = q->reliability ? RMW_QOS_POLICY_RELIABILITY_RELIABLE
                                                  : RMW_QOS_POLICY_RELIABILITY_BEST_EFFORT;
        profiles[i]->durability = q->durability ? RMW_QOS_POLICY_DURABILITY_TRANSIENT_LOCAL
                                                : RMW_QOS_POLICY_DURABILITY_VOLATILE;
        profiles[i]->history =
            q->history ? RMW_QOS_POLICY_HISTORY_KEEP_ALL : RMW_QOS_POLICY_HISTORY_KEEP_LAST;
        profiles[i]->depth = q->depth;
    }
    if (rcl_action_server_init(
            &s->server, &n->node, &s->clock, entry->action_typesupport(), action_name, &sopts)
        != RCL_RET_OK) {
        crcl__capture_rcl_error();
        (void)rcl_clock_fini(&s->clock);
        free(s);
        return NULL;
    }

    s->stop_gc = rcl_get_zero_initialized_guard_condition();
    if (rcl_guard_condition_init(&s->stop_gc, n->ctx, rcl_guard_condition_get_default_options())
        != RCL_RET_OK) {
        crcl__capture_rcl_error();
        (void)rcl_action_server_fini(&s->server, s->node);
        (void)rcl_clock_fini(&s->clock);
        free(s);
        return NULL;
    }

    // Size the wait set from rcl_action's own entity counts (3 services + 1
    // expiry timer on Jazzy) plus the stop guard condition.
    size_t num_subs = 0, num_gcs = 0, num_timers = 0, num_clients = 0, num_services = 0;
    if (rcl_action_server_wait_set_get_num_entities(
            &s->server, &num_subs, &num_gcs, &num_timers, &num_clients, &num_services)
        != RCL_RET_OK) {
        crcl__capture_rcl_error();
        (void)rcl_guard_condition_fini(&s->stop_gc);
        (void)rcl_action_server_fini(&s->server, s->node);
        (void)rcl_clock_fini(&s->clock);
        free(s);
        return NULL;
    }
    s->wait_set = rcl_get_zero_initialized_wait_set();
    if (rcl_wait_set_init(
            &s->wait_set, num_subs, num_gcs + 1, num_timers, num_clients, num_services, 0, n->ctx,
            rcl_get_default_allocator())
        != RCL_RET_OK) {
        crcl__capture_rcl_error();
        (void)rcl_guard_condition_fini(&s->stop_gc);
        (void)rcl_action_server_fini(&s->server, s->node);
        (void)rcl_clock_fini(&s->clock);
        free(s);
        return NULL;
    }

    if (pthread_mutex_init(&s->io_mutex, NULL) != 0) {
        crcl__set_error("crcl_action_server_create: pthread_mutex_init failed");
        (void)rcl_wait_set_fini(&s->wait_set);
        (void)rcl_guard_condition_fini(&s->stop_gc);
        (void)rcl_action_server_fini(&s->server, s->node);
        (void)rcl_clock_fini(&s->clock);
        free(s);
        return NULL;
    }

    if (pthread_create(&s->thread, NULL, crcl__action_server_thread_main, s) != 0) {
        crcl__set_error("crcl_action_server_create: pthread_create failed");
        (void)pthread_mutex_destroy(&s->io_mutex);
        (void)rcl_wait_set_fini(&s->wait_set);
        (void)rcl_guard_condition_fini(&s->stop_gc);
        (void)rcl_action_server_fini(&s->server, s->node);
        (void)rcl_clock_fini(&s->clock);
        free(s);
        return NULL;
    }
    return s;
}

// Shared deserialize-and-send body for the three response roles. `buf` is
// borrowed (rmw_deserialize only reads it); the typed struct is __destroy'd
// on every path.
static int crcl__action_server_send(
    crcl_action_server_t *s, const uint8_t *request_id, const uint8_t *buf, size_t len,
    const char *what,
    void *(*create_fn)(void), void (*destroy_fn)(void *),
    const rosidl_message_type_support_t *(*ts_fn)(void),
    rcl_ret_t (*send_fn)(const rcl_action_server_t *, rmw_request_id_t *, void *)) {
    if (!s || !request_id) {
        crcl__set_error("crcl_action_server send: NULL server/request_id");
        return -1;
    }
    // Valid CDR is at least the 4-byte encapsulation header — mirror the
    // Swift-side check instead of feeding a short buffer to rmw_deserialize.
    if (!buf || len < 4) {
        char msg[128];
        snprintf(msg, sizeof(msg), "%s: buffer missing 4-byte CDR encapsulation header", what);
        crcl__set_error(msg);
        return -1;
    }
    void *response = create_fn();
    if (!response) {
        char msg[128];
        snprintf(msg, sizeof(msg), "%s: response create failed", what);
        crcl__set_error(msg);
        return -1;
    }
    rcl_serialized_message_t ser = rmw_get_zero_initialized_serialized_message();
    ser.buffer = (uint8_t *)buf;
    ser.buffer_length = len;
    ser.buffer_capacity = len;
    ser.allocator = rcutils_get_default_allocator();
    if (rmw_deserialize(&ser, ts_fn(), response) != RMW_RET_OK) {
        crcl__capture_rcl_error();
        destroy_fn(response);
        return -1;
    }
    rmw_request_id_t id;
    crcl__unpack_request_id(request_id, &id);
    pthread_mutex_lock(&s->io_mutex);
    rcl_ret_t ret = send_fn(&s->server, &id, response);
    pthread_mutex_unlock(&s->io_mutex);
    destroy_fn(response);
    if (ret != RCL_RET_OK) {
        crcl__capture_rcl_error();
        return (int)ret;
    }
    return 0;
}

int crcl_action_server_send_goal_response(
    crcl_action_server_t *s, const uint8_t *request_id, const uint8_t *buf, size_t len) {
    if (!s) {
        crcl__set_error("crcl_action_server_send_goal_response: NULL server");
        return -1;
    }
    return crcl__action_server_send(
        s, request_id, buf, len, "crcl_action_server_send_goal_response",
        s->entry->send_goal_response_create, s->entry->send_goal_response_destroy,
        s->entry->send_goal_response_typesupport, rcl_action_send_goal_response);
}

int crcl_action_server_send_cancel_response(
    crcl_action_server_t *s, const uint8_t *request_id, const uint8_t *buf, size_t len) {
    if (!s) {
        crcl__set_error("crcl_action_server_send_cancel_response: NULL server");
        return -1;
    }
    return crcl__action_server_send(
        s, request_id, buf, len, "crcl_action_server_send_cancel_response",
        s->cancel_entry->response_create, s->cancel_entry->response_destroy,
        s->cancel_entry->response_typesupport, rcl_action_send_cancel_response);
}

int crcl_action_server_send_result_response(
    crcl_action_server_t *s, const uint8_t *request_id, const uint8_t *buf, size_t len) {
    if (!s) {
        crcl__set_error("crcl_action_server_send_result_response: NULL server");
        return -1;
    }
    // A goal that terminated without a result body (canceled / aborted)
    // arrives as the minimal frame [header (4) | status (1) | pad (3)] — the
    // umbrella caches an empty result CDR for those terminal states.
    // rmw_deserialize would fail on the truncated buffer (the typed
    // GetResult_Response always contains a complete result struct), so build
    // the typed response directly: a zero-initialized result (rosidl
    // __create) plus the status byte. rosidl emits `int8 status` as the
    // FIRST field of every action's GetResult_Response, so writing it
    // through an int8_t* is layout-safe for every registry entry. A full
    // response can never be 8 bytes: even an empty rosidl message
    // contributes a dummy byte past the status padding.
    if (request_id && buf && len == 8) {
        void *response = s->entry->get_result_response_create();
        if (!response) {
            crcl__set_error("crcl_action_server_send_result_response: response create failed");
            return -1;
        }
        *(int8_t *)response = (int8_t)buf[4];
        rmw_request_id_t id;
        crcl__unpack_request_id(request_id, &id);
        pthread_mutex_lock(&s->io_mutex);
        rcl_ret_t ret = rcl_action_send_result_response(&s->server, &id, response);
        pthread_mutex_unlock(&s->io_mutex);
        s->entry->get_result_response_destroy(response);
        if (ret != RCL_RET_OK) {
            crcl__capture_rcl_error();
            return (int)ret;
        }
        return 0;
    }
    // `buf` is the complete GetResult_Response [header (4) | status (1) |
    // result], encoded in one pass so the result keeps the alignment origin
    // rmw_deserialize expects (see ActionFrameDecoder.encodeGetResultResponse).
    return crcl__action_server_send(
        s, request_id, buf, len, "crcl_action_server_send_result_response",
        s->entry->get_result_response_create, s->entry->get_result_response_destroy,
        s->entry->get_result_response_typesupport, rcl_action_send_result_response);
}

int crcl_action_server_publish_feedback(crcl_action_server_t *s, const uint8_t *buf, size_t len) {
    if (!s) {
        crcl__set_error("crcl_action_server_publish_feedback: NULL server");
        return -1;
    }
    if (!buf || len < 4) {
        crcl__set_error(
            "crcl_action_server_publish_feedback: buffer missing 4-byte CDR encapsulation header");
        return -1;
    }
    void *feedback = s->entry->feedback_message_create();
    if (!feedback) {
        crcl__set_error("crcl_action_server_publish_feedback: feedback create failed");
        return -1;
    }
    rcl_serialized_message_t ser = rmw_get_zero_initialized_serialized_message();
    ser.buffer = (uint8_t *)buf;
    ser.buffer_length = len;
    ser.buffer_capacity = len;
    ser.allocator = rcutils_get_default_allocator();
    if (rmw_deserialize(&ser, s->entry->feedback_message_typesupport(), feedback) != RMW_RET_OK) {
        crcl__capture_rcl_error();
        s->entry->feedback_message_destroy(feedback);
        return -1;
    }
    pthread_mutex_lock(&s->io_mutex);
    rcl_ret_t ret = rcl_action_publish_feedback(&s->server, feedback);
    pthread_mutex_unlock(&s->io_mutex);
    s->entry->feedback_message_destroy(feedback);
    if (ret != RCL_RET_OK) {
        crcl__capture_rcl_error();
        return (int)ret;
    }
    return 0;
}

int crcl_action_server_publish_status(crcl_action_server_t *s) {
    if (!s) {
        crcl__set_error("crcl_action_server_publish_status: NULL server");
        return -1;
    }
    pthread_mutex_lock(&s->io_mutex);
    rcl_action_goal_status_array_t arr = rcl_action_get_zero_initialized_goal_status_array();
    rcl_ret_t ret = rcl_action_get_goal_status_array(&s->server, &arr);
    if (ret == RCL_RET_OK) {
        ret = rcl_action_publish_status(&s->server, &arr.msg);
    }
    if (ret != RCL_RET_OK) {
        // Capture BEFORE the fini below: a failing fini would overwrite the
        // thread-local rcl error state and the captured message would
        // describe the fini instead of the real failure.
        crcl__capture_rcl_error();
    }
    (void)rcl_action_goal_status_array_fini(&arr);
    pthread_mutex_unlock(&s->io_mutex);
    return ret != RCL_RET_OK ? (int)ret : 0;
}

int crcl_action_server_accept_goal(
    crcl_action_server_t *s, const uint8_t *uuid, int32_t stamp_sec, uint32_t stamp_nanosec) {
    if (!s || !uuid) {
        crcl__set_error("crcl_action_server_accept_goal: NULL server/uuid");
        return -1;
    }
    rcl_action_goal_info_t info = rcl_action_get_zero_initialized_goal_info();
    memcpy(info.goal_id.uuid, uuid, 16);
    info.stamp.sec = stamp_sec;
    info.stamp.nanosec = stamp_nanosec;
    pthread_mutex_lock(&s->io_mutex);
    if (rcl_action_server_goal_exists(&s->server, &info)) {
        // Already tracked — idempotent success (the response path and the
        // status-publish path can both race to accept first).
        pthread_mutex_unlock(&s->io_mutex);
        return 0;
    }
    rcl_action_goal_handle_t *handle = rcl_action_accept_new_goal(&s->server, &info);
    pthread_mutex_unlock(&s->io_mutex);
    if (!handle) {
        crcl__capture_rcl_error();
        return -1;
    }
    // rcl tracks the handle internally (rcl_action_server_get_goal_handles);
    // it is finalized by goal expiry or rcl_action_server_fini. No C-side
    // bookkeeping beyond rcl's own.
    return 0;
}

int crcl_action_server_update_goal_state(
    crcl_action_server_t *s, const uint8_t *uuid, int event) {
    if (!s || !uuid) {
        crcl__set_error("crcl_action_server_update_goal_state: NULL server/uuid");
        return -1;
    }
    if (event < CRCL_GOAL_EVENT_EXECUTE || event > CRCL_GOAL_EVENT_CANCELED) {
        crcl__set_error("crcl_action_server_update_goal_state: invalid event");
        return -1;
    }
    pthread_mutex_lock(&s->io_mutex);
    rcl_action_goal_handle_t *handle = crcl__find_goal_handle(s, uuid);
    if (!handle) {
        pthread_mutex_unlock(&s->io_mutex);
        crcl__set_error("crcl_action_server_update_goal_state: unknown goal id");
        return -1;
    }
    rcl_ret_t ret = rcl_action_update_goal_state(handle, (rcl_action_goal_event_t)event);
    pthread_mutex_unlock(&s->io_mutex);
    if (ret != RCL_RET_OK) {
        crcl__capture_rcl_error();
        return (int)ret;
    }
    return 0;
}

int crcl_action_server_notify_goal_done(crcl_action_server_t *s) {
    if (!s) {
        crcl__set_error("crcl_action_server_notify_goal_done: NULL server");
        return -1;
    }
    pthread_mutex_lock(&s->io_mutex);
    rcl_ret_t ret = rcl_action_notify_goal_done(&s->server);
    pthread_mutex_unlock(&s->io_mutex);
    if (ret != RCL_RET_OK) {
        crcl__capture_rcl_error();
        return (int)ret;
    }
    return 0;
}

int crcl_action_server_destroy(crcl_action_server_t *s) {
    if (!s) return 0;
    // Refuse a self-destroy from the take callback: pthread_join on the
    // calling thread cannot block on itself, so proceeding to fini/free would
    // leave the wait thread dereferencing freed memory the moment the
    // callback returns. Leak the server instead and surface an error.
    if (pthread_equal(pthread_self(), s->thread)) {
        crcl__set_error(
            "crcl_action_server_destroy called from the take callback; destroy from another thread");
        return -1;
    }
    // Join BEFORE any fini (M4/M7 teardown): the wait thread reads `server` /
    // `wait_set` until it exits, and the join guarantees any in-flight
    // callback has returned before the Swift side releases its context.
    atomic_store(&s->stop, true);
    (void)rcl_trigger_guard_condition(&s->stop_gc);
    if (pthread_join(s->thread, NULL) != 0) {
        crcl__set_error("crcl_action_server_destroy: pthread_join failed");
        return -1;
    }
    (void)pthread_mutex_destroy(&s->io_mutex);
    int rc = 0;
    if (rcl_action_server_fini(&s->server, s->node) != RCL_RET_OK) {
        crcl__capture_rcl_error();
        rc = 1;
    }
    if (rcl_guard_condition_fini(&s->stop_gc) != RCL_RET_OK) {
        crcl__capture_rcl_error();
        rc = 1;
    }
    if (rcl_wait_set_fini(&s->wait_set) != RCL_RET_OK) {
        crcl__capture_rcl_error();
        rc = 1;
    }
    // The clock outlives the server fini (the server borrows it).
    if (rcl_clock_fini(&s->clock) != RCL_RET_OK) {
        crcl__capture_rcl_error();
        rc = 1;
    }
    free(s);
    return rc;
}
