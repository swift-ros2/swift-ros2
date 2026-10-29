//
// dds_bridge.c
// C-FFI bridge for CycloneDDS
//
// Implementation of the DDS bridge that wraps CycloneDDS functionality
// for use from Swift via C-FFI.
//

#include "dds_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdatomic.h>
#ifdef __APPLE__
  #include <dispatch/dispatch.h>
#endif

#include <dds/dds.h>
#include "raw_cdr_sertype.h"
#include "signal_mask_scope.h"

// =============================================================================
// MARK: - Thread-Local Error Storage
// =============================================================================

#ifdef _Thread_local
#define THREAD_LOCAL _Thread_local
#elif defined(__GNUC__) || defined(__clang__)
#define THREAD_LOCAL __thread
#else
#define THREAD_LOCAL
#endif

static THREAD_LOCAL char g_last_error[512] = {0};

static void set_error(const char* format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(g_last_error, sizeof(g_last_error), format, args);
    va_end(args);
}

const char* dds_bridge_get_last_error(void) {
    return g_last_error;
}

// =============================================================================
// MARK: - Availability
// =============================================================================

bool dds_bridge_is_available(void) {
    return true;
}

// =============================================================================
// MARK: - Session Structure
// =============================================================================

struct bridge_dds_session_s {
    dds_entity_t domain;
    dds_entity_t participant;
    dds_entity_t publisher;
    int32_t domain_id;
    char session_id[33];  // 32 hex chars + null terminator
    bool is_connected;
    // Builtin DCPSPublication / DCPSParticipant readers, created by the first
    // dds_bridge_enumerate_publications() call; children of `participant`,
    // so they are deleted with it.
    struct bridge_builtin_reader {
        dds_entity_t reader;
        // The size of every sample buffer passed to the reader. It only grows:
        // CycloneDDS before 11 caches one loan per reader and, when lending it,
        // fills as many buffer slots as the largest read so far asked for.
        size_t batch;
    } publications, participants;
};

// =============================================================================
// MARK: - Writer Structure
// =============================================================================

struct bridge_dds_writer_s {
    dds_entity_t writer;
    dds_entity_t topic;
    struct ddsi_sertype* raw_sertype;
    bridge_dds_session_t* session;
    char topic_name[256];
    // Atomic for the same reason as the reader's flag: set and read on different threads.
    atomic_bool is_active;
};

// =============================================================================
// MARK: - Reader Structure
// =============================================================================

struct bridge_dds_reader_s {
    dds_entity_t reader;
    dds_entity_t topic;
    dds_listener_t* listener;
    struct ddsi_sertype* raw_sertype;
    bridge_dds_session_t* session;
    dds_bridge_data_callback_t user_callback;
    void* user_context;
    char topic_name[256];
    // Read by the listener on the thread that delivers a sample (a local writer's
    // thread) while another thread may destroy the reader, so atomic (#326).
    atomic_bool is_active;
    // Drain requests not yet served; see drain_reader().
    atomic_uint drain_requests;
};

// =============================================================================
// MARK: - Session Management Implementation
// =============================================================================

// Track whether a domain has been created for this process.
// CycloneDDS domains are shared per domain_id - once created, the config
// applies to all participants. Multiple sessions share the same domain.
static bool g_domain_created = false;
static int32_t g_domain_id = -1;

#define DOMAIN_CONFIG_XML_SIZE 8192

