//
// rcl_graph.c
// The publishers of the ROS graph as rcl sees them, for ROS2Context.topicGraph().
//

#include "rcl_bridge.h"

#include <rcl/error_handling.h>
#include <rcl/graph.h>
#include <rcutils/allocator.h>
#include <rmw/names_and_types.h>
#include <rmw/topic_endpoint_info_array.h>
#include <rmw/types.h>

#include "crcl_internal.h"
#include "signal_mask_scope.h"

#include <stdbool.h>
#include <stddef.h>

// The CRCL_RMW_* values in rcl_bridge.h are what Swift compares the reported
// QoS against. They must stay rmw's own enum values.
_Static_assert(
    CRCL_RMW_RELIABILITY_SYSTEM_DEFAULT == RMW_QOS_POLICY_RELIABILITY_SYSTEM_DEFAULT,
    "CRCL_RMW_RELIABILITY_SYSTEM_DEFAULT drifted from rmw");
_Static_assert(
    CRCL_RMW_RELIABILITY_RELIABLE == RMW_QOS_POLICY_RELIABILITY_RELIABLE,
    "CRCL_RMW_RELIABILITY_RELIABLE drifted from rmw");
_Static_assert(
    CRCL_RMW_RELIABILITY_BEST_EFFORT == RMW_QOS_POLICY_RELIABILITY_BEST_EFFORT,
    "CRCL_RMW_RELIABILITY_BEST_EFFORT drifted from rmw");
_Static_assert(
    CRCL_RMW_RELIABILITY_UNKNOWN == RMW_QOS_POLICY_RELIABILITY_UNKNOWN,
    "CRCL_RMW_RELIABILITY_UNKNOWN drifted from rmw");
_Static_assert(
    CRCL_RMW_RELIABILITY_BEST_AVAILABLE == RMW_QOS_POLICY_RELIABILITY_BEST_AVAILABLE,
    "CRCL_RMW_RELIABILITY_BEST_AVAILABLE drifted from rmw");
_Static_assert(
    CRCL_RMW_DURABILITY_SYSTEM_DEFAULT == RMW_QOS_POLICY_DURABILITY_SYSTEM_DEFAULT,
    "CRCL_RMW_DURABILITY_SYSTEM_DEFAULT drifted from rmw");
_Static_assert(
    CRCL_RMW_DURABILITY_TRANSIENT_LOCAL == RMW_QOS_POLICY_DURABILITY_TRANSIENT_LOCAL,
    "CRCL_RMW_DURABILITY_TRANSIENT_LOCAL drifted from rmw");
_Static_assert(
    CRCL_RMW_DURABILITY_VOLATILE == RMW_QOS_POLICY_DURABILITY_VOLATILE,
    "CRCL_RMW_DURABILITY_VOLATILE drifted from rmw");
_Static_assert(
    CRCL_RMW_DURABILITY_UNKNOWN == RMW_QOS_POLICY_DURABILITY_UNKNOWN,
    "CRCL_RMW_DURABILITY_UNKNOWN drifted from rmw");
_Static_assert(
    CRCL_RMW_DURABILITY_BEST_AVAILABLE == RMW_QOS_POLICY_DURABILITY_BEST_AVAILABLE,
    "CRCL_RMW_DURABILITY_BEST_AVAILABLE drifted from rmw");

static const char *or_empty(const char *s) { return s ? s : ""; }

static int graph_snapshot(crcl_node_t *n, crcl_graph_publisher_callback_t cb, void *ctx) {
    rcl_allocator_t alloc = rcl_get_default_allocator();
    rcl_names_and_types_t topics = rcl_get_zero_initialized_names_and_types();
    // no_demangle == false: rmw strips the DDS `rt/` prefix, turns DDS type
    // names into ROS ones and leaves out the service request / reply topics.
    rcl_ret_t ret = rcl_get_topic_names_and_types(&n->node, &alloc, false, &topics);
    if (ret != RCL_RET_OK) {
        crcl__capture_rcl_error();
        // Keep the captured message: a failing fini must not leave a second
        // error behind for the next capture.
        if (rcl_names_and_types_fini(&topics) != RCL_RET_OK) rcl_reset_error();
        return (int)ret;
    }
    int result = 0;
    for (size_t i = 0; i < topics.names.size; ++i) {
        const char *topic = topics.names.data[i];
        if (!topic) continue;
        rcl_topic_endpoint_info_array_t pubs = rcl_get_zero_initialized_topic_endpoint_info_array();
        // no_mangle == false: `topic` is a ROS name, rmw mangles it itself.
        ret = rcl_get_publishers_info_by_topic(&n->node, &alloc, topic, false, &pubs);
        if (ret != RCL_RET_OK) {
            crcl__capture_rcl_error();
            if (rcl_topic_endpoint_info_array_fini(&pubs, &alloc) != RMW_RET_OK) rcl_reset_error();
            result = (int)ret;
            break;
        }
        // A name with no publisher (subscribers only) yields no callback. Each
        // endpoint carries its own type, so a name published with two types
        // reports both.
        for (size_t j = 0; j < pubs.size; ++j) {
            const rmw_topic_endpoint_info_t *e = &pubs.info_array[j];
            cb(ctx, topic, or_empty(e->topic_type), (int)e->qos_profile.reliability,
               (int)e->qos_profile.durability, or_empty(e->node_name), or_empty(e->node_namespace));
        }
        if (rcl_topic_endpoint_info_array_fini(&pubs, &alloc) != RMW_RET_OK) rcl_reset_error();
    }
    if (rcl_names_and_types_fini(&topics) != RCL_RET_OK) rcl_reset_error();
    return result;
}

// The graph calls only read rmw's local graph cache. They run in the signal
// mask scope anyway, like crcl_context_create, so that a CycloneDDS thread
// started on this path cannot change the process's signal masks (#290, see
// Sources/CSignalMask/signal_mask_scope.c).
int crcl_graph_snapshot(crcl_node_t *n, crcl_graph_publisher_callback_t cb, void *ctx) {
    if (!n || !cb) {
        crcl__set_error("crcl_graph_snapshot: NULL node or callback");
        return -1;
    }
    swiftros2_signal_mask_scope_t scope;
    swiftros2_signal_mask_scope_enter(&scope);
    int ret = graph_snapshot(n, cb, ctx);
    swiftros2_signal_mask_scope_exit(&scope);
    return ret;
}
