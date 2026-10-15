//
// raw_cdr_sertype.c
// Custom sertype/serdata implementation for raw CDR data publishing
//
// This implementation provides minimal sertype/serdata operations
// for publishing pre-serialized CDR data via CycloneDDS.
//

#include "raw_cdr_sertype.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <dds/ddsrt/heap.h>
#include <dds/ddsrt/md5.h>

// CycloneDDS 11 (released 2026-04 in ros-rolling apt) renamed the receive-side
// fragment-chain admin header from <dds/ddsi/q_radmin.h> to
// <dds/ddsi/ddsi_radmin.h> and the type from `struct nn_rdata` to
// `struct ddsi_rdata`. The struct fields (rmsg, nextfrag, min, maxp1) and the
// payload macros (NN_*/DDSI_*) are otherwise identical. Pick the right header
// at compile time so the same source builds against humble/jazzy (0.10.x) and
// rolling (11.x).
#if __has_include(<dds/ddsi/ddsi_radmin.h>)
#  include <dds/ddsi/ddsi_radmin.h>
#  define RAW_CDR_RDATA_T struct ddsi_rdata
#  define RAW_CDR_RMSG_PAYLOADOFF(m, o) DDSI_RMSG_PAYLOADOFF((m), (o))
#  define RAW_CDR_RDATA_PAYLOAD_OFF(r) DDSI_RDATA_PAYLOAD_OFF((r))
#else
#  include <dds/ddsi/q_radmin.h>
#  define RAW_CDR_RDATA_T struct nn_rdata
#  define RAW_CDR_RMSG_PAYLOADOFF(m, o) NN_RMSG_PAYLOADOFF((m), (o))
#  define RAW_CDR_RDATA_PAYLOAD_OFF(r) NN_RDATA_PAYLOAD_OFF((r))
#endif

// =============================================================================
// MARK: - Sertype Operations Implementation
// =============================================================================

/// Free a raw CDR sertype
static void raw_cdr_sertype_free(struct ddsi_sertype *tp)
{
    struct raw_cdr_sertype *st = (struct raw_cdr_sertype *)tp;
    ddsrt_free(st);
}

/// Zero out samples (no-op for raw CDR - we don't have a native sample type)
static void raw_cdr_sertype_zero_samples(const struct ddsi_sertype *d, void *samples, size_t count)
{
    (void)d;
    (void)samples;
    (void)count;
    // No-op: raw CDR doesn't have a native sample type
}

/// Reallocate samples (no-op for raw CDR)
static void raw_cdr_sertype_realloc_samples(
    void **ptrs,
    const struct ddsi_sertype *d,
    void *old,
    size_t oldcount,
    size_t count)
{
    (void)d;
    (void)old;
    (void)oldcount;
    // No-op: raw CDR doesn't support sample allocation
    for (size_t i = 0; i < count; i++) {
        ptrs[i] = NULL;
    }
}

/// Free samples (no-op for raw CDR)
static void raw_cdr_sertype_free_samples(
    const struct ddsi_sertype *d,
    void **ptrs,
    size_t count,
    dds_free_op_t op)
{
    (void)d;
    (void)ptrs;
    (void)count;
    (void)op;
    // No-op: raw CDR doesn't allocate samples
}

/// Check equality of two raw CDR sertypes
static bool raw_cdr_sertype_equal(const struct ddsi_sertype *a, const struct ddsi_sertype *b)
{
    // Raw CDR sertypes are equal if they have the same type name
    // (type name comparison is done by the caller)
    (void)a;
    (void)b;
    return true;
}

/// Hash a raw CDR sertype
static uint32_t raw_cdr_sertype_hash(const struct ddsi_sertype *tp)
{
    (void)tp;
    // Type name is hashed by the base implementation
    return 0;
}

// =============================================================================
// MARK: - Serdata Operations Implementation
// =============================================================================

/// Get the serialized size of serdata (including 4-byte CDR header)
static uint32_t raw_cdr_serdata_get_size(const struct ddsi_serdata *d)
{
    const struct raw_cdr_serdata *rd = (const struct raw_cdr_serdata *)d;
    assert(rd->cdr_size >= 4);
    return (uint32_t)rd->cdr_size;
}

/// Free a raw CDR serdata
static void raw_cdr_serdata_free(struct ddsi_serdata *d)
{
    struct raw_cdr_serdata *rd = (struct raw_cdr_serdata *)d;
    // Note: ddsi_serdata_init does NOT ref the type (just stores pointer),
    // so we should NOT unref here. The type's lifecycle is managed by topic/writer.
    ddsrt_free(rd);
}