// Append formatted text to the XML buffer, checking for overflow/truncation.
// On overflow or encoding error, frees the buffer, sets *xml_out to NULL, and
// returns false so the caller can abort.
static bool xml_append(char** xml_out, size_t* offset, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

static bool xml_append(char** xml_out, size_t* offset, const char* fmt, ...) {
    if (!xml_out || !*xml_out || !offset) {
        return false;
    }
    if (*offset >= DOMAIN_CONFIG_XML_SIZE) {
        free(*xml_out);
        *xml_out = NULL;
        return false;
    }
    size_t remaining = DOMAIN_CONFIG_XML_SIZE - *offset;

    va_list ap;
    va_start(ap, fmt);
    int needed = vsnprintf(*xml_out + *offset, remaining, fmt, ap);
    va_end(ap);

    if (needed < 0 || (size_t)needed >= remaining) {
        // Encoding error or truncation - treat as fatal.
        free(*xml_out);
        *xml_out = NULL;
        return false;
    }
    *offset += (size_t)needed;
    return true;
}

/// Build XML configuration string for CycloneDDS domain
/// Returns a malloc'd string that must be freed by the caller
char* dds_bridge_build_domain_config_xml(int32_t domain_id, const bridge_discovery_config_t* config) {
    char* xml = malloc(DOMAIN_CONFIG_XML_SIZE);
    if (!xml) {
        return NULL;
    }

    size_t offset = 0;
    if (!xml_append(&xml, &offset,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<CycloneDDS xmlns=\"https://cdds.io/config\">\n"
        "  <Domain id=\"%d\">\n",
        domain_id)) {
        return NULL;
    }

    // Add discovery configuration
    if (config && (config->unicast_peers && config->peer_count > 0)) {
        if (!xml_append(&xml, &offset,
            "    <Discovery>\n"
            "      <Peers>\n")) {
            return NULL;
        }

        // Add each peer
        for (int i = 0; i < config->peer_count; i++) {
            if (!xml_append(&xml, &offset,
                "        <Peer address=\"%s\"/>\n",
                config->unicast_peers[i])) {
                return NULL;
            }
        }

        if (!xml_append(&xml, &offset, "      </Peers>\n")) {
            return NULL;
        }

        // NOTE: do not emit <EnableTopicDiscoveryEndpoints> here. It does not
        // disable multicast SPDP (it toggles DCPSTopic discovery, which ROS 2
        // graph discovery does not use), and CycloneDDS builds compiled without
        // topic-discovery support — e.g. the bundled wire CCycloneDDS fork
        // (built with -DENABLE_TOPIC_DISCOVERY=OFF) — reject it as an unknown
        // element and fail the domain creation (issue #149). Leaving multicast SPDP
        // enabled next to the explicit <Peers> is harmless: it is simply
        // ignored on networks without multicast (typical Wi-Fi).

        // Faster SPDP discovery for mobile devices (default is 30s)
        if (!xml_append(&xml, &offset, "      <SPDPInterval>1s</SPDPInterval>\n")) {
            return NULL;
        }

        if (!xml_append(&xml, &offset, "    </Discovery>\n")) {
            return NULL;
        }
    }

    // General configuration: network interface + large message support
    if (!xml_append(&xml, &offset, "    <General>\n")) {
        return NULL;
    }

    // Network interface binding
    if (config && config->network_interface && strlen(config->network_interface) > 0) {
        if (!xml_append(&xml, &offset,
            "      <Interfaces>\n"
            "        <NetworkInterface name=\"%s\"/>\n"
            "      </Interfaces>\n",
            config->network_interface)) {
            return NULL;
        }
    }

    // Keep default MaxMessageSize (14720B) and FragmentSize (1344B).
    // Large payloads like camera images are automatically fragmented at
    // the DDS level by CycloneDDS's RTPS fragmentation (DATA_FRAG).
    if (!xml_append(&xml, &offset, "    </General>\n")) {
        return NULL;
    }

    if (!xml_append(&xml, &offset,
        "  </Domain>\n"
        "</CycloneDDS>\n")) {
        return NULL;
    }

    return xml;
}

void dds_bridge_free_string(char* s) {
    free(s);
}

static bridge_dds_session_t* create_session(
    int32_t domain_id,
    const bridge_discovery_config_t* discovery_config
) {
    // Validate domain ID
    if (domain_id < 0 || domain_id > 232) {
        set_error("Invalid domain ID: %d (must be 0-232)", domain_id);
        return NULL;
    }

    // Allocate session structure
    bridge_dds_session_t* session = calloc(1, sizeof(bridge_dds_session_t));
    if (!session) {
        set_error("Failed to allocate session structure");
        return NULL;
    }

    session->domain_id = domain_id;
    session->is_connected = false;

    // Build XML configuration for discovery peers
    char* config_xml = dds_bridge_build_domain_config_xml(domain_id, discovery_config);
    if (config_xml) {
        // Create domain with XML configuration only if not yet created or domain ID changed.
        // CycloneDDS domains are shared: all participants with the same domain_id
        // use the same domain config. Only the first dds_create_domain() call applies
        // the config; subsequent calls for the same ID return an error (already exists).
        // This means domain config (NetworkInterface, MaxMessageSize, etc.) is fixed
        // for the lifetime of the process - changing it requires an app restart.
        if (!g_domain_created || g_domain_id != domain_id) {
            dds_entity_t domain = dds_create_domain(domain_id, config_xml);

            if (domain >= 0) {
                session->domain = domain;
                g_domain_created = true;
                g_domain_id = domain_id;
            } else if (domain != DDS_RETCODE_PRECONDITION_NOT_MET) {
                // CycloneDDS rejected the discovery config (bad peer address,
                // unsupported element, ...). Falling through would create the
                // participant on an implicit DEFAULT-configured domain: no
                // <Peers>, multicast SPDP, and a session that reports itself
                // connected while discovering nothing. That silent degradation
                // is indistinguishable from a firewall block and is exactly the
                // class of failure issue #176 was misdiagnosed as. Fail loudly.
                //
                // PRECONDITION_NOT_MET is the one tolerated case: the domain
                // already exists (created by another session or by rmw), so the
                // config cannot be applied but the existing one is valid. That
                // is the documented process-lifetime limitation above.
                //
                // The same return covers a domain whose sockets cannot be
                // bound, e.g. a discovery port (7400 + 250 x id) inside a
                // range Windows reserved: CycloneDDS returns DDS_RETCODE_ERROR
                // and logs "failed to bind to ANY:<port>: Not allowed".
                set_error("CycloneDDS rejected the discovery configuration of domain %d: %s"
                          " (an unusable setting, or a discovery port it could not bind)",
                    domain_id, dds_strretcode(domain));
                free(config_xml);
                free(session);
                return NULL;
            }
        }

        free(config_xml);
    }

    // Create participant QoS with enclave USER_DATA (required by rmw_cyclonedds_cpp)
    dds_qos_t* ppant_qos = dds_create_qos();
    if (ppant_qos) {
        const char* enclave_data = "enclave=/;";
        dds_qset_userdata(ppant_qos, enclave_data, strlen(enclave_data));
    }

    // Create domain participant (will use the domain configuration we just set)
    session->participant = dds_create_participant(domain_id, ppant_qos, NULL);
    if (ppant_qos) {
        dds_delete_qos(ppant_qos);
    }
    if (session->participant < 0) {
        set_error("Failed to create participant: %s", dds_strretcode(session->participant));
        free(session);
        return NULL;
    }

    // Create publisher
    session->publisher = dds_create_publisher(session->participant, NULL, NULL);
    if (session->publisher < 0) {
        set_error("Failed to create publisher: %s", dds_strretcode(session->publisher));
        dds_delete(session->participant);
        free(session);
        return NULL;
    }

    // Get participant GUID for session ID
    dds_guid_t guid;
    if (dds_get_guid(session->participant, &guid) == 0) {
        // Convert GUID to hex string (first 16 bytes)
        for (int i = 0; i < 16; i++) {
            snprintf(session->session_id + (i * 2), 3, "%02x", guid.v[i]);
        }
    } else {
        // Fallback: generate random session ID
        for (int i = 0; i < 32; i++) {
            session->session_id[i] = "0123456789abcdef"[rand() % 16];
        }
    }
    session->session_id[32] = '\0';

    session->is_connected = true;

    return session;
}

bridge_dds_session_t* dds_bridge_create_session(
    int32_t domain_id,
    const bridge_discovery_config_t* discovery_config
) {
    // dds_create_domain starts CycloneDDS's threads; keep the process's signal
    // masks intact while it does (#290, see signal_mask_scope.c).
    swiftros2_signal_mask_scope_t scope;
    swiftros2_signal_mask_scope_enter(&scope);
    bridge_dds_session_t* session = create_session(domain_id, discovery_config);
    swiftros2_signal_mask_scope_exit(&scope);
    return session;
}

#ifdef __APPLE__
// Upper bound on how long dds_bridge_destroy_session waits for the participant
// delete before it gives up and leaks the participant.
#define PARTICIPANT_DELETE_TIMEOUT_NS (3LL * NSEC_PER_SEC)
#endif

void dds_bridge_destroy_session(bridge_dds_session_t* session) {
    if (!session) {
        return;
    }

    // Delete publisher first
    if (session->publisher > 0) {
        dds_delete(session->publisher);
        session->publisher = 0;
    }

    // Delete the participant, so that it leaves the network (remote hosts drop
    // it at once instead of keeping it until its lease expires) and frees its
    // memory. dds_bridge_create_session creates the domain explicitly and
    // nothing deletes it, so deleting the session's participant does not tear
    // the domain down. (Participants used to be leaked because dds_delete hung
    // on iOS back when the domain was implicit, so that deleting the last
    // participant also tore the domain down.)
    if (session->participant > 0) {
        dds_entity_t participant = session->participant;
        session->participant = 0;
#ifdef __APPLE__
        // Bound the wait anyway so that a hung delete cannot block the caller
        // forever: after the timeout the delete keeps running on its own and
        // this session's participant is leaked if it never completes.
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_retain(done);  // released by the block
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dds_delete(participant);
            dispatch_semaphore_signal(done);
            dispatch_release(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, PARTICIPANT_DELETE_TIMEOUT_NS)) != 0) {
            fprintf(stderr, "[dds_bridge] participant delete timed out; leaking participant %d\n",
                    (int)participant);
        }
        dispatch_release(done);
#else
        dds_delete(participant);
#endif
    }

    session->is_connected = false;
    free(session);
}

