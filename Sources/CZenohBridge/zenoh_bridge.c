//
// zenoh_bridge.c
// C-FFI bridge implementation for zenoh-pico
//

#include "zenoh_bridge.h"
#include <zenoh-pico.h>
#include <zenoh-pico/api/liveliness.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

// Portable mutex shim. Windows does not ship <pthread.h>; the rest of the
// supported platforms (Apple, Linux, Android Bionic) all do. The C bridge
// only needs a non-recursive mutex for the queryable outstanding-query
// list, so we map the small surface to either pthread or Win32
// CRITICAL_SECTION.
#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
typedef CRITICAL_SECTION zenoh_mutex_t;
#  define zenoh_mutex_init(m)    InitializeCriticalSection(m)
#  define zenoh_mutex_destroy(m) DeleteCriticalSection(m)
#  define zenoh_mutex_lock(m)    EnterCriticalSection(m)
#  define zenoh_mutex_unlock(m)  LeaveCriticalSection(m)
#else
#  include <pthread.h>
#  include <fcntl.h>
#  include <sys/socket.h>
#  include <sys/time.h>
#  include <unistd.h>
typedef pthread_mutex_t zenoh_mutex_t;
#  define zenoh_mutex_init(m)    pthread_mutex_init(m, NULL)
#  define zenoh_mutex_destroy(m) pthread_mutex_destroy(m)
#  define zenoh_mutex_lock(m)    pthread_mutex_lock(m)
#  define zenoh_mutex_unlock(m)  pthread_mutex_unlock(m)
#endif

#ifdef __APPLE__
  #include <os/log.h>
