//
// dds_bridge.h
// C-FFI bridge for CycloneDDS
//
// This header provides a Swift-callable interface to CycloneDDS.
// The bridge abstracts CycloneDDS complexity and provides a simple
// session/writer model for publishing ROS 2 messages.
//
// NOTE: Types use "bridge_" prefix to avoid conflicts with CycloneDDS types.
//

#ifndef DDS_BRIDGE_H
#define DDS_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// MARK: - Opaque Handle Types
// =============================================================================

/// Opaque handle to a DDS session (participant + publisher)
typedef struct bridge_dds_session_s bridge_dds_session_t;

/// Opaque handle to a DDS data writer
typedef struct bridge_dds_writer_s bridge_dds_writer_t;

/// Opaque handle to a DDS data reader (raw CDR receive path)
typedef struct bridge_dds_reader_s bridge_dds_reader_t;

// =============================================================================
// MARK: - Discovery Configuration
// =============================================================================

/// DDS discovery mode
typedef enum {
    /// Standard SPDP multicast discovery (default)
    /// Automatic peer discovery on local network
    BRIDGE_DISCOVERY_MULTICAST = 0,

    /// Unicast-only discovery
    /// Manual peer configuration required
    BRIDGE_DISCOVERY_UNICAST = 1,

    /// Hybrid mode: multicast + specific unicast peers
    BRIDGE_DISCOVERY_HYBRID = 2
} bridge_discovery_mode_t;

/// Discovery configuration structure
typedef struct {
    /// Discovery mode (multicast, unicast, hybrid)
    bridge_discovery_mode_t mode;

    /// NULL-terminated array of unicast peer locators
    /// Format: "address:port" (e.g., "192.168.1.100:7400")
    /// Only used when mode is UNICAST or HYBRID
    const char** unicast_peers;

    /// Number of unicast peers
    int peer_count;

    /// Network interface to bind to (NULL = all interfaces)
    const char* network_interface;
} bridge_discovery_config_t;

/// Build the CycloneDDS domain-config XML (Peers / multicast-disable /
/// NetworkInterface) for the given domain + discovery config. Heap-allocated;
/// free with dds_bridge_free_string(). Returns NULL on OOM. Shared by the
/// pure-Swift DDS path and the RCL path (exported as CYCLONEDDS_URI) so both
/// backends discover identically.
char* dds_bridge_build_domain_config_xml(
    int32_t domain_id, const bridge_discovery_config_t* config);

/// Free a string returned by dds_bridge_build_domain_config_xml().
void dds_bridge_free_string(char* s);

// =============================================================================
// MARK: - QoS Configuration
// =============================================================================

/// DDS reliability setting
typedef enum {
    BRIDGE_RELIABILITY_BEST_EFFORT = 0,
    BRIDGE_RELIABILITY_RELIABLE = 1
} bridge_reliability_t;

/// DDS durability setting
typedef enum {
    BRIDGE_DURABILITY_VOLATILE = 0,
    BRIDGE_DURABILITY_TRANSIENT_LOCAL = 1
} bridge_durability_t;

/// DDS history setting
typedef enum {
    BRIDGE_HISTORY_KEEP_LAST = 0,
    BRIDGE_HISTORY_KEEP_ALL = 1
} bridge_history_kind_t;

/// QoS configuration structure
typedef struct {
    bridge_reliability_t reliability;
    bridge_durability_t durability;
    bridge_history_kind_t history_kind;
    int32_t history_depth;
} bridge_qos_config_t;

/// Default QoS for sensor data
static const bridge_qos_config_t BRIDGE_QOS_SENSOR_DATA = {
    .reliability = BRIDGE_RELIABILITY_RELIABLE,
    .durability = BRIDGE_DURABILITY_VOLATILE,
    .history_kind = BRIDGE_HISTORY_KEEP_LAST,
    .history_depth = 10
};

// =============================================================================
// MARK: - Session Management
// =============================================================================