bool dds_bridge_session_is_connected(const bridge_dds_session_t* session) {
    if (!session) {
        return false;
    }
    return session->is_connected;
}

int32_t dds_bridge_get_session_id(
    const bridge_dds_session_t* session,
    char* buffer,
    size_t buffer_size
) {
    if (!session || !buffer || buffer_size < 33) {
        set_error("Invalid parameters for dds_bridge_get_session_id");
        return -1;
    }

    strncpy(buffer, session->session_id, buffer_size - 1);
    buffer[buffer_size - 1] = '\0';
    return 0;
}

// =============================================================================
// MARK: - Writer Management Implementation
// =============================================================================

void dds_bridge_destroy_writer(bridge_dds_writer_t* writer) {
    if (!writer) {
        return;
    }

    if (writer->writer > 0) {
        dds_delete(writer->writer);
        writer->writer = 0;
    }
    if (writer->topic > 0) {
        dds_delete(writer->topic);
        writer->topic = 0;
    }
    // Release the sertype reference held since create_raw_writer (mirrors
    // dds_bridge_destroy_reader).
    if (writer->raw_sertype) {
        ddsi_sertype_unref(writer->raw_sertype);
        writer->raw_sertype = NULL;
    }

    free(writer);
}

bool dds_bridge_writer_is_active(const bridge_dds_writer_t* writer) {
    if (!writer) {
        return false;
    }
    return atomic_load(&writer->is_active);
}

int32_t dds_bridge_writer_matched_count(const bridge_dds_writer_t* writer) {
    if (!writer) {
        return -1;
    }
    if (writer->writer <= 0) {
        return -1;
    }
    dds_publication_matched_status_t status;
    if (dds_get_publication_matched_status(writer->writer, &status) != DDS_RETCODE_OK) {
        return -1;
    }
    return (int32_t)status.current_count;
}

// =============================================================================
// MARK: - Raw CDR Publishing Implementation
// =============================================================================

