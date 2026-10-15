//
// zenoh_bridge.h
// C-FFI bridge for zenoh-pico to Swift
//
// Provides simplified C API wrapping zenoh-pico for use in Swift
//

#ifndef ZENOH_BRIDGE_H
#define ZENOH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Opaque handles for zenoh types (exposed as pointers to Swift)
// ============================================================================

typedef struct zenoh_session_t zenoh_session_t;
typedef struct zenoh_keyexpr_t zenoh_keyexpr_t;
typedef struct zenoh_subscriber_t zenoh_subscriber_t;
typedef struct zenoh_liveliness_token_t zenoh_liveliness_token_t;
typedef struct zenoh_publisher_t zenoh_publisher_t;

// ============================================================================
// Error handling
// ============================================================================

// Returns 0 on success, negative error code on failure
typedef int8_t zenoh_result_t;

// Error codes
#define ZENOH_ERROR_SESSION_CLOSED -2

/// Returned when this build lacks an optional zenoh-pico feature: by
/// zenoh_publisher_matching_status without matching support, and by
/// zenoh_declare_advanced_publisher without advanced publication.
#define ZENOH_MATCHING_UNKNOWN -3

/// Returned when the session is still open but has lost its transport: its
/// router closed the connection or stopped answering (lease expiry or a failed
/// keep-alive) and zenoh-pico tore the transport down. zenoh-pico does not
/// reconnect it (this build has no auto-reconnect); close the session and open
/// a new one. Returned by zenoh_publisher_matching_status (the matching state
/// is unknown) and, instead of calling into zenoh-pico, by every call that
/// would send on the lost transport: the puts, the declarations, zenoh_get and
/// the query replies. zenoh-pico crashes on such sends once the transport is
/// torn down, so the undeclarations and zenoh_close_session do not send either:
/// on such a session they free the bridge's handle, return 0, and leave the
/// zenoh-pico objects allocated (a bounded leak per lost router).
#define ZENOH_ERROR_TRANSPORT_LOST -4

// ============================================================================
// Session management
// ============================================================================

/// Opens a zenoh session with the given locator string
/// @param locator Connection string (e.g., "tcp/127.0.0.1:7447")
/// @param out_session Output parameter for the created session handle
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_open_session(const char* locator, zenoh_session_t** out_session);

/// Closes a zenoh session and frees all associated resources. A session that
/// has lost its transport (see ZENOH_ERROR_TRANSPORT_LOST) is not closed in
/// zenoh-pico, which would crash: its periodic scheduler is stopped, the handle
/// is freed and the zenoh-pico session is left allocated.
/// @param session Session handle to close (will be set to NULL)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_close_session(zenoh_session_t** session);

/// Gets the session ID as a hex string
/// @param session The zenoh session
/// @param out_buffer Buffer to store the session ID (must be at least 33 bytes: 32 hex chars + null terminator)
/// @param buffer_size Size of the output buffer
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_get_session_id(zenoh_session_t* session, char* out_buffer, size_t buffer_size);

/// Checks if the session is healthy and can safely publish
/// This is more comprehensive than z_session_is_closed() - it verifies
/// the session is not in a stale/zombie state after sleep/wake cycles,
/// and that it has not lost its transport (a client session whose router
/// went away stays open in zenoh-pico but can no longer send or receive)
/// @param session The zenoh session to check
/// @return true if session is healthy, false if stale, closed or its
///         transport is lost
bool zenoh_is_session_healthy(zenoh_session_t* session);

// ============================================================================
// Key expression management
// ============================================================================

/// Declares a key expression for efficient repeated use
/// @param session The zenoh session
/// @param keyexpr_str The key expression string
/// @param out_keyexpr Output parameter for the declared key expression handle
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_declare_keyexpr(zenoh_session_t* session,
                                      const char* keyexpr_str,
                                      zenoh_keyexpr_t** out_keyexpr);

/// Undeclares and frees a key expression
/// @param session The zenoh session
/// @param keyexpr Key expression handle to undeclare (will be set to NULL)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_undeclare_keyexpr(zenoh_session_t* session,
                                        zenoh_keyexpr_t** keyexpr);

// ============================================================================
// Publishing
// ============================================================================