#else
  /* Non-Apple platforms: stub out Apple's unified logging to stderr. */
  typedef int os_log_t;
  #define os_log_create(subsystem, category) 0
  #define os_log_info(log, fmt, ...)  \
      fprintf(stderr, "[info]  " fmt "\n", ##__VA_ARGS__)
  #define os_log_error(log, fmt, ...) \
      fprintf(stderr, "[error] " fmt "\n", ##__VA_ARGS__)
  #define os_log_debug(log, fmt, ...) \
      fprintf(stderr, "[debug] " fmt "\n", ##__VA_ARGS__)
  #define os_log(log, fmt, ...)       \
      fprintf(stderr, fmt "\n", ##__VA_ARGS__)
#endif

// The bridge requires the swift-ros2 fork of zenoh-pico at 1.10 or later, built
// with Z_FEATURE_MULTI_THREAD: the build fails on anything older, on headers
// without the version macros and on a single-thread configuration. It relies
// on what 1.10 does: one executor thread per session runs the read, lease and
// keep-alive tasks, and every call on a session that lost its transport
// returns (see zenoh_bridge_transport_lost and "Calls on a session that lost
// its transport"). It also calls _z_transport_is_lost, which the fork adds.
// Every swift-ros2 build is on that source: Linux, Android and Windows compile
// vendor/zenoh-pico, whose committed config.h sets Z_FEATURE_MULTI_THREAD, and
// the Apple build links the CZenohPico xcframework built from it with the same
// options. Up to and including 3.2.0-rc.1 the Apple build linked zenoh-pico
// 1.7.1, and the bridge carried a second code path for it.
#if !defined(ZENOH_PICO_MAJOR) || !defined(ZENOH_PICO_MINOR) || \
    !(ZENOH_PICO_MAJOR > 1 || (ZENOH_PICO_MAJOR == 1 && ZENOH_PICO_MINOR >= 10))
#  error "CZenohBridge requires the swift-ros2 fork of zenoh-pico, 1.10 or later (ZENOH_PICO_MAJOR / ZENOH_PICO_MINOR in zenoh-pico.h): update vendor/zenoh-pico, pin CZenohPico assets built from it in Package.swift, or rebuild build/zenoh-pico with Scripts/build-xcframework.sh"
#endif
#if Z_FEATURE_MULTI_THREAD != 1
#  error "CZenohBridge requires a zenoh-pico built with Z_FEATURE_MULTI_THREAD: the session's executor thread and the lost-transport checks depend on it"
#endif

// Advanced publication (zenoh-ext's AdvancedPublisher, used for TRANSIENT_LOCAL)
// is an unstable zenoh-pico API: its declarations only exist when the library is
// built with Z_FEATURE_UNSTABLE_API and Z_FEATURE_ADVANCED_PUBLICATION, so
// everything that names a ze_* symbol stays behind this macro.
#if defined(Z_FEATURE_UNSTABLE_API) && Z_FEATURE_ADVANCED_PUBLICATION == 1
#  define ZENOH_BRIDGE_ADVANCED_PUBLICATION 1
#else
#  define ZENOH_BRIDGE_ADVANCED_PUBLICATION 0
#endif

// Bounded sends (see zenoh_bridge_bound_sends). The bridge reaches the
// session's TCP socket through zenoh-pico's transport and link structs, which
// are internal to zenoh-pico, and only with POSIX sockets. The lost-transport
// checks (see zenoh_bridge_transport_lost) report the transport that a
// timed-out send leaves behind.
#if Z_FEATURE_LINK_TCP == 1 && !defined(_WIN32)
#  define ZENOH_BRIDGE_BOUNDED_SENDS 1
#else
#  define ZENOH_BRIDGE_BOUNDED_SENDS 0
#endif

// How long one send on the session's socket may wait for the network before it
// fails: zenoh's default for blocking messages (wait_before_close).
#define ZENOH_BRIDGE_SEND_TIMEOUT_MS 5000

// ============================================================================
// Internal structures
// ============================================================================

struct zenoh_session_t {
    z_owned_session_t session;
    // A duplicate descriptor of the session's TCP socket, or -1 when the
    // bridge does not bound its sends (see zenoh_bridge_bound_sends).
    int socket_fd;
};

struct zenoh_subscriber_t {
    z_owned_subscriber_t subscriber;
    zenoh_subscriber_callback_t callback;
    void* context;
};

struct zenoh_liveliness_token_t {
    z_owned_liveliness_token_t token;
};

// A plain publisher fills `publisher`; an advanced one fills `advanced` and
// leaves `publisher` uninitialized (the advanced publisher owns its own inner
// publisher). Always branch on `is_advanced` before touching either member.
struct zenoh_publisher_t {
    bool is_advanced;
    // Congestion control of the plain put path (an advanced publisher takes it
    // from its declaration options).
    z_congestion_control_t congestion_control;
    z_owned_publisher_t publisher;
#if ZENOH_BRIDGE_ADVANCED_PUBLICATION
    ze_owned_advanced_publisher_t advanced;
#endif
};

// Forward declarations for the linked-list cross-references between
// zenoh_query_t and zenoh_queryable_t.
struct zenoh_queryable_t;

struct zenoh_query_t {
    z_owned_query_t query;
    struct zenoh_queryable_t* owner;  // queryable that produced this query (for unlink)
    struct zenoh_query_t* next;       // singly-linked list of outstanding queries
    struct zenoh_query_t* prev;
};

struct zenoh_queryable_t {
    z_owned_queryable_t queryable;
    zenoh_queryable_callback_t callback;
    void* context;
    // Outstanding queries that the Swift side hasn't replied to yet. The
    // C bridge owns them; on undeclare, we walk this list and drop+free
    // every entry so a Swift handler that returns without replying does
    // not leak bridge state.
    struct zenoh_query_t* outstanding_head;
    zenoh_mutex_t outstanding_lock;
};

typedef struct {
    zenoh_get_reply_callback_t reply_callback;
    zenoh_get_finish_callback_t finish_callback;
    void* context;
} zenoh_get_callback_state_t;

// ============================================================================
// Internal helpers
// ============================================================================

// Copy a zenoh string view into a freshly malloc'd NUL-terminated C string.
// zenoh-pico strings are length+pointer with no terminator (_z_string_t is
// "A string with no terminator", vendor/zenoh-pico/include/zenoh-pico/
// collections/string.h:64-70), and z_keyexpr_as_view_string merely aliases
// the keyexpr suffix slice, so passing z_string_data() to a callback that
// expects a C string would read past the end of the slice. Returns NULL on
// allocation failure; callers substitute "" so the payload is still
// delivered.
static char* zenoh_string_dup_cstr(const z_loaned_string_t* s) {
    size_t len = z_string_len(s);
    char* cstr = (char*)malloc(len + 1);
    if (!cstr) {
        return NULL;
    }
    if (len > 0) {
        memcpy(cstr, z_string_data(s), len);
    }
    cstr[len] = '\0';
    return cstr;
}

// Whether an open session has lost its transport.
//
// zenoh-pico (built without auto-reconnect) does not close a client session
// whose router goes away: z_session_is_closed() stays false. A router that
// stops answering is noticed after one to two of its leases; one whose process
// dies on a reachable host is noticed sooner, when a keep-alive cannot be sent
// (a failed read is not taken as a loss). The lease task, the keep-alive task
// and a read task that cannot process a message all end in
// _zp_unicast_failed_result (src/transport/unicast/lease.c) on the session's
// executor thread, which keeps running afterwards. Nothing calls
// _z_interest_peer_disconnected in client mode, so every publisher's write
// filter (and with it the matching status) keeps its last value forever.
//
// That function marks the transport as failed, sends CLOSE, clears the
// transport (it destroys the transmit mutex and frees the buffers, the peer
// list and the link) and only then sets the type to _Z_TRANSPORT_NONE. The
// CLOSE can take the whole send timeout when the router no longer reads, so
// the type alone would report the loss seconds late, after the transport was
// destroyed. _z_transport_is_lost (added by the swift-ros2 fork of zenoh-pico)
// reads the mark, so the loss is reported from the start of that sequence. The
// fork also turns away every send, and the peer count of a get, that reaches
// zenoh-pico after the mark, and clears the transport only when the calls
// already inside have left. So a call that passed this check just before the
// failure does not touch a destroyed transport: a send fails, and a get
// returns 0 with its finish callback and no reply. The multicast failure path
// (_zp_multicast_failed_result) sets the same mark before it clears its
// transport.
//
// In peer mode, which the bridge never configures, a vanished peer is taken
// off the peer list under the peer mutex and updates matching, while the
// transport stays up: this check stays false there, as it should.
//
// Thread safety: callers run on any thread (the matching poll runs every 50 ms
// per publisher) concurrently with the executor thread running the failure
// path. _z_transport_is_lost reads only the transport type and the mark. Both
// live inside the session struct (the transport is embedded in it, not
// allocated), so they stay valid while the session is alive. Nothing here
// dereferences the peer list, the link or any other memory the failure path
// frees. The race is benign: the mark is atomic and stays set once the
// transport has failed, and the type is a plain enum that on an open session
// only goes from unicast to none, after the mark was set, so either value then
// reads as lost. A call that reads the mark just before it is set returns
// false, and the next call reports the loss. Do not use z_info_routers_zid or
// _z_session_has_router_peer here: both walk the peer list without the peer
// mutex and would race with its free.
static bool zenoh_bridge_transport_lost(const z_loaned_session_t* zs) {
    if (z_session_is_closed(zs)) {
        // A closed session is reported as closed, not as lost.
        return false;
    }
    return _z_transport_is_lost(&_Z_RC_IN_VAL(zs)->_tp);
}

// The zenoh-pico publisher behind a bridge publisher: an advanced publisher
// wraps a plain one.
static inline const z_loaned_publisher_t* zenoh_bridge_inner_publisher(zenoh_publisher_t* publisher) {
#if ZENOH_BRIDGE_ADVANCED_PUBLICATION
    if (publisher->is_advanced) {
        return z_publisher_loan(&z_loan(publisher->advanced)->_publisher);
    }
#endif
    return z_loan(publisher->publisher);
}

// Whether the session behind an entity's weak session reference has lost its
// transport. Upgrading the weak reference is a lock-free atomic count update;
// the strong reference keeps the session alive during the check. A session
// that is already gone counts as lost.
static inline bool zenoh_bridge_weak_session_lost(const _z_session_weak_t* zn) {
    _z_session_rc_t session = _z_session_weak_upgrade(zn);
    if (_Z_RC_IS_NULL(&session)) {
        return true;
    }
    bool lost = zenoh_bridge_transport_lost(&session);
    _z_session_rc_drop(&session);
    return lost;
}

// Whether the session a publisher was declared on has lost its transport.
//
// The session is reached through the publisher's own weak session reference
// (every zenoh-pico publisher operation does the same), so the caller needs
// neither the session handle nor any lock beyond the one that keeps the
// publisher declared. A session that is already gone counts as lost: its
// matching state is unknown.
static inline bool zenoh_bridge_publisher_transport_lost(zenoh_publisher_t* publisher) {
    return zenoh_bridge_weak_session_lost(&zenoh_bridge_inner_publisher(publisher)->_zn);
}

// Whether a bridge session has lost its transport.
static inline bool zenoh_bridge_session_lost(zenoh_session_t* session) {
    return zenoh_bridge_transport_lost(z_loan(session->session));
}

// Calls on a session that lost its transport.
//
// Every operation (put, get, declaration, matching status) is refused with
// ZENOH_ERROR_TRANSPORT_LOST before it reaches zenoh-pico, which would report
// some of them as successful although nothing can be sent: a get, and a put
// through a publisher whose frozen write filter knows no subscriber.
//
// Teardown runs as on a healthy session. zenoh-pico returns from each call on
// such a session and frees what the call owns: undeclaring an entity, replying
// to or dropping a received query, and z_close all return, some of them with
// an error (checked under AddressSanitizer with a killed and with a frozen
// router). So the session, its entities and its executor thread are released.

// Bounds every send on a session's TCP socket.
//
// zenoh-pico sends on a blocking socket with no send timeout, holding the
// session's transmit mutex. When the network stalls (the peer stops reading or
// the path drops every packet), the send buffer fills and that send blocks for
// as long as the stall lasts, with no upper bound on a zero window. Every
// other send then waits behind it: puts through publishers declared with
// block_on_congestion, query replies, declarations, and the keep-alive that
// the session's executor thread sends. That thread then runs nothing else, so
// the lease is never checked and nothing reports the stall. (DROP puts fail at
// once, but the one stuck in the send never returns.)
//
// SO_SNDTIMEO makes such a send fail after ZENOH_BRIDGE_SEND_TIMEOUT_MS. The
// link's write then reports _Z_ERR_TRANSPORT_TX_FAILED (-100), the transmit
// mutex is released, and zenoh_bridge_close_failed_link takes the link down.
//
// Called right after z_open, before any entity exists. Returns a duplicate
// descriptor of the socket for zenoh_bridge_close_failed_link, or -1 when sends
// stay unbounded (other link types, other builds). The duplicate keeps the
// socket alive until zenoh_close_session closes it, so the bridge can shut it
// down at any time without racing zenoh-pico's own close of its descriptor
// (whose number could otherwise be reused by an unrelated file).
static int zenoh_bridge_bound_sends(const z_loaned_session_t* zs) {
#if ZENOH_BRIDGE_BOUNDED_SENDS
    _z_session_t* s = _Z_RC_IN_VAL(zs);
    if (s->_tp._type != _Z_TRANSPORT_UNICAST_TYPE) {
        return -1;
    }
    const _z_link_t* link = s->_tp._transport._unicast._common._link;
    if (link == NULL || link->_type != _Z_LINK_TYPE_TCP) {
        return -1;
    }
    int fd = link->_socket._tcp._sock._fd;
    struct timeval timeout;
    timeout.tv_sec = ZENOH_BRIDGE_SEND_TIMEOUT_MS / 1000;
    timeout.tv_usec = (ZENOH_BRIDGE_SEND_TIMEOUT_MS % 1000) * 1000;
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) {
        return -1;
    }
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
#else
    (void)zs;
    return -1;
#endif
}

// Takes the session's link down after a put through a publisher declared with
// block_on_congestion failed with _Z_ERR_TRANSPORT_TX_FAILED.
//
// A blocking put never fails on the transmit mutex, so that error means one of
// two things. The write itself failed: the peer is gone, or the send timed out
// (see zenoh_bridge_bound_sends), possibly after writing part of a frame,
// which leaves the byte stream unusable. Or the put reached zenoh-pico while
// the transport was failing and was turned away (a put reports every failed
// send with this code); the link is going down then anyway. Without this,
// every send queued behind a failed write would wait out its own timeout in
// turn, and so would the keep-alive whose failure tells zenoh-pico that the
// transport is gone. shutdown() makes every later send fail at once instead,
// so the queue drains, a keep-alive fails, and the session's executor marks
// the transport lost (ZENOH_ERROR_TRANSPORT_LOST) within two keep-alive
// periods.
//
// It shuts the socket down through the bridge's duplicate descriptor (see
// zenoh_bridge_bound_sends), not through the transport, which the failure path
// may be freeing concurrently. Shutting the socket down also wakes a send
// blocked on it. It does so even when the transport is already lost: blocking
// puts that passed the lost-transport check before the failure path began may
// still wait for the transmit mutex, and the failure path waits for them
// before it clears the transport.
static void zenoh_bridge_close_failed_link(zenoh_session_t* session) {
#if ZENOH_BRIDGE_BOUNDED_SENDS
    if (session->socket_fd >= 0) {
        shutdown(session->socket_fd, SHUT_RDWR);
    }
#else
    (void)session;
#endif
}

// Releases the bridge's duplicate of the session's socket (see
// zenoh_bridge_bound_sends). `lost`: the transport is lost and zenoh-pico may
// have closed its own descriptor already, so this close can be the last one;
// abort the connection then, instead of lingering on unsent data in the
// caller's thread.
static void zenoh_bridge_release_socket(zenoh_session_t* session, bool lost) {
#if ZENOH_BRIDGE_BOUNDED_SENDS
    if (session->socket_fd < 0) {
        return;
    }
    if (lost) {
        struct linger abort_on_close;
        abort_on_close.l_onoff = 1;
        abort_on_close.l_linger = 0;
        setsockopt(session->socket_fd, SOL_SOCKET, SO_LINGER, &abort_on_close, sizeof(abort_on_close));
        shutdown(session->socket_fd, SHUT_RDWR);
    }
    close(session->socket_fd);
    session->socket_fd = -1;
#else
    (void)session;
    (void)lost;
#endif
}

// ============================================================================
// Session management
// ============================================================================

zenoh_result_t zenoh_open_session(const char* locator, zenoh_session_t** out_session) {
    os_log_t log = os_log_create("com.youtalk.swift-ros2", "zenoh");

    if (!locator || !out_session) {
        os_log_error(log, "[zenoh_bridge] ERROR: Invalid parameters");
        return -1;
    }

    os_log_info(log, "[zenoh_bridge] Opening session with locator: %s", locator);

    // Allocate session wrapper
    zenoh_session_t* session = (zenoh_session_t*)malloc(sizeof(zenoh_session_t));
    if (!session) {
        os_log_error(log, "[zenoh_bridge] ERROR: Failed to allocate session");
        return -1;
    }
    session->socket_fd = -1;

    // Create config
    z_owned_config_t config;
    int ret = z_config_default(&config);
    os_log_info(log, "[zenoh_bridge] z_config_default returned: %d", ret);
    if (ret < 0) {
        free(session);
        return -1;
    }

    // Set the connect mode and locator
    ret = zp_config_insert(z_loan_mut(config), Z_CONFIG_CONNECT_KEY, locator);
    os_log_info(log, "[zenoh_bridge] zp_config_insert returned: %d", ret);
    if (ret < 0) {
        z_drop(z_move(config));
        free(session);
        return -1;
    }

    // Open the session with default options: with NULL, z_open fills them in
    // itself (in multi-thread builds z_open_options_t has no __dummy field to
    // set) and starts the session's executor thread, which runs the read,
    // lease and keep-alive tasks.
    os_log_info(log, "[zenoh_bridge] Calling z_open...");
    os_log_info(log, "[zenoh_bridge] Using locator: %s", locator);

    ret = z_open(&session->session, z_move(config), NULL);
    os_log_info(log, "[zenoh_bridge] z_open returned: %d", ret);
    if (ret < 0) {
        os_log_error(log, "[zenoh_bridge] ERROR: z_open failed with code %d", ret);
        os_log_error(log, "[zenoh_bridge] Possible causes: network unreachable, router not running, or firewall blocking");
        os_log_error(log, "[zenoh_bridge] errno: %d (%s)", errno, strerror(errno));
        free(session);
        return -1;
    }

    session->socket_fd = zenoh_bridge_bound_sends(z_loan(session->session));

    // Start read and lease tasks for background processing. z_open already
    // started the executor that runs them, so these calls start nothing:
    // zp_start_read_task finds the executor running (it only waits for the
    // task step in progress, a read of up to 100 ms), and zp_start_lease_task
    // does nothing.
    os_log_info(log, "[zenoh_bridge] Starting read and lease tasks...");
    zp_start_read_task(z_loan_mut(session->session), NULL);
    zp_start_lease_task(z_loan_mut(session->session), NULL);

    os_log_info(log, "[zenoh_bridge] Session opened successfully");
    *out_session = session;
    return 0;
}

zenoh_result_t zenoh_close_session(zenoh_session_t** session) {
    if (!session || !*session) {
        return -1;
    }

    zenoh_session_t* s = *session;

    // A session that lost its transport is closed like any other: z_close has
    // nothing to send and releases the session.
    bool lost = zenoh_bridge_session_lost(s);

    if (lost) {
        // The executor may still be inside the failure path, sending CLOSE to
        // a router that no longer reads: stopping it below would wait for that
        // send to time out. Fail the send now.
        zenoh_bridge_close_failed_link(s);
    }

    // Stop background tasks: zp_stop_read_task stops the session's executor
    // (zp_stop_lease_task does nothing).
    zp_stop_read_task(z_loan_mut(s->session));
    zp_stop_lease_task(z_loan_mut(s->session));
    // Stopping the executor waits for the task it is running. That task can be
    // the one that finds the transport failed, so look again: a lost session
    // must not linger on unsent data when its socket is released below.
    lost = lost || zenoh_bridge_session_lost(s);

    // Close the session
    z_close_options_t options;
    options.__dummy = 0;
    z_close(z_loan_mut(s->session), &options);
    zenoh_bridge_release_socket(s, lost);

    // Drop the session
    z_drop(z_move(s->session));

    free(s);
    *session = NULL;

    return 0;
}

zenoh_result_t zenoh_get_session_id(zenoh_session_t* session, char* out_buffer, size_t buffer_size) {
    if (!session || !out_buffer || buffer_size < 33) {
        return -1;
    }

    // Get the session ID
    z_id_t id = z_info_zid(z_loan(session->session));

    // Convert to hex string (16 bytes = 32 hex chars + null terminator)
    for (size_t i = 0; i < 16; i++) {
        snprintf(out_buffer + (i * 2), 3, "%02x", id.id[i]);
    }
    out_buffer[32] = '\0';

    return 0;
}

bool zenoh_is_session_healthy(zenoh_session_t* session) {
    os_log_t log = os_log_create("com.youtalk.swift-ros2", "zenoh");

    if (!session) {
        os_log_error(log, "[zenoh_bridge] is_session_healthy: session is NULL");
        return false;
    }

    // Check 1: Session is not explicitly closed
    if (z_session_is_closed(z_loan(session->session))) {
        os_log_info(log, "[zenoh_bridge] Session is closed");
        return false;
    }

    // Check 2: Try to get session ID - this validates internal state
    // If the session is in a zombie state, this may fail or return zero ID
    z_id_t id = z_info_zid(z_loan(session->session));

    // A valid session should have a non-zero ID
    bool has_valid_id = false;
    for (size_t i = 0; i < 16; i++) {
        if (id.id[i] != 0) {
            has_valid_id = true;
            break;
        }
    }

    if (!has_valid_id) {
        os_log_info(log, "[zenoh_bridge] Session has invalid/zero ID - likely stale");
        return false;
    }

    // Check 3: The session still has its transport. A client session whose
    // router went away stays open but can no longer send or receive.
    if (zenoh_bridge_transport_lost(z_loan(session->session))) {
        os_log_info(log, "[zenoh_bridge] Session lost its transport (router unreachable)");
        return false;
    }

    os_log_info(log, "[zenoh_bridge] Session health check passed");
    return true;
}

size_t zenoh_max_fragmented_message_size(void) {
    return (size_t)Z_FRAG_MAX_SIZE;
}

// ============================================================================
// Publishing
// ============================================================================

// DROP (zenoh-pico's default) only try-locks the session's transmit mutex:
// a put fails with _Z_ERR_TRANSPORT_TX_FAILED (-100) whenever another thread
// is sending on the session (a query reply, another put, a declaration, the
// executor's keep-alive). BLOCK waits for that send to finish instead.
static inline z_congestion_control_t zenoh_bridge_congestion_control(bool block_on_congestion) {
    return block_on_congestion ? Z_CONGESTION_CONTROL_BLOCK : Z_CONGESTION_CONTROL_DROP;
}

zenoh_result_t zenoh_declare_publisher(zenoh_session_t* session,
                                       const char* keyexpr_str,
                                       bool block_on_congestion,
                                       zenoh_publisher_t** out_publisher) {
    if (!session || !keyexpr_str || !out_publisher) {
        return -1;
    }
    if (zenoh_bridge_session_lost(session)) {
        return ZENOH_ERROR_TRANSPORT_LOST;
    }
    z_view_keyexpr_t view_ke;
    if (z_view_keyexpr_from_str(&view_ke, keyexpr_str) < 0) {
        return -1;
    }
    zenoh_publisher_t* pub = (zenoh_publisher_t*)malloc(sizeof(zenoh_publisher_t));
    if (!pub) {
        return -1;
    }
    pub->is_advanced = false;
    pub->congestion_control = zenoh_bridge_congestion_control(block_on_congestion);
    z_publisher_options_t options;
    z_publisher_options_default(&options);
    options.congestion_control = pub->congestion_control;
    if (z_declare_publisher(z_loan(session->session), &pub->publisher, z_loan(view_ke), &options) < 0) {
        free(pub);
        return -1;
    }
    *out_publisher = pub;
    return 0;
}

zenoh_result_t zenoh_declare_advanced_publisher(zenoh_session_t* session,
                                                const char* keyexpr_str,
                                                size_t cache_depth,
                                                uint64_t heartbeat_ms,
                                                bool block_on_congestion,
                                                zenoh_publisher_t** out_publisher) {
    if (!session || !keyexpr_str || !out_publisher || cache_depth == 0) {
        return -1;
    }
#if ZENOH_BRIDGE_ADVANCED_PUBLICATION
    if (zenoh_bridge_session_lost(session)) {
        return ZENOH_ERROR_TRANSPORT_LOST;
    }
    z_view_keyexpr_t view_ke;
    if (z_view_keyexpr_from_str(&view_ke, keyexpr_str) < 0) {
        return -1;
    }
    zenoh_publisher_t* pub = (zenoh_publisher_t*)malloc(sizeof(zenoh_publisher_t));
    if (!pub) {
        return -1;
    }
    pub->is_advanced = true;
    pub->congestion_control = zenoh_bridge_congestion_control(block_on_congestion);
    ze_advanced_publisher_options_t options;
    ze_advanced_publisher_options_default(&options);
    options.publisher_options.congestion_control = pub->congestion_control;
    options.cache.is_enabled = true;
    options.cache.max_samples = cache_depth;
    options.publisher_detection = true;
    if (heartbeat_ms > 0) {
        ze_advanced_publisher_sample_miss_detection_options_default(&options.sample_miss_detection);
        options.sample_miss_detection.is_enabled = true;
        options.sample_miss_detection.heartbeat_mode = ZE_ADVANCED_PUBLISHER_HEARTBEAT_MODE_SPORADIC;
        options.sample_miss_detection.heartbeat_period_ms = heartbeat_ms;
    }
    if (ze_declare_advanced_publisher(z_loan(session->session), &pub->advanced, z_loan(view_ke), &options) < 0) {
        free(pub);
        return -1;
    }
    *out_publisher = pub;
    return 0;
#else
    (void)heartbeat_ms;
    (void)block_on_congestion;
    return ZENOH_MATCHING_UNKNOWN;
#endif
}

// The result of a put through a declared publisher. A blocking put that failed
// to write leaves the link unusable: take it down (see
// zenoh_bridge_close_failed_link).
static zenoh_result_t zenoh_bridge_put_result(zenoh_session_t* session,
                                              const zenoh_publisher_t* publisher,
                                              z_result_t rc) {
    if (rc == _Z_ERR_TRANSPORT_TX_FAILED && publisher->congestion_control == Z_CONGESTION_CONTROL_BLOCK) {
        zenoh_bridge_close_failed_link(session);
    }
    return (zenoh_result_t)rc;
}

zenoh_result_t zenoh_publisher_put(zenoh_session_t* session,
                                   zenoh_publisher_t* publisher,
                                   const uint8_t* payload,
                                   size_t payload_len,
                                   const uint8_t* attachment_data,
                                   size_t attachment_len) {
    if (!session || !publisher || !payload) {
        return -1;
    }
    if (z_session_is_closed(z_loan(session->session))) {
        return ZENOH_ERROR_SESSION_CLOSED;
    }
    if (zenoh_bridge_session_lost(session)) {
        // Fail instead of letting an advanced publisher whose frozen write
        // filter knows of no subscriber cache the sample and report success.
        return ZENOH_ERROR_TRANSPORT_LOST;
    }
#if ZENOH_BRIDGE_ADVANCED_PUBLICATION
    if (publisher->is_advanced) {
        // An advanced publisher has to put through itself: it adds the sample
        // to its cache (which serves late joiners) before it consults the write
        // filter, and it stamps the sequence number and timestamp.
        //
        // The cache keeps the sample by sharing the payload's and the
        // attachment's underlying buffers (reference counted), not by copying
        // the data, so they must own their memory. The aliasing buffers of the
        // plain path (NULL deleter) would dangle in the cache as soon as this
        // call returns.
        z_owned_bytes_t adv_bytes;
        if (z_bytes_copy_from_buf(&adv_bytes, payload, payload_len) < 0) {
            return -1;
        }
        ze_advanced_publisher_put_options_t adv_options;
        ze_advanced_publisher_put_options_default(&adv_options);
        z_owned_bytes_t adv_attachment;
        bool has_adv_attachment = false;
        if (attachment_data && attachment_len > 0) {
            if (z_bytes_copy_from_buf(&adv_attachment, attachment_data, attachment_len) < 0) {
                z_drop(z_move(adv_bytes));
                return -1;
            }
            adv_options.put_options.attachment = z_move(adv_attachment);
            has_adv_attachment = true;
        }
        z_result_t adv_rc = ze_advanced_publisher_put(z_loan(publisher->advanced), z_move(adv_bytes), &adv_options);
        // The put consumes both values, except that it returns before it takes
        // them when it cannot stamp the sample (for example the session closed
        // after the check above). Dropping a value the put already consumed is
        // a no-op, so drop both unconditionally: nothing leaks on any path.
        z_drop(z_move(adv_bytes));
        if (has_adv_attachment) {
            z_drop(z_move(adv_attachment));
        }
        return zenoh_bridge_put_result(session, publisher, adv_rc);
    }
#endif
    z_owned_bytes_t bytes;
    if (z_bytes_from_buf(&bytes, (uint8_t*)payload, payload_len, NULL, NULL) < 0) {
        return -1;
    }
    // Plain publishers deliver with z_put on the publisher's declared key
    // expression, not with z_publisher_put. z_publisher_put consults the
    // publisher's write filter, which starts closed and only opens once the
    // router's interest reply arrives: it would silently drop the first
    // messages after creation (and everything while no subscriber is known)
    // while the caller sees success. z_put has no such filter, so every
    // message goes out; the declared publisher serves only
    // zenoh_publisher_matching_status. (An advanced publisher has to put
    // through itself, because its cache fills before the filter.)
    z_put_options_t options;
    z_put_options_default(&options);
    options.congestion_control = publisher->congestion_control;
    z_owned_bytes_t attachment;
    if (attachment_data && attachment_len > 0) {
        if (z_bytes_from_buf(&attachment, (uint8_t*)attachment_data, attachment_len, NULL, NULL) < 0) {
            z_drop(z_move(bytes));
            return -1;
        }
        options.attachment = z_move(attachment);
    }
    z_result_t rc = z_put(z_loan(session->session), z_publisher_keyexpr(z_loan(publisher->publisher)), z_move(bytes),
                          &options);
    return zenoh_bridge_put_result(session, publisher, rc);
}

zenoh_result_t zenoh_publisher_matching_status(zenoh_publisher_t* publisher, bool* out_matching) {
    if (!publisher || !out_matching) {
        return -1;
    }
#if Z_FEATURE_MATCHING == 1
    // A session that lost its transport keeps reporting the last matching state
    // (see zenoh_bridge_transport_lost): report it as unknown instead.
    if (zenoh_bridge_publisher_transport_lost(publisher)) {
        return ZENOH_ERROR_TRANSPORT_LOST;
    }
    z_matching_status_t status;
#if ZENOH_BRIDGE_ADVANCED_PUBLICATION
    if (publisher->is_advanced) {
        if (ze_advanced_publisher_get_matching_status(z_loan(publisher->advanced), &status) < 0) {
            return -1;
        }
        *out_matching = status.matching;
        return 0;
    }
#endif
    if (z_publisher_get_matching_status(z_loan(publisher->publisher), &status) < 0) {
        return -1;
    }
    *out_matching = status.matching;
    return 0;
#else
    return ZENOH_MATCHING_UNKNOWN;
#endif
}

zenoh_result_t zenoh_undeclare_publisher(zenoh_publisher_t** publisher) {
    if (!publisher || !*publisher) {
        return -1;
    }
    zenoh_publisher_t* pub = *publisher;
    z_result_t rc;
#if ZENOH_BRIDGE_ADVANCED_PUBLICATION
    if (pub->is_advanced) {
        // Only the advanced member is initialized for an advanced publisher.
        rc = ze_undeclare_advanced_publisher(z_move(pub->advanced));
        free(pub);
        *publisher = NULL;
        return (zenoh_result_t)rc;
    }
#endif
    rc = z_undeclare_publisher(z_move(pub->publisher));
    free(pub);
    *publisher = NULL;
    return (zenoh_result_t)rc;
}

// ============================================================================
// Subscription
// ============================================================================

// Internal callback wrapper that converts zenoh sample to our callback format
static void zenoh_sample_handler(z_loaned_sample_t* sample, void* context) {
    zenoh_subscriber_t* sub = (zenoh_subscriber_t*)context;
    if (!sub || !sub->callback) {
        return;
    }

    // Extract keyexpr as a NUL-terminated copy (the view is not terminated;
    // see zenoh_string_dup_cstr).
    const z_loaned_keyexpr_t* keyexpr = z_sample_keyexpr(sample);
    z_view_string_t keyexpr_str;
    z_keyexpr_as_view_string(keyexpr, &keyexpr_str);
    char* ke_copy = zenoh_string_dup_cstr(z_loan(keyexpr_str));
    const char* ke_cstr = ke_copy ? ke_copy : "";

    // Extract payload
    const z_loaned_bytes_t* payload_bytes = z_sample_payload(sample);
    z_bytes_reader_t reader = z_bytes_get_reader(payload_bytes);

    // Get payload length and data
    size_t payload_len = z_bytes_len(payload_bytes);
    uint8_t* payload_data = NULL;

    if (payload_len > 0) {
        payload_data = (uint8_t*)malloc(payload_len);
        if (!payload_data) {
            // Memory allocation failed, skip callback
            if (ke_copy) free(ke_copy);
            return;
        }
        z_bytes_reader_read(&reader, payload_data, payload_len);
    }

    // Extract attachment if present
    const z_loaned_bytes_t* attachment_bytes = z_sample_attachment(sample);
    uint8_t* attachment_data = NULL;
    size_t attachment_len = 0;

    if (attachment_bytes) {
        attachment_len = z_bytes_len(attachment_bytes);
        if (attachment_len > 0) {
            attachment_data = (uint8_t*)malloc(attachment_len);
            if (!attachment_data) {
                // Attachment malloc failed, but we can still invoke callback without attachment
                attachment_len = 0;
            } else {
                z_bytes_reader_t att_reader = z_bytes_get_reader(attachment_bytes);
                z_bytes_reader_read(&att_reader, attachment_data, attachment_len);
            }
        }
    }

    // Invoke user callback
    sub->callback(ke_cstr, payload_data, payload_len,
                  attachment_data, attachment_len, sub->context);

    // Cleanup
    if (payload_data) free(payload_data);
    if (attachment_data) free(attachment_data);
    if (ke_copy) free(ke_copy);
}

zenoh_result_t zenoh_declare_subscriber(zenoh_session_t* session,
                                        const char* keyexpr_str,
                                        zenoh_subscriber_callback_t callback,
                                        void* context,
                                        zenoh_subscriber_t** out_subscriber) {
    if (!session || !keyexpr_str || !callback || !out_subscriber) {
        return -1;
    }
    if (zenoh_bridge_session_lost(session)) {
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    zenoh_subscriber_t* sub = (zenoh_subscriber_t*)malloc(sizeof(zenoh_subscriber_t));
    if (!sub) {
        return -1;
    }

    sub->callback = callback;
    sub->context = context;

    // Create a view keyexpr from string
    z_view_keyexpr_t view_ke;
    if (z_view_keyexpr_from_str(&view_ke, keyexpr_str) < 0) {
        free(sub);
        return -1;
    }

    // Create closure for the callback
    z_owned_closure_sample_t closure;
    z_closure(&closure, zenoh_sample_handler, NULL, sub);

    // Declare subscriber
    z_subscriber_options_t options;
    z_subscriber_options_default(&options);

    if (z_declare_subscriber(z_loan(session->session), &sub->subscriber,
                             z_loan(view_ke), z_move(closure), &options) < 0) {
        free(sub);
        return -1;
    }

    *out_subscriber = sub;
    return 0;
}

zenoh_result_t zenoh_undeclare_subscriber(zenoh_session_t* session,
                                          zenoh_subscriber_t** subscriber) {
    if (!session || !subscriber || !*subscriber) {
        return -1;
    }

    zenoh_subscriber_t* sub = *subscriber;

    // Undeclare the subscriber
    z_undeclare_subscriber(z_move(sub->subscriber));

    free(sub);
    *subscriber = NULL;

    return 0;
}

// ============================================================================
// Liveliness tokens (for ROS 2 discovery)
// ============================================================================

zenoh_result_t zenoh_declare_liveliness_token(zenoh_session_t* session,
                                              const char* key_expr,
                                              zenoh_liveliness_token_t** out_token) {
    os_log_t log = os_log_create("com.youtalk.swift-ros2", "zenoh");

    if (!session || !key_expr || !out_token) {
        os_log_error(log, "[zenoh_bridge] declare_liveliness_token: Invalid parameters");
        return -1;
    }

    if (zenoh_bridge_session_lost(session)) {
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    os_log_info(log, "[zenoh_bridge] Declaring liveliness token: %s", key_expr);

    // Allocate token wrapper
    zenoh_liveliness_token_t* token = (zenoh_liveliness_token_t*)malloc(sizeof(zenoh_liveliness_token_t));
    if (!token) {
        os_log_error(log, "[zenoh_bridge] ERROR: Failed to allocate liveliness token");
        return -1;
    }

    // Create key expression view
    z_view_keyexpr_t view_ke;
    int ret = z_view_keyexpr_from_str(&view_ke, key_expr);
    if (ret < 0) {
        os_log_error(log, "[zenoh_bridge] ERROR: Invalid key expression, ret=%d", ret);
        free(token);
        return -1;
    }

    // Declare liveliness token using proper API
    z_liveliness_token_options_t options;
    z_liveliness_token_options_default(&options);

    ret = z_liveliness_declare_token(
        z_loan(session->session),
        &token->token,
        z_loan(view_ke),
        &options
    );

    if (ret < 0) {
        os_log_error(log, "[zenoh_bridge] ERROR: Failed to declare liveliness token, ret=%d", ret);
        free(token);
        return -1;
    }

    os_log_info(log, "[zenoh_bridge] Liveliness token declared successfully");
    *out_token = token;
    return 0;
}

zenoh_result_t zenoh_undeclare_liveliness_token(zenoh_session_t* session,
                                                zenoh_liveliness_token_t** token) {
    if (!session || !token || !*token) {
        return -1;
    }

    zenoh_liveliness_token_t* t = *token;

    // Undeclare the liveliness token
    z_liveliness_undeclare_token(z_move(t->token));

    free(t);
    *token = NULL;

    return 0;
}

// ============================================================================
// Queryable (Service Server side)
// ============================================================================

// Link a query into the queryable's outstanding-list head. Caller must NOT
// hold the lock.
static void zenoh_queryable_link_query(zenoh_queryable_t* qbl, zenoh_query_t* q) {
    zenoh_mutex_lock(&qbl->outstanding_lock);
    q->owner = qbl;
    q->prev = NULL;
    q->next = qbl->outstanding_head;
    if (qbl->outstanding_head) {
        qbl->outstanding_head->prev = q;
    }
    qbl->outstanding_head = q;
    zenoh_mutex_unlock(&qbl->outstanding_lock);
}

// Unlink a query from its owner's outstanding-list. Caller must NOT hold
// the lock. Safe to call at most once per query (no-op if already unlinked).
static void zenoh_queryable_unlink_query(zenoh_query_t* q) {
    if (!q->owner) return;
    zenoh_queryable_t* qbl = q->owner;
    zenoh_mutex_lock(&qbl->outstanding_lock);
    if (q->prev) {
        q->prev->next = q->next;
    } else if (qbl->outstanding_head == q) {
        qbl->outstanding_head = q->next;
    }
    if (q->next) {
        q->next->prev = q->prev;
    }
    q->prev = NULL;
    q->next = NULL;
    q->owner = NULL;
    zenoh_mutex_unlock(&qbl->outstanding_lock);
}

// Internal closure handler that translates a loaned query into a cloned,
// owned query handle and dispatches to the user-supplied callback.
static void zenoh_query_handler(z_loaned_query_t* query, void* context) {
    zenoh_queryable_t* qbl = (zenoh_queryable_t*)context;
    if (!qbl || !qbl->callback) {
        return;
    }

    // Allocate the wrapper that will outlive the C closure scope.
    zenoh_query_t* q = (zenoh_query_t*)malloc(sizeof(zenoh_query_t));
    if (!q) {
        return;
    }
    q->owner = NULL;
    q->next = NULL;
    q->prev = NULL;

    if (z_query_clone(&q->query, query) < 0) {
        free(q);
        return;
    }

    zenoh_queryable_link_query(qbl, q);

    // Extract keyexpr as a NUL-terminated copy (the view is not terminated;
    // see zenoh_string_dup_cstr).
    const z_loaned_keyexpr_t* keyexpr = z_query_keyexpr(query);
    z_view_string_t keyexpr_str;
    z_keyexpr_as_view_string(keyexpr, &keyexpr_str);
    char* ke_copy = zenoh_string_dup_cstr(z_loan(keyexpr_str));
    const char* ke_cstr = ke_copy ? ke_copy : "";

    // Extract payload (may be NULL).
    const z_loaned_bytes_t* payload_bytes = z_query_payload(query);
    uint8_t* payload_data = NULL;
    size_t payload_len = 0;
    if (payload_bytes) {
        payload_len = z_bytes_len(payload_bytes);
        if (payload_len > 0) {
            payload_data = (uint8_t*)malloc(payload_len);
            if (!payload_data) {
                if (ke_copy) free(ke_copy);
                // `q` is already listed: take it out before it is freed.
                zenoh_queryable_unlink_query(q);
                z_drop(z_move(q->query));
                free(q);
                return;
            }
            z_bytes_reader_t reader = z_bytes_get_reader(payload_bytes);
            z_bytes_reader_read(&reader, payload_data, payload_len);
        }
    }

    // Extract attachment if present.
    const z_loaned_bytes_t* attachment_bytes = z_query_attachment(query);
    uint8_t* attachment_data = NULL;
    size_t attachment_len = 0;
    if (attachment_bytes) {
        attachment_len = z_bytes_len(attachment_bytes);
        if (attachment_len > 0) {
            attachment_data = (uint8_t*)malloc(attachment_len);
            if (!attachment_data) {
                attachment_len = 0;
            } else {
                z_bytes_reader_t att_reader = z_bytes_get_reader(attachment_bytes);
                z_bytes_reader_read(&att_reader, attachment_data, attachment_len);
            }
        }
    }

    // Hand off ownership of `q` to Swift. Swift must call zenoh_query_reply or
    // zenoh_query_reply_err to consume it; otherwise zenoh_undeclare_queryable
    // frees it. The caller must therefore not use `q` once it has started to
    // undeclare the queryable (ZenohQueryable.close invalidates its handles
    // first).
    qbl->callback(q, ke_cstr, payload_data, payload_len,
                  attachment_data, attachment_len, qbl->context);

    if (payload_data) free(payload_data);
    if (attachment_data) free(attachment_data);
    if (ke_copy) free(ke_copy);
}

zenoh_result_t zenoh_declare_queryable(zenoh_session_t* session,
                                       const char* keyexpr_str,
                                       zenoh_queryable_callback_t callback,
                                       void* context,
                                       zenoh_queryable_t** out_queryable) {
    if (!session || !keyexpr_str || !callback || !out_queryable) {
        return -1;
    }
    if (zenoh_bridge_session_lost(session)) {
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    zenoh_queryable_t* qbl = (zenoh_queryable_t*)malloc(sizeof(zenoh_queryable_t));
    if (!qbl) {
        return -1;
    }

    qbl->callback = callback;
    qbl->context = context;
    qbl->outstanding_head = NULL;
    zenoh_mutex_init(&qbl->outstanding_lock);

    // Create a view keyexpr from the string.
    z_view_keyexpr_t view_ke;
    if (z_view_keyexpr_from_str(&view_ke, keyexpr_str) < 0) {
        free(qbl);
        return -1;
    }

    // Build the closure with our static handler.
    z_owned_closure_query_t closure;
    z_closure(&closure, zenoh_query_handler, NULL, qbl);

    z_queryable_options_t options;
    z_queryable_options_default(&options);
    // rmw_zenoh_cpp clients query with Z_QUERY_TARGET_ALL_COMPLETE, which only
    // reaches queryables declared complete; rmw_zenoh_cpp services do the same.
    options.complete = true;

    if (z_declare_queryable(z_loan(session->session), &qbl->queryable,
                            z_loan(view_ke), z_move(closure), &options) < 0) {
        zenoh_mutex_destroy(&qbl->outstanding_lock);
        free(qbl);
        return -1;
    }

    *out_queryable = qbl;
    return 0;
}

zenoh_result_t zenoh_undeclare_queryable(zenoh_session_t* session,
                                         zenoh_queryable_t** queryable) {
    if (!session || !queryable || !*queryable) {
        return -1;
    }

    zenoh_queryable_t* qbl = *queryable;

    z_undeclare_queryable(z_move(qbl->queryable));

    // Drop and free any outstanding queries the Swift handler abandoned
    // without replying. After undeclare, no new queries can arrive on this
    // queryable, so a single drain is sufficient. The caller guarantees that
    // no reply on one of these queries is running or will start.
    zenoh_mutex_lock(&qbl->outstanding_lock);
    zenoh_query_t* q = qbl->outstanding_head;
    qbl->outstanding_head = NULL;
    zenoh_mutex_unlock(&qbl->outstanding_lock);
    while (q) {
        zenoh_query_t* next = q->next;
        z_drop(z_move(q->query));
        free(q);
        q = next;
    }

    zenoh_mutex_destroy(&qbl->outstanding_lock);
    free(qbl);
    *queryable = NULL;

    return 0;
}

// Whether the session a received query arrived on has lost its transport.
static bool zenoh_bridge_query_transport_lost(zenoh_query_t* query) {
    return zenoh_bridge_weak_session_lost(&_Z_RC_IN_VAL(z_loan(query->query))->_zn);
}

// Consumes a query whose session has lost its transport without replying. The
// drop sends nothing: zenoh-pico turns its final reply away on the lost
// transport and frees the query.
static void zenoh_bridge_abandon_query(zenoh_query_t* query) {
    zenoh_queryable_unlink_query(query);
    z_drop(z_move(query->query));
    free(query);
}

zenoh_result_t zenoh_query_reply(zenoh_query_t* query,
                                 const uint8_t* payload,
                                 size_t payload_len,
                                 const uint8_t* attachment,
                                 size_t attachment_len) {
    if (!query) {
        return -1;
    }
    if (zenoh_bridge_query_transport_lost(query)) {
        zenoh_bridge_abandon_query(query);
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    z_owned_bytes_t payload_bytes;
    if (z_bytes_from_buf(&payload_bytes, (uint8_t*)payload, payload_len, NULL, NULL) < 0) {
        // Drop the query on error so the caller does not double-free.
        zenoh_queryable_unlink_query(query);
        z_drop(z_move(query->query));
        free(query);
        return -1;
    }

    z_query_reply_options_t options;
    z_query_reply_options_default(&options);

    z_owned_bytes_t attachment_bytes;
    if (attachment && attachment_len > 0) {
        if (z_bytes_from_buf(&attachment_bytes, (uint8_t*)attachment, attachment_len, NULL, NULL) < 0) {
            z_drop(z_move(payload_bytes));
            zenoh_queryable_unlink_query(query);
            z_drop(z_move(query->query));
            free(query);
            return -1;
        }
        options.attachment = z_move(attachment_bytes);
    }

    const z_loaned_query_t* loaned = z_loan(query->query);
    const z_loaned_keyexpr_t* keyexpr = z_query_keyexpr(loaned);
    int result = z_query_reply(loaned, keyexpr, z_move(payload_bytes), &options);

    zenoh_queryable_unlink_query(query);
    z_drop(z_move(query->query));
    free(query);

    return (zenoh_result_t)result;
}

zenoh_result_t zenoh_query_reply_err(zenoh_query_t* query,
                                     const char* message_utf8,
                                     size_t len) {
    if (!query) {
        return -1;
    }
    if (zenoh_bridge_query_transport_lost(query)) {
        zenoh_bridge_abandon_query(query);
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    z_owned_bytes_t payload_bytes;
    if (z_bytes_from_buf(&payload_bytes, (uint8_t*)message_utf8, len, NULL, NULL) < 0) {
        zenoh_queryable_unlink_query(query);
        z_drop(z_move(query->query));
        free(query);
        return -1;
    }

    z_query_reply_err_options_t options;
    z_query_reply_err_options_default(&options);

    const z_loaned_query_t* loaned = z_loan(query->query);
    int result = z_query_reply_err(loaned, z_move(payload_bytes), &options);

    zenoh_queryable_unlink_query(query);
    z_drop(z_move(query->query));
    free(query);

    return (zenoh_result_t)result;
}

// ============================================================================
// Get (Service Client side)
// ============================================================================

// Per-reply handler that translates a loaned reply into the user callback.
static void zenoh_get_reply_handler(z_loaned_reply_t* reply, void* context) {
    zenoh_get_callback_state_t* state = (zenoh_get_callback_state_t*)context;
    if (!state || !state->reply_callback) {
        return;
    }

    bool is_error = !z_reply_is_ok(reply);
    const z_loaned_bytes_t* payload_bytes = NULL;
    const z_loaned_bytes_t* attachment_bytes = NULL;
    const z_loaned_keyexpr_t* keyexpr = NULL;

    if (is_error) {
        const z_loaned_reply_err_t* err = z_reply_err(reply);
        if (err) {
            payload_bytes = z_reply_err_payload(err);
        }
    } else {
        const z_loaned_sample_t* sample = z_reply_ok(reply);
        if (sample) {
            keyexpr = z_sample_keyexpr(sample);
            payload_bytes = z_sample_payload(sample);
            attachment_bytes = z_sample_attachment(sample);
        }
    }

    // Marshal keyexpr as a NUL-terminated copy (the view is not terminated;
    // see zenoh_string_dup_cstr). Error replies carry no keyexpr, so the
    // empty-string default stays for that arm.
    char* ke_copy = NULL;
    const char* ke_cstr = "";
    z_view_string_t keyexpr_str;
    if (keyexpr) {
        z_keyexpr_as_view_string(keyexpr, &keyexpr_str);
        ke_copy = zenoh_string_dup_cstr(z_loan(keyexpr_str));
        if (ke_copy) {
            ke_cstr = ke_copy;
        }
    }

    // Marshal payload.
    uint8_t* payload_data = NULL;
    size_t payload_len = 0;
    if (payload_bytes) {
        payload_len = z_bytes_len(payload_bytes);
        if (payload_len > 0) {
            payload_data = (uint8_t*)malloc(payload_len);
            if (!payload_data) {
                payload_len = 0;
            } else {
                z_bytes_reader_t reader = z_bytes_get_reader(payload_bytes);
                z_bytes_reader_read(&reader, payload_data, payload_len);
            }
        }
    }

    // Marshal attachment.
    uint8_t* attachment_data = NULL;
    size_t attachment_len = 0;
    if (attachment_bytes) {
        attachment_len = z_bytes_len(attachment_bytes);
        if (attachment_len > 0) {
            attachment_data = (uint8_t*)malloc(attachment_len);
            if (!attachment_data) {
                attachment_len = 0;
            } else {
                z_bytes_reader_t att_reader = z_bytes_get_reader(attachment_bytes);
                z_bytes_reader_read(&att_reader, attachment_data, attachment_len);
            }
        }
    }

    state->reply_callback(ke_cstr, payload_data, payload_len,
                          attachment_data, attachment_len, is_error,
                          state->context);

    if (payload_data) free(payload_data);
    if (attachment_data) free(attachment_data);
    if (ke_copy) free(ke_copy);
}

// Drop handler invoked once when the reply closure is dropped (after the
// final reply or the timeout). Frees the heap-allocated state.
static void zenoh_get_finish_handler(void* context) {
    zenoh_get_callback_state_t* state = (zenoh_get_callback_state_t*)context;
    if (!state) {
        return;
    }
    if (state->finish_callback) {
        state->finish_callback(state->context);
    }
    free(state);
}

// Shared body of zenoh_get and zenoh_get_history. `parameters` is the
// selector's parameter string ("" for none). Replies are never consolidated.
// `all_replies` targets every matching queryable; otherwise the zenoh-pico
// default target applies.
static zenoh_result_t zenoh_get_impl(zenoh_session_t* session,
                                     const char* keyexpr_str,
                                     const char* parameters,
                                     bool all_replies,
                                     const uint8_t* payload,
                                     size_t payload_len,
                                     const uint8_t* attachment,
                                     size_t attachment_len,
                                     uint32_t timeout_ms,
                                     zenoh_get_reply_callback_t reply_callback,
                                     zenoh_get_finish_callback_t finish_callback,
                                     void* context) {
    if (!session || !keyexpr_str || !parameters || !reply_callback) {
        return -1;
    }

    // Contract: finish_callback fires exactly once per call, success or
    // failure. After the closure is built, zenoh-pico guarantees this by
    // invoking the drop handler even when z_get fails (see the comment at
    // the z_get call below). On every failure return BEFORE the closure is
    // built, we must invoke finish_callback ourselves — otherwise the
    // caller-retained context (Swift GetContext) leaks on each call against
    // a disconnected session or an invalid key expression.
    if (z_session_is_closed(z_loan(session->session))) {
        if (finish_callback) {
            finish_callback(context);
        }
        return ZENOH_ERROR_SESSION_CLOSED;
    }
    if (zenoh_bridge_session_lost(session)) {
        if (finish_callback) {
            finish_callback(context);
        }
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    z_view_keyexpr_t view_ke;
    if (z_view_keyexpr_from_str(&view_ke, keyexpr_str) < 0) {
        if (finish_callback) {
            finish_callback(context);
        }
        return -1;
    }

    zenoh_get_callback_state_t* state = (zenoh_get_callback_state_t*)malloc(sizeof(zenoh_get_callback_state_t));
    if (!state) {
        if (finish_callback) {
            finish_callback(context);
        }
        return -1;
    }
    state->reply_callback = reply_callback;
    state->finish_callback = finish_callback;
    state->context = context;

    z_get_options_t options;
    z_get_options_default(&options);
    // No consolidation, as rmw_zenoh_cpp's clients do: every reply goes to
    // the callback as it arrives. (The bridge chose it when the default,
    // latest, consolidation crashed on zenoh-pico 1.7: that mode puts each
    // reply into a pending-reply cache first, 1.7 copied the reply for that,
    // and its decoder left the encoding of a reply that carries none as the
    // previous message of the same frame had set it. 1.10 clears the message
    // before it decodes one.)
    options.consolidation = z_query_consolidation_none();
    if (timeout_ms > 0) {
        options.timeout_ms = (uint64_t)timeout_ms;
    }
    if (all_replies) {
        options.target = Z_QUERY_TARGET_ALL;
    }

    z_owned_bytes_t payload_bytes;
    bool payload_built = false;
    if (payload && payload_len > 0) {
        if (z_bytes_from_buf(&payload_bytes, (uint8_t*)payload, payload_len, NULL, NULL) < 0) {
            free(state);
            if (finish_callback) {
                finish_callback(context);
            }
            return -1;
        }
        options.payload = z_move(payload_bytes);
        payload_built = true;
    }

    z_owned_bytes_t attachment_bytes;
    if (attachment && attachment_len > 0) {
        if (z_bytes_from_buf(&attachment_bytes, (uint8_t*)attachment, attachment_len, NULL, NULL) < 0) {
            if (payload_built) {
                z_drop(z_move(payload_bytes));
            }
            free(state);
            if (finish_callback) {
                finish_callback(context);
            }
            return -1;
        }
        options.attachment = z_move(attachment_bytes);
    }

    z_owned_closure_reply_t closure;
    z_closure(&closure, zenoh_get_reply_handler, zenoh_get_finish_handler, state);

    int result = z_get(z_loan(session->session), z_loan(view_ke), parameters,
                       z_move(closure), &options);

    if (result < 0) {
        // The closure drop handler already frees `state` and fires
        // finish_callback when z_get fails. zenoh-pico (_z_query) calls the
        // dropper itself on every failure before the query is registered, and
        // on a send failure _z_unregister_pending_query frees the pending
        // query, whose clear function calls it.
        // Do not double-finish or double-free here.
        return (zenoh_result_t)result;
    }

    return 0;
}

zenoh_result_t zenoh_get(zenoh_session_t* session,
                         const char* keyexpr_str,
                         const uint8_t* payload,
                         size_t payload_len,
                         const uint8_t* attachment,
                         size_t attachment_len,
                         uint32_t timeout_ms,
                         zenoh_get_reply_callback_t reply_callback,
                         zenoh_get_finish_callback_t finish_callback,
                         void* context) {
    return zenoh_get_impl(session, keyexpr_str, "", false, payload, payload_len,
                          attachment, attachment_len, timeout_ms, reply_callback,
                          finish_callback, context);
}

zenoh_result_t zenoh_get_history(zenoh_session_t* session,
                                 const char* keyexpr_str,
                                 const char* parameters,
                                 uint32_t timeout_ms,
                                 zenoh_get_reply_callback_t reply_callback,
                                 zenoh_get_finish_callback_t finish_callback,
                                 void* context) {
    return zenoh_get_impl(session, keyexpr_str, parameters ? parameters : "", true,
                          NULL, 0, NULL, 0, timeout_ms, reply_callback,
                          finish_callback, context);
}

// ============================================================================
// Liveliness queries (ROS 2 graph discovery)
// ============================================================================

zenoh_result_t zenoh_liveliness_get(zenoh_session_t* session,
                                    const char* keyexpr_str,
                                    uint32_t timeout_ms,
                                    zenoh_get_reply_callback_t reply_callback,
                                    zenoh_get_finish_callback_t finish_callback,
                                    void* context) {
    if (!session || !keyexpr_str || !reply_callback) {
        return -1;
    }

    // Same contract as zenoh_get: finish_callback fires exactly once. Before the
    // closure is built, every failure return fires it here; after that the
    // closure drop handler fires it, also when z_liveliness_get fails.
    if (z_session_is_closed(z_loan(session->session))) {
        if (finish_callback) {
            finish_callback(context);
        }
        return ZENOH_ERROR_SESSION_CLOSED;
    }
    if (zenoh_bridge_session_lost(session)) {
        if (finish_callback) {
            finish_callback(context);
        }
        return ZENOH_ERROR_TRANSPORT_LOST;
    }

    z_view_keyexpr_t view_ke;
    if (z_view_keyexpr_from_str(&view_ke, keyexpr_str) < 0) {
        if (finish_callback) {
            finish_callback(context);
        }
        return -1;
    }

    zenoh_get_callback_state_t* state = (zenoh_get_callback_state_t*)malloc(sizeof(zenoh_get_callback_state_t));
    if (!state) {
        if (finish_callback) {
            finish_callback(context);
        }
        return -1;
    }
    state->reply_callback = reply_callback;
    state->finish_callback = finish_callback;
    state->context = context;

    z_liveliness_get_options_t options;
    z_liveliness_get_options_default(&options);
    if (timeout_ms > 0) {
        options.timeout_ms = (uint64_t)timeout_ms;
    }

    z_owned_closure_reply_t closure;
    z_closure(&closure, zenoh_get_reply_handler, zenoh_get_finish_handler, state);

    int result = z_liveliness_get(z_loan(session->session), z_loan(view_ke), z_move(closure), &options);
    return result < 0 ? (zenoh_result_t)result : 0;
}