bridge_dds_writer_t* dds_bridge_create_raw_writer(
    bridge_dds_session_t* session,
    const char* topic_name,
    const char* type_name,
    const bridge_qos_config_t* qos,
    const char* user_data
) {
    if (!session || !topic_name || !type_name) {
        set_error("Invalid parameters for dds_bridge_create_raw_writer");
        return NULL;
    }

    if (!session->is_connected) {
        set_error("Session is not connected");
        return NULL;
    }

    // Allocate writer structure
    bridge_dds_writer_t* writer = calloc(1, sizeof(bridge_dds_writer_t));
    if (!writer) {
        set_error("Failed to allocate writer structure");
        return NULL;
    }

    writer->session = session;
    strncpy(writer->topic_name, topic_name, sizeof(writer->topic_name) - 1);
    atomic_init(&writer->is_active, false);

    // Use default QoS if not specified
    const bridge_qos_config_t* effective_qos = qos ? qos : &BRIDGE_QOS_SENSOR_DATA;

    // Create raw CDR sertype
    writer->raw_sertype = raw_cdr_sertype_new(type_name);
    if (!writer->raw_sertype) {
        set_error("Failed to create raw CDR sertype for '%s'", type_name);
        free(writer);
        return NULL;
    }

    // Create topic using raw CDR sertype
    // Note: dds_create_topic_sertype takes ownership of sertype reference,
    // and may replace the sertype pointer with an existing compatible one.
    // We add a reference before calling, and after the call we need to use
    // the (possibly updated) sertype pointer.
    struct ddsi_sertype* sertype_for_topic = ddsi_sertype_ref(writer->raw_sertype);
    writer->topic = dds_create_topic_sertype(
        session->participant,
        topic_name,
        &sertype_for_topic,
        NULL,  // qos
        NULL,  // listener
        NULL   // sedp_plist
    );

    if (writer->topic < 0) {
        set_error("Failed to create raw CDR topic '%s': %s", topic_name, dds_strretcode(writer->topic));
        // On failure dds_create_topic_impl does not consume the passed-in
        // reference, so both of our references — the stored one and the one
        // passed via sertype_for_topic (the same pointer at this point) —
        // must be released here. Two failure classes exist and both leave the
        // passed-in reference with us:
        //   1. The plain `goto error` paths (bad qos, security, ktopic lookup;
        //      vendor/cyclonedds src/core/ddsc/src/dds_topic.c) never touch
        //      *sertype.
        //   2. The DDS_HAS_TYPE_DISCOVERY `error_typeref` path DOES call
        //      ddsi_sertype_unref(*sertype), but that only balances the +1 that
        //      ddsi_sertype_register_locked took a few lines earlier — it is
        //      the registration's own reference, not ours.
        // CycloneDDS's own dds_create_topic confirms the contract: it holds a
        // single reference and unrefs it exactly once on every failure
        // (including error_typeref) without double-freeing. We hold two
        // independent references, so we unref twice.
        ddsi_sertype_unref(sertype_for_topic);
        ddsi_sertype_unref(writer->raw_sertype);
        free(writer);
        return NULL;
    }

    // If dds_create_topic_sertype returned a different sertype (because a matching
    // one was already registered), we need to use that one for creating serdata.
    // Release our original reference and use the one from topic creation.
    if (sertype_for_topic != writer->raw_sertype) {
        ddsi_sertype_unref(writer->raw_sertype);
        writer->raw_sertype = ddsi_sertype_ref(sertype_for_topic);
    }

    // Create writer QoS
    dds_qos_t* writer_qos = dds_create_qos();
    if (!writer_qos) {
        set_error("Failed to create writer QoS");
        dds_delete(writer->topic);
        ddsi_sertype_unref(writer->raw_sertype);
        free(writer);
        return NULL;
    }

    // Set reliability
    if (effective_qos->reliability == BRIDGE_RELIABILITY_RELIABLE) {
        dds_qset_reliability(writer_qos, DDS_RELIABILITY_RELIABLE, DDS_MSECS(100));
    } else {
        dds_qset_reliability(writer_qos, DDS_RELIABILITY_BEST_EFFORT, 0);
    }

    // Set durability
    if (effective_qos->durability == BRIDGE_DURABILITY_TRANSIENT_LOCAL) {
        dds_qset_durability(writer_qos, DDS_DURABILITY_TRANSIENT_LOCAL);
    } else {
        dds_qset_durability(writer_qos, DDS_DURABILITY_VOLATILE);
    }

    // Set history
    if (effective_qos->history_kind == BRIDGE_HISTORY_KEEP_ALL) {
        dds_qset_history(writer_qos, DDS_HISTORY_KEEP_ALL, 0);
    } else {
        dds_qset_history(writer_qos, DDS_HISTORY_KEEP_LAST, effective_qos->history_depth);
    }

    // Set USER_DATA QoS (type hash for rmw_cyclonedds_cpp discovery)
    if (user_data && strlen(user_data) > 0) {
        dds_qset_userdata(writer_qos, user_data, strlen(user_data));
    }

    // Create writer
    writer->writer = dds_create_writer(session->publisher, writer->topic, writer_qos, NULL);
    dds_delete_qos(writer_qos);

    if (writer->writer < 0) {
        set_error("Failed to create raw CDR writer for topic '%s': %s",
                  topic_name, dds_strretcode(writer->writer));
        dds_delete(writer->topic);
        ddsi_sertype_unref(writer->raw_sertype);
        free(writer);
        return NULL;
    }

    atomic_store(&writer->is_active, true);

    return writer;
}

int32_t dds_bridge_write_raw_cdr(
    bridge_dds_writer_t* writer,
    const uint8_t* cdr_data,
    size_t cdr_len,
    uint64_t timestamp_ns
) {
    if (!writer || !cdr_data || cdr_len == 0) {
        set_error("Invalid parameters for dds_bridge_write_raw_cdr");
        return -1;
    }

    if (!atomic_load(&writer->is_active)) {
        set_error("Writer is not active");
        return -2;
    }

    // Verify CDR data has encapsulation header
    if (cdr_len < 4) {
        set_error("CDR data too short (missing encapsulation header)");
        return -4;
    }

    if (writer->raw_sertype == NULL) {
        set_error("raw_sertype is NULL");
        return -10;
    }

    // Create raw CDR serdata
    dds_time_t timestamp = (dds_time_t)timestamp_ns;
    struct ddsi_serdata* serdata = raw_cdr_serdata_new(
        writer->raw_sertype,
        cdr_data,
        cdr_len,
        timestamp
    );

    if (!serdata) {
        set_error("Failed to create raw CDR serdata");
        return -5;
    }

    // dds_writecdr's ownership contract is asymmetric: once the writer lock
    // is taken, dds_writecdr_impl_common consumes one serdata reference on
    // every path, success or failure ("consumes 1 refc from din in all
    // paths", vendor/cyclonedds/src/core/ddsc/src/dds_write.c:293). A
    // RELIABLE writer with a full WHC returns DDS_RETCODE_TIMEOUT with the
    // reference already consumed, so unref-on-failure would double-free.
    // Only the pre-lock early-outs (NULL serdata, invalid writer handle,
    // topic filter; dds_write.c:65-74) leave ownership with the caller.
    // Take an extra reference before the call and release exactly one
    // afterwards so success and all post-lock failures are balanced; the
    // rare pre-lock failure then leaks one serdata instead of corrupting
    // the heap.
    ddsi_serdata_ref(serdata);
    dds_return_t ret = dds_writecdr(writer->writer, serdata);
    ddsi_serdata_unref(serdata);

    if (ret < 0) {
        set_error("Failed to write raw CDR data: %s", dds_strretcode(ret));
        return -6;
    }

    return 0;
}