/// Create serdata from serialized iovec data (for receiving)
static struct ddsi_serdata *raw_cdr_serdata_from_ser_iov(
    const struct ddsi_sertype *type,
    enum ddsi_serdata_kind kind,
    ddsrt_msg_iovlen_t niov,
    const ddsrt_iovec_t *iov,
    size_t size)
{
    // Calculate total size from iovecs
    size_t total_size = 0;
    for (ddsrt_msg_iovlen_t i = 0; i < niov; i++) {
        total_size += iov[i].iov_len;
    }

    // Allocate serdata with flexible array
    struct raw_cdr_serdata *rd = ddsrt_malloc(sizeof(struct raw_cdr_serdata) + total_size);
    if (!rd) {
        return NULL;
    }

    ddsi_serdata_init(&rd->c, type, kind);
    rd->cdr_size = total_size;

    // Copy data from iovecs
    size_t offset = 0;
    for (ddsrt_msg_iovlen_t i = 0; i < niov; i++) {
        memcpy(rd->cdr_data + offset, iov[i].iov_base, iov[i].iov_len);
        offset += iov[i].iov_len;
    }

    (void)size; // size parameter is the expected size (we computed it from iovecs)

    return &rd->c;
}

/// Create serdata from fragchain (for receiving - used by DDSI)
static struct ddsi_serdata *raw_cdr_serdata_from_ser(
    const struct ddsi_sertype *type,
    enum ddsi_serdata_kind kind,
    const RAW_CDR_RDATA_T *fragchain,
    size_t size)
{
    // Must have at least the 4-byte XCDR encapsulation header.
    if (size < 4) {
        return NULL;
    }

    // Allocate serdata with flexible array + 3 bytes trailing padding.
    // The +3 mirrors raw_cdr_serdata_new: CycloneDDS's align4u(cdr_size)
    // may read up to 3 bytes past the end when slicing fragments via
    // to_ser_ref on the transmit side. Keeping the layout identical
    // between transmit- and receive-constructed serdatas avoids surprises
    // if the received sample is ever re-published.
    struct raw_cdr_serdata *rd = ddsrt_malloc(sizeof(struct raw_cdr_serdata) + size + 3);
    if (!rd) {
        return NULL;
    }

    ddsi_serdata_init(&rd->c, type, kind);
    // For keyless types, all serdatas share the sertype's basehash.
    rd->c.hash = type->serdata_basehash;
    rd->cdr_size = size;

    // Walk the fragment chain, copying each fragment's new region into
    // rd->cdr_data. Mirrors the canonical walk in CycloneDDS's
    // serdata_default_from_ser_common but starts at off=0 so the 4-byte
    // encapsulation header is preserved verbatim in rd->cdr_data.
    size_t off = 0;
    while (fragchain) {
        assert(fragchain->min <= off);
        assert(fragchain->maxp1 <= size);
        if (fragchain->maxp1 > off) {
            const unsigned char *payload =
                RAW_CDR_RMSG_PAYLOADOFF(fragchain->rmsg, RAW_CDR_RDATA_PAYLOAD_OFF(fragchain));
            memcpy(rd->cdr_data + off, payload + off - fragchain->min, fragchain->maxp1 - off);
            off = fragchain->maxp1;
        }
        fragchain = fragchain->nextfrag;
    }

    // Zero the trailing 3 bytes of padding so an align4u overread returns
    // well-defined zero bytes (matches raw_cdr_serdata_new).
    memset(rd->cdr_data + size, 0, 3);

    return &rd->c;
}

/// Create serdata from keyhash (for tkmap lookups)
static struct ddsi_serdata *raw_cdr_serdata_from_keyhash(
    const struct ddsi_sertype *type,
    const struct ddsi_keyhash *keyhash)
{
    (void)keyhash;  // Ignore keyhash for keyless types

    // Create a minimal serdata for keyhash lookup
    size_t alloc_size = sizeof(struct raw_cdr_serdata) + 4;
    struct raw_cdr_serdata *rd = ddsrt_malloc(alloc_size);
    if (!rd) {
        return NULL;
    }

    ddsi_serdata_init(&rd->c, type, SDK_KEY);
    // For keyless types, use the sertype's basehash
    rd->c.hash = type->serdata_basehash;
    rd->cdr_size = 4;
    rd->cdr_data[0] = 0x00;
    rd->cdr_data[1] = 0x01;
    rd->cdr_data[2] = 0x00;
    rd->cdr_data[3] = 0x00;

    return &rd->c;
}

/// Create serdata from application sample (not supported for raw CDR)
static struct ddsi_serdata *raw_cdr_serdata_from_sample(
    const struct ddsi_sertype *type,
    enum ddsi_serdata_kind kind,
    const void *sample)
{
    (void)type;
    (void)kind;
    (void)sample;
    // Not supported: use raw_cdr_serdata_new instead
    return NULL;
}