/// Puts data to a key expression with optional attachment
/// @param session The zenoh session
/// @param keyexpr The key expression to publish to
/// @param payload Pointer to the payload data
/// @param payload_len Length of the payload in bytes
/// @param attachment_data Pointer to attachment data (can be NULL)
/// @param attachment_len Length of attachment data in bytes (0 if no attachment)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_put(zenoh_session_t* session,
                         zenoh_keyexpr_t* keyexpr,
                         const uint8_t* payload,
                         size_t payload_len,
                         const uint8_t* attachment_data,
                         size_t attachment_len);

/// Puts data to a key expression string (non-declared) with optional attachment
/// @param session The zenoh session
/// @param keyexpr_str The key expression string to publish to
/// @param payload Pointer to the payload data
/// @param payload_len Length of the payload in bytes
/// @param attachment_data Pointer to attachment data (can be NULL)
/// @param attachment_len Length of attachment data in bytes (0 if no attachment)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_put_str(zenoh_session_t* session,
                             const char* keyexpr_str,
                             const uint8_t* payload,
                             size_t payload_len,
                             const uint8_t* attachment_data,
                             size_t attachment_len);

/// Declare a publisher on a key expression. Unlike zenoh_put on a bare key
/// expression, a declared publisher can report matching subscribers.
///
/// `block_on_congestion` selects the congestion control of every put through
/// the publisher. false (DROP, the default of zenoh_put) only try-locks the
/// session's transmit mutex, so a put fails with -100
/// (_Z_ERR_TRANSPORT_TX_FAILED) whenever another thread is sending on the same
/// session at that moment. true (BLOCK) waits for that send instead, as query
/// replies and declarations do. The wait is bounded: a send on the session's
/// TCP socket that makes no progress for 5 s fails with -100, and a blocking
/// put that fails to write shuts the socket down, so every other send fails at
/// once and the session soon reports its transport lost
/// (ZENOH_ERROR_TRANSPORT_LOST).
/// @return 0 on success, negative on error.
zenoh_result_t zenoh_declare_publisher(zenoh_session_t* session,
                                       const char* keyexpr_str,
                                       bool block_on_congestion,
                                       zenoh_publisher_t** out_publisher);

/// Declare an advanced publisher (rmw_zenoh's TRANSIENT_LOCAL): it keeps the
/// last `cache_depth` samples for late-joining advanced subscribers, can be
/// detected through liveliness, and, when `heartbeat_ms` > 0, sends sporadic
/// sample-miss heartbeats with that period. Uses the same handle and the same
/// put / matching / undeclare calls as a plain publisher, and the same
/// `block_on_congestion` choice as zenoh_declare_publisher.
/// @return 0 on success, ZENOH_MATCHING_UNKNOWN when this build has no
///         advanced publication, -1 on error.
zenoh_result_t zenoh_declare_advanced_publisher(zenoh_session_t* session,
                                                const char* keyexpr_str,
                                                size_t cache_depth,
                                                uint64_t heartbeat_ms,
                                                bool block_on_congestion,
                                                zenoh_publisher_t** out_publisher);

/// Publish on a declared publisher's key expression. Same payload and attachment
/// contract, delivery semantics and return codes as zenoh_put
/// (ZENOH_ERROR_SESSION_CLOSED when the session is closed,
/// ZENOH_ERROR_TRANSPORT_LOST when it has lost its transport). A plain publisher's
/// write filter is bypassed, so a message is sent even before the router has
/// reported any matching subscriber. An advanced publisher puts through itself:
/// the sample is cached first (for late joiners) and then sent unless its write
/// filter knows of no subscriber.
zenoh_result_t zenoh_publisher_put(zenoh_session_t* session,
                                   zenoh_publisher_t* publisher,
                                   const uint8_t* payload,
                                   size_t payload_len,
                                   const uint8_t* attachment_data,
                                   size_t attachment_len);

/// Writes whether at least one subscriber matches the publisher.
/// Callable from any thread while the publisher is declared; takes no lock.
/// @return 0 on success, ZENOH_MATCHING_UNKNOWN without matching support,
///         ZENOH_ERROR_TRANSPORT_LOST when the publisher's session has lost its
///         transport (zenoh-pico would keep reporting the last state forever),
///         -1 on bad arguments or failure.
zenoh_result_t zenoh_publisher_matching_status(zenoh_publisher_t* publisher, bool* out_matching);