// =============================================================================
// MARK: - Raw CDR Subscribing Implementation
// =============================================================================

/// Takes every sample of the reader and passes the valid ones to the user callback,
/// with dds_takecdr in batches of 16, matching rmw_cyclonedds_cpp's default batch size
/// to keep stack usage bounded.
static void take_all_samples(bridge_dds_reader_t* reader, dds_entity_t reader_entity) {
    enum { BATCH = 16 };
    struct ddsi_serdata* sdbuf[BATCH];
    dds_sample_info_t info[BATCH];

    for (;;) {
        // Zero the serdata pointers so we don't accidentally unref stale garbage.
        for (int i = 0; i < BATCH; i++) {
            sdbuf[i] = NULL;
        }

        dds_return_t n = dds_takecdr(reader_entity, sdbuf, BATCH, info, DDS_ANY_STATE);
        if (n <= 0) {
            break;
        }

        for (dds_return_t i = 0; i < n; i++) {
            struct ddsi_serdata* sd = sdbuf[i];
            if (!sd) {
                continue;
            }
            if (info[i].valid_data) {
                // sd is our raw_cdr_serdata (we own the type); safe to downcast.
                const struct raw_cdr_serdata* rd = (const struct raw_cdr_serdata*)sd;
                uint64_t ts_ns = (info[i].source_timestamp == DDS_TIME_INVALID)
                    ? 0
                    : (uint64_t)info[i].source_timestamp;
                reader->user_callback(rd->cdr_data, rd->cdr_size, ts_ns, reader->user_context);
            }
            ddsi_serdata_unref(sd);
        }

        if ((uint32_t)n < (uint32_t)BATCH) {
            // Likely drained - avoid an extra syscall next iteration.
            break;
        }
    }
}

/// Takes the reader's samples on behalf of every caller that asks while a drain is
/// running, so the user callback never runs on two threads at once for one reader.
///
/// The first caller drains; a caller that finds a drain running only counts its
/// request and returns, and the draining thread takes again before it stops. That
/// covers the listener firing on a CycloneDDS thread while the creating thread drains
/// (see dds_bridge_drain_reader) and a callback whose own write is delivered to
/// this reader on the same thread, without a lock that either case could deadlock on.
static void drain_reader(bridge_dds_reader_t* reader, dds_entity_t reader_entity) {
    if (atomic_fetch_add(&reader->drain_requests, 1) != 0) {
        return;
    }
    for (;;) {
        take_all_samples(reader, reader_entity);
        unsigned int served = 1;
        if (atomic_compare_exchange_strong(&reader->drain_requests, &served, 0)) {
            return;
        }
        // More requests came in while taking: serve them with one more pass.
        atomic_store(&reader->drain_requests, 1);
    }
}

/// Listener callback invoked by CycloneDDS when new data is available on the reader.
static void bridge_on_data_available(dds_entity_t reader_entity, void* arg) {
    bridge_dds_reader_t* reader = (bridge_dds_reader_t*)arg;
    if (!reader || !atomic_load(&reader->is_active) || !reader->user_callback) {
        return;
    }
    drain_reader(reader, reader_entity);
}