/// Create a DDS session with the specified domain ID and discovery configuration
///
/// @param domain_id ROS 2 domain ID (0-232)
/// @param discovery_config Discovery configuration (NULL for defaults)
/// @return Session handle, or NULL on failure (check dds_bridge_get_last_error())
bridge_dds_session_t* dds_bridge_create_session(
    int32_t domain_id,
    const bridge_discovery_config_t* discovery_config
);

/// Destroy a DDS session and release all resources, deleting its participant.
/// On Apple platforms the participant delete is bounded: if it has not
/// finished within 3 s the call returns and that participant is leaked.
///
/// @param session Session to destroy
void dds_bridge_destroy_session(bridge_dds_session_t* session);

/// Check if a session is connected and healthy
///
/// @param session Session to check
/// @return true if session is healthy, false otherwise
bool dds_bridge_session_is_connected(const bridge_dds_session_t* session);

/// Get the session's participant GUID as a hex string
///
/// @param session Session to query
/// @param buffer Output buffer (must be at least 33 bytes)
/// @param buffer_size Size of the output buffer
/// @return 0 on success, negative on failure
int32_t dds_bridge_get_session_id(
    const bridge_dds_session_t* session,
    char* buffer,
    size_t buffer_size
);

// =============================================================================
// MARK: - Writer Management
// =============================================================================

/// Destroy a DDS data writer
///
/// @param writer Writer to destroy
void dds_bridge_destroy_writer(bridge_dds_writer_t* writer);

/// Check if a writer is active
///
/// @param writer Writer to check
/// @return true if writer is active, false otherwise
bool dds_bridge_writer_is_active(const bridge_dds_writer_t* writer);

/// Number of subscriptions currently matched to the writer
///
/// @param writer Writer to query
/// @return current matched count, or -1 on error
int32_t dds_bridge_writer_matched_count(const bridge_dds_writer_t* writer);

// =============================================================================
// MARK: - Raw CDR Publishing (Custom Sertype)
// =============================================================================

/// Create a DDS data writer using custom raw CDR sertype
///
/// This function creates a writer that can publish pre-serialized CDR data
/// using a custom sertype implementation, so it does not require a
/// schema-based topic descriptor.
///
/// @param session Active DDS session
/// @param topic_name Full topic name (e.g., "/ios/imu")
/// @param type_name DDS type name (e.g., "sensor_msgs::msg::dds_::Imu_")
/// @param qos QoS configuration (NULL for sensor data defaults)
/// @param user_data USER_DATA QoS string for writer (e.g., "typehash=RIHS01_...;"), NULL to omit
/// @return Writer handle, or NULL on failure (check dds_bridge_get_last_error())
bridge_dds_writer_t* dds_bridge_create_raw_writer(
    bridge_dds_session_t* session,
    const char* topic_name,
    const char* type_name,
    const bridge_qos_config_t* qos,
    const char* user_data
);

/// Write pre-serialized CDR data using raw CDR sertype
///
/// This function writes data using the custom sertype/serdata implementation.
/// The writer must have been created with dds_bridge_create_raw_writer.
///
/// @param writer Active DDS writer (created with dds_bridge_create_raw_writer)
/// @param cdr_data CDR-serialized payload (with 4-byte encapsulation header)
/// @param cdr_len Length of CDR data in bytes
/// @param timestamp_ns Timestamp in nanoseconds since Unix epoch
/// @return 0 on success, negative on failure (check dds_bridge_get_last_error())
int32_t dds_bridge_write_raw_cdr(
    bridge_dds_writer_t* writer,
    const uint8_t* cdr_data,
    size_t cdr_len,
    uint64_t timestamp_ns
);

// =============================================================================
// MARK: - Raw CDR Subscribing (Custom Sertype)
// =============================================================================

