//
// signal_mask_scope.h
// Keeps the process's signal masks intact while CycloneDDS starts its threads.
//
// Shared by CDDSBridge (wire DDS) and CRclBridge (RCL, where rmw_cyclonedds_cpp
// starts the CycloneDDS threads). See signal_mask_scope.c for the root cause.
//

#ifndef SWIFT_ROS2_SIGNAL_MASK_SCOPE_H
#define SWIFT_ROS2_SIGNAL_MASK_SCOPE_H

#ifndef _WIN32
  #include <signal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque state of one scope. Windows has no signal masks; the scope is empty there.
typedef struct {
#ifndef _WIN32
    sigset_t saved;
#else
    int unused;
#endif
} swiftros2_signal_mask_scope_t;

/// Call before a function that makes CycloneDDS create a domain (and thereby
/// start its threads). On Apple platforms, off the main thread, this sets the
/// calling thread's mask to the main thread's mask, so that CycloneDDS's
/// process-wide mask restore hands every thread the main thread's mask. The
/// calling thread's own mask is saved in `scope`.
void swiftros2_signal_mask_scope_enter(swiftros2_signal_mask_scope_t* scope);

/// Call after the function returns, on every path, from the same thread as
/// `swiftros2_signal_mask_scope_enter`. Gives the calling thread its own mask back.
void swiftros2_signal_mask_scope_exit(const swiftros2_signal_mask_scope_t* scope);

#ifdef __cplusplus
}
#endif

#endif  // SWIFT_ROS2_SIGNAL_MASK_SCOPE_H