bridge_dds_reader_t* dds_bridge_create_raw_reader(
    bridge_dds_session_t* session,
    const char* topic_name,
    const char* type_name,
    const bridge_qos_config_t* qos,
    const char* user_data,
    dds_bridge_data_callback_t callback,
    void* context
) {
    if (!session || !topic_name || !type_name || !callback) {
        set_error("Invalid parameters for dds_bridge_create_raw_reader");
        return NULL;
    }

    if (!session->is_connected) {
        set_error("Session is not connected");
        return NULL;
    }

    // Allocate reader structure
    bridge_dds_reader_t* reader = calloc(1, sizeof(bridge_dds_reader_t));
    if (!reader) {
        set_error("Failed to allocate reader structure");
        return NULL;
    }

    reader->session = session;
    reader->user_callback = callback;
    reader->user_context = context;
    atomic_init(&reader->drain_requests, 0);
    strncpy(reader->topic_name, topic_name, sizeof(reader->topic_name) - 1);
    atomic_init(&reader->is_active, false);

    // Use default QoS if not specified
    const bridge_qos_config_t* effective_qos = qos ? qos : &BRIDGE_QOS_SENSOR_DATA;

    // Create raw CDR sertype (same pattern as create_raw_writer)
    reader->raw_sertype = raw_cdr_sertype_new(type_name);
    if (!reader->raw_sertype) {
        set_error("Failed to create raw CDR sertype for '%s'", type_name);
        free(reader);
        return NULL;
    }

    // Create topic using raw CDR sertype.
    // Note: dds_create_topic_sertype takes ownership of sertype reference,
    // and may replace the sertype pointer with an existing compatible one.
    struct ddsi_sertype* sertype_for_topic = ddsi_sertype_ref(reader->raw_sertype);
    reader->topic = dds_create_topic_sertype(
        session->participant,
        topic_name,
        &sertype_for_topic,
        NULL,  // qos
        NULL,  // listener
        NULL   // sedp_plist
    );

    if (reader->topic < 0) {
        set_error("Failed to create raw CDR topic '%s': %s",
                  topic_name, dds_strretcode(reader->topic));
        // On failure dds_create_topic_impl does not consume the passed-in
        // reference — neither the plain `goto error` paths nor the
        // DDS_HAS_TYPE_DISCOVERY `error_typeref` path (whose
        // ddsi_sertype_unref only balances the registration's own +1). See the
        // matching comment in create_raw_writer. Release both of our
        // independent references here.
        ddsi_sertype_unref(sertype_for_topic);
        ddsi_sertype_unref(reader->raw_sertype);
        free(reader);
        return NULL;
    }

    // If dds_create_topic_sertype returned a different sertype (because a matching
    // one was already registered), use that one going forward.
    if (sertype_for_topic != reader->raw_sertype) {
        ddsi_sertype_unref(reader->raw_sertype);
        reader->raw_sertype = ddsi_sertype_ref(sertype_for_topic);
    }

    // Create reader QoS
    dds_qos_t* reader_qos = dds_create_qos();
    if (!reader_qos) {
        set_error("Failed to create reader QoS");
        dds_delete(reader->topic);
        ddsi_sertype_unref(reader->raw_sertype);
        free(reader);
        return NULL;
    }

    // Set reliability
    if (effective_qos->reliability == BRIDGE_RELIABILITY_RELIABLE) {
        dds_qset_reliability(reader_qos, DDS_RELIABILITY_RELIABLE, DDS_MSECS(100));
    } else {
        dds_qset_reliability(reader_qos, DDS_RELIABILITY_BEST_EFFORT, 0);
    }

    // Set durability
    if (effective_qos->durability == BRIDGE_DURABILITY_TRANSIENT_LOCAL) {
        dds_qset_durability(reader_qos, DDS_DURABILITY_TRANSIENT_LOCAL);
    } else {
        dds_qset_durability(reader_qos, DDS_DURABILITY_VOLATILE);
    }

    // Set history
    if (effective_qos->history_kind == BRIDGE_HISTORY_KEEP_ALL) {
        dds_qset_history(reader_qos, DDS_HISTORY_KEEP_ALL, 0);
    } else {
        dds_qset_history(reader_qos, DDS_HISTORY_KEEP_LAST, effective_qos->history_depth);
    }

    // Set USER_DATA QoS (type hash for rmw_cyclonedds_cpp discovery)
    if (user_data && strlen(user_data) > 0) {
        dds_qset_userdata(reader_qos, user_data, strlen(user_data));
    }

    // Create listener with the bridge reader as the arg pointer, then install
    // the data_available callback. Use the plain _arg-less dds_lset_data_available
    // to remain compatible with older CycloneDDS (Ubuntu Humble's 0.9) which
    // predates dds_lset_data_available_arg.
    reader->listener = dds_create_listener(reader);
    if (!reader->listener) {
        set_error("Failed to create reader listener");
        dds_delete_qos(reader_qos);
        dds_delete(reader->topic);
        ddsi_sertype_unref(reader->raw_sertype);
        free(reader);
        return NULL;
    }
    dds_lset_data_available(reader->listener, bridge_on_data_available);

    // Create reader directly under the participant (CycloneDDS auto-creates an
    // implicit subscriber). This mirrors rmw_cyclonedds_cpp.
    reader->reader = dds_create_reader(
        session->participant, reader->topic, reader_qos, reader->listener);
    dds_delete_qos(reader_qos);

    if (reader->reader < 0) {
        set_error("Failed to create raw CDR reader for topic '%s': %s",
                  topic_name, dds_strretcode(reader->reader));
        dds_delete_listener(reader->listener);
        dds_delete(reader->topic);
        ddsi_sertype_unref(reader->raw_sertype);
        free(reader);
        return NULL;
    }

    atomic_store(&reader->is_active, true);

    // The samples the reader got while dds_create_reader ran are not taken here: the
    // caller passes them on with dds_bridge_drain_reader once it holds no lock.
    return reader;
}

void dds_bridge_drain_reader(bridge_dds_reader_t* reader) {
    // A transient-local reader gets the cached samples of the writers in this process
    // while dds_create_reader runs, before the listener is armed, and no listener call
    // follows for them: without this drain they would wait for the next live sample.
    // Samples from remote writers arrive later and go through the listener.
    if (!reader || !atomic_load(&reader->is_active) || reader->reader <= 0) {
        return;
    }
    drain_reader(reader, reader->reader);
}

void dds_bridge_destroy_reader(bridge_dds_reader_t* reader) {
    if (!reader) {
        return;
    }

    atomic_store(&reader->is_active, false);

    // dds_delete on the reader blocks until any in-flight listener callback
    // completes (CycloneDDS contract), so after this returns the callback will
    // never fire again.
    if (reader->reader > 0) {
        dds_delete(reader->reader);
        reader->reader = 0;
    }
    if (reader->topic > 0) {
        dds_delete(reader->topic);
        reader->topic = 0;
    }
    if (reader->listener) {
        dds_delete_listener(reader->listener);
        reader->listener = NULL;
    }
    if (reader->raw_sertype) {
        ddsi_sertype_unref(reader->raw_sertype);
        reader->raw_sertype = NULL;
    }

    free(reader);
}