/// Convert serdata to untyped serdata (for key-based operations)
static struct ddsi_serdata *raw_cdr_serdata_to_untyped(const struct ddsi_serdata *d)
{
    // For keyless types, create a minimal "keyhash-only" serdata.
    // This is stored in the tkmap and must be a separate allocation.
    // Use SDK_KEY kind for the untyped representation.
    size_t alloc_size = sizeof(struct raw_cdr_serdata) + 4; // Minimal CDR header only
    struct raw_cdr_serdata *rd = ddsrt_malloc(alloc_size);
    if (!rd) {
        return NULL;
    }

    // Initialize as SDK_KEY (untyped/keyhash-only representation)
    ddsi_serdata_init(&rd->c, d->type, SDK_KEY);

    // For keyless types, all serdatas share the same hash
    rd->c.hash = d->type->serdata_basehash;
    rd->c.timestamp = d->timestamp;
    rd->c.statusinfo = d->statusinfo;

    rd->cdr_size = 4;
    // Minimal CDR header for keyhash
    rd->cdr_data[0] = 0x00;
    rd->cdr_data[1] = 0x01;
    rd->cdr_data[2] = 0x00;
    rd->cdr_data[3] = 0x00;

    return &rd->c;
}

/// Copy serialized data to buffer
static void raw_cdr_serdata_to_ser(
    const struct ddsi_serdata *d,
    size_t off,
    size_t sz,
    void *buf)
{
    const struct raw_cdr_serdata *rd = (const struct raw_cdr_serdata *)d;
    if (off >= rd->cdr_size) {
        memset(buf, 0, sz);
        return;
    }
    // Copy available data and zero-fill any remainder (for aligned reads
    // that extend beyond the actual CDR data)
    size_t avail = rd->cdr_size - off;
    if (avail >= sz) {
        memcpy(buf, rd->cdr_data + off, sz);
    } else {
        memcpy(buf, rd->cdr_data + off, avail);
        memset((uint8_t *)buf + avail, 0, sz - avail);
    }
}

/// Get reference to serialized data
static struct ddsi_serdata *raw_cdr_serdata_to_ser_ref(
    const struct ddsi_serdata *d,
    size_t off,
    size_t sz,
    ddsrt_iovec_t *ref)
{
    const struct raw_cdr_serdata *rd = (const struct raw_cdr_serdata *)d;
    if (off >= rd->cdr_size) {
        ref->iov_base = (void *)(rd->cdr_data);
        ref->iov_len = 0;
        return ddsi_serdata_ref(d);
    }
    // CycloneDDS requests 4-byte aligned sizes (align4u) for fragment payloads.
    // The last fragment's aligned size may exceed cdr_size by up to 3 bytes.
    // The buffer is allocated with extra padding to handle this safely.
    ref->iov_base = (void *)(rd->cdr_data + off);
    ref->iov_len = (ddsrt_iov_len_t)sz;
    return ddsi_serdata_ref(d);
}

/// Release reference to serialized data
static void raw_cdr_serdata_to_ser_unref(struct ddsi_serdata *d, const ddsrt_iovec_t *ref)
{
    (void)ref;
    ddsi_serdata_unref(d);
}

/// Convert serdata to application sample (not supported)
static bool raw_cdr_serdata_to_sample(
    const struct ddsi_serdata *d,
    void *sample,
    void **bufptr,
    void *buflim)
{
    (void)d;
    (void)sample;
    (void)bufptr;
    (void)buflim;
    // Not supported: raw CDR doesn't have a native sample type
    return false;
}

/// Convert untyped serdata to sample (not supported)
static bool raw_cdr_serdata_untyped_to_sample(
    const struct ddsi_sertype *type,
    const struct ddsi_serdata *d,
    void *sample,
    void **bufptr,
    void *buflim)
{
    (void)type;
    (void)d;
    (void)sample;
    (void)bufptr;
    (void)buflim;
    // Not supported: raw CDR doesn't have a native sample type
    return false;
}

/// Check if two serdatas have equal keys (always TRUE for keyless types)
static bool raw_cdr_serdata_eqkey(const struct ddsi_serdata *a, const struct ddsi_serdata *b)
{
    (void)a;
    (void)b;
    // Keyless type: all instances are considered the same (there's only one instance)
    return true;
}

/// Print serdata (for debugging)
static size_t raw_cdr_serdata_print(
    const struct ddsi_sertype *type,
    const struct ddsi_serdata *d,
    char *buf,
    size_t size)
{
    const struct raw_cdr_serdata *rd = (const struct raw_cdr_serdata *)d;
    int n = snprintf(buf, size, "[raw CDR %zu bytes, type=%s]",
                     rd->cdr_size, type->type_name);
    return (size_t)(n < 0 ? 0 : (size_t)n);
}

