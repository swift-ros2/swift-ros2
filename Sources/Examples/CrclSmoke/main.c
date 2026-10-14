#include <stdio.h>
#include "rcl_bridge.h"

int main(void) {
    // Smoke exits on first failure; the process teardown reclaims resources,
    // so error paths intentionally skip explicit destroy calls.
    crcl_context_t *ctx = crcl_context_create(0);
    if (!ctx) { printf("context FAIL: %s\n", crcl_last_error()); return 1; }

    crcl_node_t *node = crcl_node_create(ctx, "crcl_smoke", "/swift_ros2");
    if (!node) { printf("node FAIL: %s\n", crcl_last_error()); return 1; }

    crcl_qos_t qos = {.reliability = 1, .durability = 0, .history = 0, .depth = 10};
    crcl_publisher_t *pub = crcl_publisher_create(node, "sensor_msgs/msg/Imu", "/imu", qos);
    if (!pub) { printf("publisher FAIL: %s\n", crcl_last_error()); return 1; }

    uint8_t cdr[8] = {0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0};
    int rc = crcl_publish_serialized(pub, cdr, sizeof(cdr));
    if (rc != 0) { printf("publish FAIL (%d): %s\n", rc, crcl_last_error()); return 1; }

    // The publish path is what this smoke validates, and it has now succeeded.
    // Print + flush the result BEFORE teardown: on a headless CI runner with no
    // working multicast, CycloneDDS participant teardown can block indefinitely
    // on failed discovery writes, and stdout to a pipe is fully buffered, so a
    // teardown hang would otherwise swallow this line. Teardown still runs after
    // (best-effort; the OS reclaims everything on process exit).
    printf("crcl_smoke OK: serialized publish path exercised\n");
    fflush(stdout);

    crcl_publisher_destroy(pub);
    crcl_node_destroy(node);
    crcl_context_destroy(ctx);
    return 0;
}