bool dds_bridge_reader_is_active(const bridge_dds_reader_t* reader) {
    if (!reader) {
        return false;
    }
    return atomic_load(&reader->is_active);
}

int32_t dds_bridge_reader_matched_count(const bridge_dds_reader_t* reader) {
    if (!reader) {
        return -1;
    }
    if (reader->reader <= 0) {
        return -1;
    }
    dds_subscription_matched_status_t status;
    if (dds_get_subscription_matched_status(reader->reader, &status) != DDS_RETCODE_OK) {
        return -1;
    }
    return (int32_t)status.current_count;
}

// =============================================================================
// MARK: - Entity GUIDs
// =============================================================================

static int32_t copy_entity_guid(dds_entity_t entity, uint8_t* guid_out) {
    if (entity <= 0 || !guid_out) {
        set_error("Invalid parameters for the entity GUID query");
        return -1;
    }
    dds_guid_t guid;
    dds_return_t ret = dds_get_guid(entity, &guid);
    if (ret != DDS_RETCODE_OK) {
        set_error("dds_get_guid failed: %s", dds_strretcode(ret));
        return -1;
    }
    memcpy(guid_out, guid.v, DDS_BRIDGE_GUID_SIZE);
    return 0;
}

int32_t dds_bridge_get_participant_guid(const bridge_dds_session_t* session, uint8_t* guid_out) {
    if (!session) {
        set_error("Invalid parameters for dds_bridge_get_participant_guid");
        return -1;
    }
    return copy_entity_guid(session->participant, guid_out);
}

int32_t dds_bridge_writer_get_guid(const bridge_dds_writer_t* writer, uint8_t* guid_out) {
    if (!writer) {
        set_error("Invalid parameters for dds_bridge_writer_get_guid");
        return -1;
    }
    return copy_entity_guid(writer->writer, guid_out);
}

int32_t dds_bridge_reader_get_guid(const bridge_dds_reader_t* reader, uint8_t* guid_out) {
    if (!reader) {
        set_error("Invalid parameters for dds_bridge_reader_get_guid");
        return -1;
    }
    return copy_entity_guid(reader->reader, guid_out);
}

// =============================================================================
// MARK: - Discovered Publications (topic graph)
// =============================================================================

// Samples are read in batches of this size; a batch that comes back full is
// read again with a larger one, up to MAX_BUILTIN_BATCH. A full batch of that size
// fails the read rather than return a list that may be cut short.
#define FIRST_BUILTIN_BATCH 256
#define MAX_BUILTIN_BATCH 65536

typedef struct bridge_builtin_reader builtin_reader_t;

static int32_t ensure_builtin_reader(
    bridge_dds_session_t* session, dds_entity_t topic, builtin_reader_t* slot, const char* what) {
    if (slot->reader > 0) {
        return 0;
    }
    // The builtin topics come with their own default reader QoS (reliable,
    // transient-local, keep-last 1 per instance), so a reader created late
    // still sees every endpoint discovered before it.
    dds_entity_t reader = dds_create_reader(session->participant, topic, NULL, NULL);
    if (reader < 0) {
        set_error("Failed to create the builtin %s reader: %s", what, dds_strretcode(reader));
        return -1;
    }
    slot->reader = reader;
    slot->batch = FIRST_BUILTIN_BATCH;
    return 0;
}

typedef struct {
    void** samples;
    dds_sample_info_t* infos;
} builtin_buffers_t;

/// Buffers of `slot->batch` entries. Every read or take on the reader passes the
/// full batch as both its buffer size and its sample limit: an older CycloneDDS
/// lends its cached loan by filling one slot per sample of the largest batch
/// requested so far, so a smaller buffer would overflow.
static bool alloc_builtin_buffers(const builtin_reader_t* slot, builtin_buffers_t* out) {
    out->samples = calloc(slot->batch, sizeof(void*));
    out->infos = calloc(slot->batch, sizeof(dds_sample_info_t));
    if (!out->samples || !out->infos) {
        free(out->samples);
        free(out->infos);
        set_error("Failed to allocate the builtin topic read buffers");
        return false;
    }
    return true;
}

static void free_builtin_buffers(builtin_buffers_t* buffers) {
    free(buffers->samples);
    free(buffers->infos);
}

/// Takes and drops every sample of the instances that are no longer alive.
/// Returns 0, or -1 with the error set.
static int32_t take_not_alive(builtin_reader_t* slot) {
    const uint32_t mask = DDS_ANY_SAMPLE_STATE | DDS_ANY_VIEW_STATE
        | DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE | DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE;
    builtin_buffers_t buffers;
    if (!alloc_builtin_buffers(slot, &buffers)) {
        return -1;
    }
    for (;;) {
        buffers.samples[0] = NULL;
        dds_return_t n = dds_take_mask(
            slot->reader, buffers.samples, buffers.infos, slot->batch, (uint32_t)slot->batch, mask);
        if (n < 0) {
            free_builtin_buffers(&buffers);
            set_error("Failed to take the ended instances of a builtin topic: %s", dds_strretcode(n));
            return -1;
        }
        if (n == 0) {
            break;
        }
        dds_return_loan(slot->reader, buffers.samples, n);
        if ((size_t)n < slot->batch) {
            break;
        }
    }
    free_builtin_buffers(&buffers);
    return 0;
}

typedef void (*builtin_sample_visitor_t)(const void* sample, void* arg);