/// Get keyhash (return empty hash for keyless types)
static void raw_cdr_serdata_get_keyhash(
    const struct ddsi_serdata *d,
    struct ddsi_keyhash *buf,
    bool force_md5)
{
    (void)d;
    (void)force_md5;
    // Return zero keyhash for keyless types
    memset(buf->value, 0, sizeof(buf->value));
}

// =============================================================================
// MARK: - Operations Tables
// =============================================================================

const struct ddsi_sertype_ops raw_cdr_sertype_ops = {
    .version = ddsi_sertype_v0,
    .arg = NULL,
    .free = raw_cdr_sertype_free,
    .zero_samples = raw_cdr_sertype_zero_samples,
    .realloc_samples = raw_cdr_sertype_realloc_samples,
    .free_samples = raw_cdr_sertype_free_samples,
    .equal = raw_cdr_sertype_equal,
    .hash = raw_cdr_sertype_hash,
    .type_id = NULL,           // No XTypes support
    .type_map = NULL,          // No XTypes support
    .type_info = NULL,         // No XTypes support
    .derive_sertype = NULL,    // No derived sertypes
    .get_serialized_size = NULL,
    .serialize_into = NULL
};

const struct ddsi_serdata_ops raw_cdr_serdata_ops = {
    .eqkey = raw_cdr_serdata_eqkey,
    .get_size = raw_cdr_serdata_get_size,
    .from_ser = raw_cdr_serdata_from_ser,
    .from_ser_iov = raw_cdr_serdata_from_ser_iov,
    .from_keyhash = raw_cdr_serdata_from_keyhash,
    .from_sample = raw_cdr_serdata_from_sample,
    .to_ser = raw_cdr_serdata_to_ser,
    .to_ser_ref = raw_cdr_serdata_to_ser_ref,
    .to_ser_unref = raw_cdr_serdata_to_ser_unref,
    .to_sample = raw_cdr_serdata_to_sample,
    .to_untyped = raw_cdr_serdata_to_untyped,
    .untyped_to_sample = raw_cdr_serdata_untyped_to_sample,
    .free = raw_cdr_serdata_free,
    .print = raw_cdr_serdata_print,
    .get_keyhash = raw_cdr_serdata_get_keyhash
};

// =============================================================================
// MARK: - Factory Functions Implementation
// =============================================================================

struct ddsi_sertype *raw_cdr_sertype_new(const char *type_name)
{
    if (!type_name || strlen(type_name) == 0) {
        return NULL;
    }

    struct raw_cdr_sertype *st = ddsrt_malloc(sizeof(struct raw_cdr_sertype));
    if (!st) {
        return NULL;
    }

    if (!raw_cdr_sertype_init(st, type_name)) {
        ddsrt_free(st);
        return NULL;
    }

    return &st->c;
}

bool raw_cdr_sertype_init(struct raw_cdr_sertype *st, const char *type_name)
{
    if (!st || !type_name) {
        return false;
    }

    // Initialize with TOPICKIND_NO_KEY flag (keyless type)
    ddsi_sertype_init_flags(
        &st->c,
        type_name,
        &raw_cdr_sertype_ops,
        &raw_cdr_serdata_ops,
        DDSI_SERTYPE_FLAG_TOPICKIND_NO_KEY
    );

    return true;
}

void raw_cdr_sertype_fini(struct raw_cdr_sertype *st)
{
    if (st) {
        ddsi_sertype_fini(&st->c);
    }
}

struct ddsi_serdata *raw_cdr_serdata_new(
    const struct ddsi_sertype *type,
    const uint8_t *cdr_data,
    size_t cdr_len,
    dds_time_t timestamp)
{
    if (!type || !cdr_data || cdr_len < 4) {
        return NULL;
    }

    // Allocate serdata with space for CDR data + 3 bytes padding.
    // CycloneDDS requests 4-byte aligned fragment sizes (align4u) when
    // reading fragment payloads via to_ser_ref. The last fragment's aligned
    // size may exceed cdr_len by up to 3 bytes. The extra padding ensures
    // the aligned read is safe and returns zeros for the padding bytes.
    size_t alloc_size = sizeof(struct raw_cdr_serdata) + cdr_len + 3;
    struct raw_cdr_serdata *rd = ddsrt_malloc(alloc_size);
    if (!rd) {
        return NULL;
    }

    // Initialize base serdata
    ddsi_serdata_init(&rd->c, type, SDK_DATA);

    // For keyless types, all serdatas should have the same hash (the sertype's basehash)
    rd->c.hash = type->serdata_basehash;

    // Set timestamp
    rd->c.timestamp.v = timestamp;
    rd->c.statusinfo = 0;

    // Copy CDR data and zero the padding bytes
    rd->cdr_size = cdr_len;
    memcpy(rd->cdr_data, cdr_data, cdr_len);
    memset(rd->cdr_data + cdr_len, 0, 3);

    return &rd->c;
}