/// Callback fired for each received sample.
///
/// @param cdr_data     CDR-serialized payload including 4-byte encapsulation header
///                     (owned by bridge; valid only during the call).
/// @param cdr_len      Length of cdr_data in bytes.
/// @param timestamp_ns Source timestamp in nanoseconds since Unix epoch
///                     (from dds_sample_info_t.source_timestamp; 0 if invalid).
/// @param context      Opaque user pointer supplied to dds_bridge_create_raw_reader.
typedef void (*dds_bridge_data_callback_t)(
    const uint8_t* cdr_data,
    size_t cdr_len,
    uint64_t timestamp_ns,
    void* context
);

/// Create a DDS data reader using the raw CDR sertype.
///
/// Parallel to dds_bridge_create_raw_writer. Reuses the participant from the session
/// (the reader is created directly under the participant; CycloneDDS provides an
/// implicit subscriber internally).
///
/// @param session Active DDS session
/// @param topic_name Full topic name (e.g., "rt/chatter")
/// @param type_name DDS type name in ::msg::dds_:: form (e.g., "std_msgs::msg::dds_::String_")
/// @param qos QoS configuration (NULL for sensor data defaults)
/// @param user_data USER_DATA QoS string for reader (e.g., "typehash=RIHS01_...;"), NULL to omit
/// @param callback Callback invoked on each received valid sample (must be non-NULL).
///        It runs on a CycloneDDS listener thread, except for the samples the reader
///        receives while it is being created (a transient-local reader gets the caches
///        of writers in this process then): those are passed on the calling thread
///        before this function returns. Calls for one reader never overlap.
/// @param context Opaque user pointer passed to each callback invocation (may be NULL)
/// @return Reader handle, or NULL on failure (check dds_bridge_get_last_error())
bridge_dds_reader_t* dds_bridge_create_raw_reader(
    bridge_dds_session_t* session,
    const char* topic_name,
    const char* type_name,
    const bridge_qos_config_t* qos,
    const char* user_data,
    dds_bridge_data_callback_t callback,
    void* context
);

/// Destroy a DDS data reader. Safe to pass NULL.
///
/// Calls dds_delete on the reader entity, which blocks until any in-flight listener
/// callback returns (CycloneDDS contract). After this returns the callback will
/// never fire again, so the caller can safely release resources associated with
/// `context`.
///
/// @param reader Reader to destroy
void dds_bridge_destroy_reader(bridge_dds_reader_t* reader);

/// Check if a reader is active
///
/// @param reader Reader to check
/// @return true if reader is active, false otherwise
bool dds_bridge_reader_is_active(const bridge_dds_reader_t* reader);

/// Number of publications currently matched to the reader
///
/// @param reader Reader to query
/// @return current matched count, or -1 on error
int32_t dds_bridge_reader_matched_count(const bridge_dds_reader_t* reader);

// =============================================================================
// MARK: - Entity GUIDs
// =============================================================================

/// Size of a DDS GUID in bytes (12-byte prefix + 4-byte entity id).
#define DDS_BRIDGE_GUID_SIZE 16

/// Copy the session participant's GUID, as dds_get_guid returns it (the form
/// rmw_cyclonedds_cpp puts in a gid), into `guid_out`.
///
/// @param session Active DDS session
/// @param guid_out Output buffer of at least DDS_BRIDGE_GUID_SIZE bytes
/// @return 0 on success, negative on failure (check dds_bridge_get_last_error())
int32_t dds_bridge_get_participant_guid(const bridge_dds_session_t* session, uint8_t* guid_out);

/// Copy a writer's endpoint GUID into `guid_out` (DDS_BRIDGE_GUID_SIZE bytes).
///
/// @return 0 on success, negative on failure
int32_t dds_bridge_writer_get_guid(const bridge_dds_writer_t* writer, uint8_t* guid_out);

/// Copy a reader's endpoint GUID into `guid_out` (DDS_BRIDGE_GUID_SIZE bytes).
///
/// @return 0 on success, negative on failure
int32_t dds_bridge_reader_get_guid(const bridge_dds_reader_t* reader, uint8_t* guid_out);

// =============================================================================
// MARK: - Discovered Publications (topic graph)
// =============================================================================

