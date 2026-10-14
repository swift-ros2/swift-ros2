//
// crcl_internal.h
// Internal (non-public-API) surface shared between the bridge C sources
// (rcl_bridge.c, rcl_subscription.c, rcl_service.c, rcl_client.c,
// rcl_action_*.c): the node / publisher struct bodies and the error helpers. The typedefs
// themselves stay in rcl_bridge.h; this header only supplies the struct
// *bodies* so the other TUs can dereference them without re-declaring the
// typedefs.
//
#ifndef CRCL_INTERNAL_H
#define CRCL_INTERNAL_H

#include <rcl/publisher.h>
#include <rcl/rcl.h>
#include <rcutils/allocator.h>
#include <rmw/types.h>  // rmw_request_id_t (request-id blob pack helpers)

#ifdef __cplusplus
extern "C" {
#endif

// The crcl_publisher_t / crcl_node_t typedefs are also declared in
// rcl_bridge.h. Repeating an identical typedef of an incomplete struct is
// legal in C11, so this header stays self-contained.
typedef struct crcl_publisher_s crcl_publisher_t;
struct crcl_publisher_s {
    rcl_publisher_t pub;
    rcl_node_t *node;  // borrowed; node must outlive the publisher
};

// Stored `ctx` exists because Jazzy's rcl has no rcl_node_get_context();
// rcl_subscription.c needs the owning context to init its guard condition and
// wait set, so crcl_node_create records it here at node-create time.
typedef struct crcl_node_s crcl_node_t;
struct crcl_node_s {
    rcl_node_t node;
    rcl_context_t *ctx;  // borrowed; context must outlive the node
};

/// Pack / unpack an rmw_request_id_t to / from the opaque 24-byte FFI blob
/// (16-byte writer GUID + int64 sequence number in little-endian byte order;
/// 24 == CRCL_REQUEST_ID_SIZE in rcl_bridge.h). Defined in rcl_service.c and
/// shared with the rcl_action_* bridge sources.
void crcl__pack_request_id(const rmw_request_id_t *id, uint8_t out[24]);
void crcl__unpack_request_id(const uint8_t in[24], rmw_request_id_t *id);

/// Copy `msg` into the thread-local error buffer surfaced by crcl_last_error().
void crcl__set_error(const char *msg);

/// Capture the current rcutils error stack into the thread-local error buffer
/// and reset it (used after a failing rcl/rmw call).
void crcl__capture_rcl_error(void);

/// Zero-filling allocator for rmw_serialized_message OUTPUT buffers (#162).
/// Buffers initialized with it must be released through the message's own
/// allocator (rmw_serialized_message_fini) — never with plain free().
rcutils_allocator_t crcl__zeroing_allocator(void);

#ifdef __cplusplus
}
#endif
#endif  // CRCL_INTERNAL_H