/// Undeclare and free the publisher; sets *publisher to NULL.
zenoh_result_t zenoh_undeclare_publisher(zenoh_publisher_t** publisher);

// ============================================================================
// Subscription (callback-based)
// ============================================================================

/// Callback function type for subscribers
/// @param keyexpr_str The key expression that matched
/// @param payload Pointer to received payload data
/// @param payload_len Length of received payload
/// @param attachment Pointer to received attachment data (can be NULL)
/// @param attachment_len Length of received attachment (0 if no attachment)
/// @param context User-provided context pointer
typedef void (*zenoh_subscriber_callback_t)(const char* keyexpr_str,
                                             const uint8_t* payload,
                                             size_t payload_len,
                                             const uint8_t* attachment,
                                             size_t attachment_len,
                                             void* context);

/// Declares a subscriber with a callback
/// @param session The zenoh session
/// @param keyexpr_str The key expression to subscribe to
/// @param callback The callback function to invoke on received samples
/// @param context User context pointer passed to callback
/// @param out_subscriber Output parameter for the subscriber handle
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_declare_subscriber(zenoh_session_t* session,
                                        const char* keyexpr_str,
                                        zenoh_subscriber_callback_t callback,
                                        void* context,
                                        zenoh_subscriber_t** out_subscriber);

/// Undeclares and frees a subscriber
/// @param session The zenoh session
/// @param subscriber Subscriber handle to undeclare (will be set to NULL)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_undeclare_subscriber(zenoh_session_t* session,
                                          zenoh_subscriber_t** subscriber);

// ============================================================================
// Liveliness tokens (for ROS 2 discovery)
// ============================================================================

/// Declares a liveliness token for ROS 2 entity discovery
/// @param session The zenoh session
/// @param key_expr The liveliness token key expression (e.g., "@ros2_lv/0/...")
/// @param out_token Output parameter for the liveliness token handle
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_declare_liveliness_token(zenoh_session_t* session,
                                              const char* key_expr,
                                              zenoh_liveliness_token_t** out_token);

/// Undeclares and frees a liveliness token
/// @param session The zenoh session
/// @param token Liveliness token handle to undeclare (will be set to NULL)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_undeclare_liveliness_token(zenoh_session_t* session,
                                                zenoh_liveliness_token_t** token);

// ============================================================================
// Queryable (Service Server side)
// ============================================================================

typedef struct zenoh_queryable_t zenoh_queryable_t;
typedef struct zenoh_query_t zenoh_query_t;

/// Callback invoked when a query is received on a declared queryable.
/// The query handle is owned by the bridge and remains valid until the
/// Swift side calls `zenoh_query_reply` or `zenoh_query_reply_err`, both of
/// which consume it. If neither is called before the queryable is undeclared,
/// the bridge drops the cloned query when the queryable is freed.
/// @param query Owned query handle (consumed by the first reply call)
/// @param keyexpr_str The key expression the query was issued against
/// @param payload Pointer to the query payload (NULL if empty)
/// @param payload_len Length of the query payload (0 if empty)
/// @param attachment Pointer to the query attachment (NULL if not present)
/// @param attachment_len Length of the attachment (0 if not present)
/// @param context User-provided context pointer
typedef void (*zenoh_queryable_callback_t)(zenoh_query_t* query,
                                            const char* keyexpr_str,
                                            const uint8_t* payload,
                                            size_t payload_len,
                                            const uint8_t* attachment,
                                            size_t attachment_len,
                                            void* context);

/// Declares a queryable on the given key expression
/// @param session The zenoh session
/// @param keyexpr_str The key expression to expose as a queryable
/// @param callback Callback invoked once per incoming query
/// @param context User context pointer passed to the callback
/// @param out_queryable Output parameter for the queryable handle
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_declare_queryable(zenoh_session_t* session,
                                       const char* keyexpr_str,
                                       zenoh_queryable_callback_t callback,
                                       void* context,
                                       zenoh_queryable_t** out_queryable);

/// Undeclares and frees a queryable
/// @param session The zenoh session
/// @param queryable Queryable handle to undeclare (will be set to NULL)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_undeclare_queryable(zenoh_session_t* session,
                                         zenoh_queryable_t** queryable);