/// The reliability of a discovered writer.
typedef enum {
    /// The writer's QoS carries no reliability policy.
    BRIDGE_DISCOVERED_RELIABILITY_UNKNOWN = -1,
    BRIDGE_DISCOVERED_RELIABILITY_BEST_EFFORT = 0,
    BRIDGE_DISCOVERED_RELIABILITY_RELIABLE = 1
} bridge_discovered_reliability_t;

/// The durability of a discovered writer.
typedef enum {
    /// The writer's QoS carries no durability policy.
    BRIDGE_DISCOVERED_DURABILITY_UNKNOWN = -1,
    BRIDGE_DISCOVERED_DURABILITY_VOLATILE = 0,
    BRIDGE_DISCOVERED_DURABILITY_TRANSIENT_LOCAL = 1,
    BRIDGE_DISCOVERED_DURABILITY_TRANSIENT = 2,
    BRIDGE_DISCOVERED_DURABILITY_PERSISTENT = 3
} bridge_discovered_durability_t;

/// One writer of the domain, as the builtin DCPSPublication topic lists it. Every
/// pointer is owned by the bridge and valid only during the callback.
typedef struct {
    /// The writer's GUID (DDS_BRIDGE_GUID_SIZE bytes), the form dds_get_guid returns.
    const uint8_t* endpoint_guid;
    /// The GUID of the writer's participant (DDS_BRIDGE_GUID_SIZE bytes).
    const uint8_t* participant_guid;
    /// The DDS topic name, for example "rt/chatter".
    const char* topic_name;
    /// The DDS type name, for example "std_msgs::msg::dds_::String_".
    const char* type_name;
    bridge_discovered_reliability_t reliability;
    bridge_discovered_durability_t durability;
} bridge_publication_info_t;

/// Called once per alive writer by dds_bridge_enumerate_publications().
typedef void (*dds_bridge_publication_callback_t)(const bridge_publication_info_t* info, void* context);

/// Called once per alive participant by dds_bridge_enumerate_publications(), with its
/// GUID (DDS_BRIDGE_GUID_SIZE bytes, valid only during the call).
typedef void (*dds_bridge_participant_callback_t)(const uint8_t* participant_guid, void* context);

/// Lists every writer and every participant the session's participant has discovered
/// in its domain, its own and those of other participants in the process included.
///
/// The first call creates readers of the builtin DCPSPublication and DCPSParticipant
/// topics on the session's participant; they live until the session is destroyed. The
/// builtin writers keep their history, so the first call already sees every endpoint
/// discovered so far. Each call reads the alive instances with loaned samples and
/// calls back synchronously on the calling thread, writers first, then participants;
/// it also takes the instances that are no longer alive, so disposed endpoints do not
/// pile up in the readers. The callbacks must not call back into the bridge.
///
/// Not thread-safe against dds_bridge_destroy_session() or another call on the same
/// session; the caller serializes them.
///
/// @param session Active DDS session
/// @param publication_cb Called for each alive writer (must be non-NULL)
/// @param participant_cb Called for each alive participant (may be NULL)
/// @param context Opaque pointer passed to both callbacks
/// @return 0 on success, negative on failure (check dds_bridge_get_last_error())
int32_t dds_bridge_enumerate_publications(
    bridge_dds_session_t* session,
    dds_bridge_publication_callback_t publication_cb,
    dds_bridge_participant_callback_t participant_cb,
    void* context
);

// =============================================================================
// MARK: - Error Handling
// =============================================================================

/// Get the last error message
///
/// @return Error message string (thread-local, do not free)
const char* dds_bridge_get_last_error(void);

// =============================================================================
// MARK: - Availability
// =============================================================================

/// Check if DDS bridge is available (compiled with CycloneDDS)
///
/// @return true if DDS is available, false otherwise
bool dds_bridge_is_available(void);

#ifdef __cplusplus
}
#endif

#endif // DDS_BRIDGE_H
