/*
 * spine-converter, unofficial converter for Spine skeleton data
 * Spine is a trademark of Esoteric Software
 * Users must hold their own Spine Editor license, see LICENSE
 *
 * All functions are thread-safe
 * Input buffers are only read during the call
 * Strings are UTF-8 and NUL-terminated
 */
#ifndef SPINE_CONVERTER_H
#define SPINE_CONVERTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(SPC_SHARED)
#    ifdef SPC_BUILDING
#        define SPC_API __declspec(dllexport)
#    else
#        define SPC_API __declspec(dllimport)
#    endif
#else
#    define SPC_API
#endif

/** Bumped on incompatible ABI changes */
#define SPC_ABI_VERSION 1

typedef enum spc_status {
    SPC_OK = 0,
    SPC_ERR_INVALID_ARGUMENT = 1,
    /** Not Spine skeleton data */
    SPC_ERR_UNKNOWN_FORMAT = 2,
    /** Source or target version not supported */
    SPC_ERR_UNSUPPORTED_VERSION = 3,
    /** Known version but corrupt or truncated */
    SPC_ERR_MALFORMED = 4,
    SPC_ERR_OUT_OF_MEMORY = 5,
    /** Data loss with SPC_FLAG_FAIL_ON_LOSS set */
    SPC_ERR_LOSSY_REJECTED = 6
} spc_status;

typedef enum spc_format {
    SPC_FORMAT_UNKNOWN = 0,
    SPC_FORMAT_JSON = 1,
    SPC_FORMAT_BINARY = 2,
    /** Texture atlas text, detected without a version */
    SPC_FORMAT_ATLAS = 3
} spc_format;

/** Ordered from least to most severe, see docs/report.md */
typedef enum spc_impact {
    SPC_IMPACT_NONE = 0,
    SPC_IMPACT_EDITOR = 1,
    SPC_IMPACT_CONTROL = 2,
    SPC_IMPACT_POSE = 3,
    SPC_IMPACT_RENDER = 4
} spc_impact;

/** How a loss can be avoided, see docs/report.md */
typedef enum spc_remedy {
    SPC_REMEDY_NONE = 0,
    /** Exact without SPC_FLAG_NO_REWRITE */
    SPC_REMEDY_REWRITE = 1,
    /** No target data reproduces it */
    SPC_REMEDY_RUNTIME = 2
} spc_remedy;

typedef struct spc_detect_result {
    spc_format format;
    /** Version text as written, empty when absent */
    char version[32];
    /** 0 when absent */
    uint16_t major;
    uint16_t minor;
    uint16_t patch;
} spc_detect_result;

/** NULL in spc_convert uses the internal allocator */
typedef struct spc_allocator {
    void *ctx;
    /** Returns NULL on failure, align is a power of two */
    void *(*alloc)(void *ctx, size_t size, size_t align);
    void (*free)(void *ctx, void *ptr, size_t size, size_t align);
} spc_allocator;

/* Unknown bits fail with SPC_ERR_INVALID_ARGUMENT */
/** Any loss fails with SPC_ERR_LOSSY_REJECTED */
#define SPC_FLAG_FAIL_ON_LOSS (1u << 0)
#define SPC_FLAG_PRETTY_JSON (1u << 1)
/** Keeps the source structure where a rewrite would pose exactly, see docs/report.md */
#define SPC_FLAG_NO_REWRITE (1u << 2)

typedef struct spc_options {
    /** Must be sizeof(spc_options) */
    uint32_t struct_size;
    /** Such as "4.3" or "3.8.99", NULL keeps the source version */
    const char *target_version;
    /** SPC_FORMAT_UNKNOWN keeps the source format, atlases only convert to atlases */
    spc_format target_format;
    /** SPC_FLAG_ bits */
    uint32_t flags;
    /** Atlas text of a 3.5 or 3.6 skeleton, keeps mesh UVs of stripped regions, NULL when absent */
    const uint8_t *atlas;
    size_t atlas_length;
} spc_options;

/** Owns all memory returned for one conversion */
typedef struct spc_result spc_result;

SPC_API uint32_t spc_abi_version(void);
/** Static string */
SPC_API const char *spc_library_version(void);
/** Static string */
SPC_API const char *spc_status_string(spc_status status);

/** Does not allocate */
SPC_API spc_status spc_detect(const uint8_t *data, size_t length, spc_detect_result *out);

/**
 * options NULL keeps version and format
 * out is set on failure too when allocation succeeded
 * Free out with spc_result_free
 */
SPC_API spc_status spc_convert(
    const uint8_t *data,
    size_t length,
    const spc_options *options,
    const spc_allocator *allocator,
    spc_result **out
);

SPC_API spc_status spc_result_status(const spc_result *result);
/** NULL on failure, valid until spc_result_free */
SPC_API const uint8_t *spc_result_data(const spc_result *result, size_t *length);
/** JSON array, see docs/report.md, accepts NULL */
SPC_API const char *spc_result_report(const spc_result *result, size_t *length);
/** Report entries that are not rewritten, accepts NULL */
SPC_API size_t spc_result_loss_count(const spc_result *result);
/** Most severe impact in the report, accepts NULL */
SPC_API spc_impact spc_result_max_impact(const spc_result *result);
/** Report entries with this remedy, accepts NULL and unknown values */
SPC_API size_t spc_result_remedy_count(const spc_result *result, spc_remedy remedy);
/** Empty on success */
SPC_API const char *spc_result_error(const spc_result *result);
/** Accepts NULL */
SPC_API void spc_result_free(spc_result *result);

#ifdef __cplusplus
}
#endif

#endif