/// Replies to a query with a successful payload and optional attachment.
/// Consumes the query handle: after this call returns, *query is freed and
/// the Swift side must drop its pointer.
/// @param query Query handle (consumed)
/// @param payload Pointer to the reply payload (may be NULL if payload_len == 0)
/// @param payload_len Length of the reply payload
/// @param attachment Optional attachment data (NULL for none)
/// @param attachment_len Length of the attachment (0 for none)
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_query_reply(zenoh_query_t* query,
                                 const uint8_t* payload,
                                 size_t payload_len,
                                 const uint8_t* attachment,
                                 size_t attachment_len);

/// Replies to a query with an error payload (UTF-8 encoded message).
/// Consumes the query handle: after this call returns, *query is freed and
/// the Swift side must drop its pointer.
/// @param query Query handle (consumed)
/// @param message_utf8 Pointer to UTF-8 error message bytes (may be NULL if len == 0)
/// @param len Length of the error message in bytes
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_query_reply_err(zenoh_query_t* query,
                                     const char* message_utf8,
                                     size_t len);

// ============================================================================
// Get (Service Client side)
// ============================================================================

/// Per-reply callback invoked once for each reply received from a get.
/// `is_error` indicates whether this is an error reply.
/// @param keyexpr_str The key expression the reply is associated with
/// @param payload Pointer to the reply payload (NULL if empty)
/// @param payload_len Length of the reply payload (0 if empty)
/// @param attachment Pointer to the reply attachment (NULL if not present)
/// @param attachment_len Length of the attachment (0 if not present)
/// @param is_error true if this is an error reply, false if it is an OK reply
/// @param context User-provided context pointer
typedef void (*zenoh_get_reply_callback_t)(const char* keyexpr_str,
                                            const uint8_t* payload,
                                            size_t payload_len,
                                            const uint8_t* attachment,
                                            size_t attachment_len,
                                            bool is_error,
                                            void* context);

/// Finish callback invoked exactly once after the final reply is delivered
/// (or the timeout has elapsed). Use this to free any user-side context.
/// @param context User-provided context pointer
typedef void (*zenoh_get_finish_callback_t)(void* context);

/// Issues a query against the given key expression. Replies are not
/// consolidated: each one reaches reply_callback as it arrives.
/// @param session The zenoh session
/// @param keyexpr_str The key expression to query
/// @param payload Pointer to the request payload (NULL for none)
/// @param payload_len Length of the request payload (0 for none)
/// @param attachment Pointer to the request attachment (NULL for none)
/// @param attachment_len Length of the attachment (0 for none)
/// @param timeout_ms Query timeout in milliseconds (0 = library default)
/// @param reply_callback Callback invoked once per reply
/// @param finish_callback Callback invoked once after all replies are delivered
/// @param context User context pointer passed to both callbacks
/// @return 0 on success, negative error code otherwise
zenoh_result_t zenoh_get(zenoh_session_t* session,
                         const char* keyexpr_str,
                         const uint8_t* payload,
                         size_t payload_len,
                         const uint8_t* attachment,
                         size_t attachment_len,
                         uint32_t timeout_ms,
                         zenoh_get_reply_callback_t reply_callback,
                         zenoh_get_finish_callback_t finish_callback,
                         void* context);

/// Queries the history of every matching queryable, for example the cache of
/// every advanced publisher (a TRANSIENT_LOCAL rmw_zenoh publisher) on a
/// topic. Like zenoh_get, with the selector parameters `parameters` (for
/// example "_anyke;_max=1"; NULL or "" for none), no payload or attachment,
/// every matching queryable targeted and every reply delivered (no
/// consolidation). Same callback, finish and return-code contract as zenoh_get.
zenoh_result_t zenoh_get_history(zenoh_session_t* session,
                                 const char* keyexpr_str,
                                 const char* parameters,
                                 uint32_t timeout_ms,
                                 zenoh_get_reply_callback_t reply_callback,
                                 zenoh_get_finish_callback_t finish_callback,
                                 void* context);

// ============================================================================
// Utility functions
// ============================================================================

/// Gets a human-readable error message for a result code
/// @param result The result code
/// @return String description of the error
const char* zenoh_result_str(zenoh_result_t result);

#ifdef __cplusplus
}
#endif

#endif // ZENOH_BRIDGE_H
