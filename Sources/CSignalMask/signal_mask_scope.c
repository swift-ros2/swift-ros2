//
// signal_mask_scope.c
// Signal mask preservation around CycloneDDS domain creation.
//

#include "signal_mask_scope.h"

#ifndef _WIN32
  #include <pthread.h>
  #include <signal.h>
#endif

// CycloneDDS's ddsrt_thread_create blocks every signal with sigprocmask()
// around pthread_create() and then restores the mask it saved, so that its
// threads start with signals blocked. On Linux sigprocmask() changes only the
// calling thread. On Apple platforms it changes the mask of every thread in
// the process, so the restore gives every thread the mask of the thread that
// created the domain. ROS2Context opens its DDS transports on a Swift
// concurrency (Dispatch worker) thread, which has SIGINT, SIGTERM and the
// other asynchronous signals blocked, so the main thread was left with them
// blocked and Ctrl-C or kill no longer stopped the process (#290).
//
// The bridge entry points that make CycloneDDS create a domain (wire DDS:
// dds_bridge_create_session; RCL: crcl_context_create and crcl_node_create,
// where rmw_cyclonedds_cpp creates the domain on the first node) therefore run
// with the calling thread's mask set to the main thread's mask (as captured
// when this library was loaded), which is what CycloneDDS then restores on
// every thread. The result is the same as doing the work on the main thread.
// On every POSIX platform the calling thread gets its own mask back before the
// function returns, also when ddsrt_thread_create fails with every signal
// blocked.

#ifdef __APPLE__
static sigset_t g_main_thread_signal_mask;

__attribute__((constructor))
static void capture_main_thread_signal_mask(void) {
    if (!pthread_main_np() || pthread_sigmask(SIG_BLOCK, NULL, &g_main_thread_signal_mask) != 0) {
        sigemptyset(&g_main_thread_signal_mask);
    }
}
#endif

void swiftros2_signal_mask_scope_enter(swiftros2_signal_mask_scope_t* scope) {
#if defined(__APPLE__)
    if (!pthread_main_np()) {
        pthread_sigmask(SIG_SETMASK, &g_main_thread_signal_mask, &scope->saved);
        return;
    }
#endif
#ifndef _WIN32
    pthread_sigmask(SIG_BLOCK, NULL, &scope->saved);
#else
    (void)scope;
#endif
}

void swiftros2_signal_mask_scope_exit(const swiftros2_signal_mask_scope_t* scope) {
#ifndef _WIN32
    pthread_sigmask(SIG_SETMASK, &scope->saved, NULL);
#else
    (void)scope;
#endif
}