/// Reads every alive instance of a builtin reader with loaned samples and
/// passes each valid sample to `visit`. Returns 0, or -1 with the error set.
static int32_t read_alive(builtin_reader_t* slot, builtin_sample_visitor_t visit, void* arg) {
    const uint32_t mask = DDS_ANY_SAMPLE_STATE | DDS_ANY_VIEW_STATE | DDS_ALIVE_INSTANCE_STATE;
    for (;;) {
        builtin_buffers_t buffers;
        if (!alloc_builtin_buffers(slot, &buffers)) {
            return -1;
        }
        dds_return_t n = dds_read_mask(
            slot->reader, buffers.samples, buffers.infos, slot->batch, (uint32_t)slot->batch, mask);
        if (n < 0) {
            free_builtin_buffers(&buffers);
            set_error("Failed to read a builtin topic: %s", dds_strretcode(n));
            return -1;
        }
        if ((size_t)n == slot->batch) {
            // Possibly more instances than the batch holds: read them all again
            // with a larger one, so that one call returns one consistent list.
            dds_return_loan(slot->reader, buffers.samples, n);
            free_builtin_buffers(&buffers);
            if (slot->batch >= MAX_BUILTIN_BATCH) {
                set_error("A builtin topic has %d or more instances, more than one read lists",
                          MAX_BUILTIN_BATCH);
                return -1;
            }
            slot->batch *= 4;
            continue;
        }
        for (dds_return_t i = 0; i < n; i++) {
            if (buffers.infos[i].valid_data && buffers.samples[i]) {
                visit(buffers.samples[i], arg);
            }
        }
        if (n > 0) {
            dds_return_loan(slot->reader, buffers.samples, n);
        }
        free_builtin_buffers(&buffers);
        return 0;
    }
}

typedef struct {
    dds_bridge_publication_callback_t publication_cb;
    dds_bridge_participant_callback_t participant_cb;
    void* context;
} enumerate_args_t;

static bridge_discovered_reliability_t discovered_reliability(const dds_qos_t* qos) {
    dds_reliability_kind_t kind;
    dds_duration_t max_blocking_time;
    if (!qos || !dds_qget_reliability(qos, &kind, &max_blocking_time)) {
        return BRIDGE_DISCOVERED_RELIABILITY_UNKNOWN;
    }
    return kind == DDS_RELIABILITY_RELIABLE ? BRIDGE_DISCOVERED_RELIABILITY_RELIABLE
                                            : BRIDGE_DISCOVERED_RELIABILITY_BEST_EFFORT;
}

static bridge_discovered_durability_t discovered_durability(const dds_qos_t* qos) {
    dds_durability_kind_t kind;
    if (!qos || !dds_qget_durability(qos, &kind)) {
        return BRIDGE_DISCOVERED_DURABILITY_UNKNOWN;
    }
    switch (kind) {
    case DDS_DURABILITY_VOLATILE: return BRIDGE_DISCOVERED_DURABILITY_VOLATILE;
    case DDS_DURABILITY_TRANSIENT_LOCAL: return BRIDGE_DISCOVERED_DURABILITY_TRANSIENT_LOCAL;
    case DDS_DURABILITY_TRANSIENT: return BRIDGE_DISCOVERED_DURABILITY_TRANSIENT;
    case DDS_DURABILITY_PERSISTENT: return BRIDGE_DISCOVERED_DURABILITY_PERSISTENT;
    }
    return BRIDGE_DISCOVERED_DURABILITY_UNKNOWN;
}

static void visit_publication(const void* sample, void* arg) {
    const dds_builtintopic_endpoint_t* endpoint = sample;
    const enumerate_args_t* args = arg;
    if (!endpoint->topic_name || !endpoint->type_name) {
        return;
    }
    bridge_publication_info_t info = {
        .endpoint_guid = endpoint->key.v,
        .participant_guid = endpoint->participant_key.v,
        .topic_name = endpoint->topic_name,
        .type_name = endpoint->type_name,
        .reliability = discovered_reliability(endpoint->qos),
        .durability = discovered_durability(endpoint->qos),
    };
    args->publication_cb(&info, args->context);
}

static void visit_participant(const void* sample, void* arg) {
    const dds_builtintopic_participant_t* participant = sample;
    const enumerate_args_t* args = arg;
    args->participant_cb(participant->key.v, args->context);
}

int32_t dds_bridge_enumerate_publications(
    bridge_dds_session_t* session,
    dds_bridge_publication_callback_t publication_cb,
    dds_bridge_participant_callback_t participant_cb,
    void* context
) {
    if (!session || !publication_cb) {
        set_error("Invalid parameters for dds_bridge_enumerate_publications");
        return -1;
    }
    if (!session->is_connected || session->participant <= 0) {
        set_error("Session is not connected");
        return -2;
    }
    if (ensure_builtin_reader(
            session, DDS_BUILTIN_TOPIC_DCPSPUBLICATION, &session->publications, "DCPSPublication") != 0) {
        return -3;
    }
    if (participant_cb
        && ensure_builtin_reader(
               session, DDS_BUILTIN_TOPIC_DCPSPARTICIPANT, &session->participants, "DCPSParticipant") != 0) {
        return -3;
    }

    enumerate_args_t args = {
        .publication_cb = publication_cb, .participant_cb = participant_cb, .context = context};

    if (take_not_alive(&session->publications) != 0
        || read_alive(&session->publications, visit_publication, &args) != 0) {
        return -4;
    }
    // Participants after writers: a writer's participant is discovered before
    // the writer, so every participant of a listed writer is listed too.
    if (participant_cb
        && (take_not_alive(&session->participants) != 0
            || read_alive(&session->participants, visit_participant, &args) != 0)) {
        return -4;
    }
    return 0;
}
