#include <spine_converter.h>
#include <stdio.h>
#include <string.h>

#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); \
            return 1;                                                  \
        }                                                              \
    } while (0)

static const char *json = "{\"skeleton\":{\"spine\":\"3.8.99\",\"hash\":\"\"},\"bones\":[]}";

static int detect(void) {
    spc_detect_result detected;
    CHECK(spc_detect((const uint8_t *)json, strlen(json), &detected) == SPC_OK);
    CHECK(detected.format == SPC_FORMAT_JSON);
    CHECK(strcmp(detected.version, "3.8.99") == 0);
    CHECK(detected.major == 3 && detected.minor == 8 && detected.patch == 99);
    CHECK(spc_detect((const uint8_t *)"PNG", 3, &detected) == SPC_ERR_UNKNOWN_FORMAT);
    CHECK(spc_detect(NULL, 0, NULL) == SPC_ERR_INVALID_ARGUMENT);
    return 0;
}

static int loss(void) {
    static const char *physics =
        "{\"skeleton\":{\"spine\":\"4.2.43\",\"referenceScale\":50},"
        "\"bones\":[{\"name\":\"root\"}],\"physics\":[{\"name\":\"p\",\"bone\":\"root\"}]}";
    spc_options options = {.struct_size = sizeof(spc_options), .target_version = "4.1"};
    spc_result *result = NULL;
    CHECK(spc_convert((const uint8_t *)physics, strlen(physics), &options, NULL, &result) == SPC_OK);
    CHECK(spc_result_loss_count(result) == 2);
    CHECK(spc_result_max_impact(result) == SPC_IMPACT_POSE);
    CHECK(spc_result_remedy_count(result, SPC_REMEDY_NONE) == 2);
    CHECK(spc_result_remedy_count(result, SPC_REMEDY_REWRITE) == 0);
    CHECK(spc_result_remedy_count(result, (spc_remedy)7) == 0);
    spc_result_free(result);

    options.flags = SPC_FLAG_FAIL_ON_LOSS;
    CHECK(
        spc_convert((const uint8_t *)physics, strlen(physics), &options, NULL, &result)
        == SPC_ERR_LOSSY_REJECTED
    );
    CHECK(spc_result_loss_count(result) == 2);
    CHECK(spc_result_data(result, NULL) == NULL);
    spc_result_free(result);
    CHECK(spc_result_loss_count(NULL) == 0);
    CHECK(spc_result_max_impact(NULL) == SPC_IMPACT_NONE);
    CHECK(spc_result_remedy_count(NULL, SPC_REMEDY_NONE) == 0);
    return 0;
}

static int convert(void) {
    spc_result *result = NULL;
    CHECK(spc_convert((const uint8_t *)json, strlen(json), NULL, NULL, &result) == SPC_OK);
    size_t length = 0;
    const uint8_t *data = spc_result_data(result, &length);
    CHECK(length == strlen(json) && memcmp(data, json, length) == 0);
    CHECK(strcmp(spc_result_report(result, NULL), "[]") == 0);
    CHECK(strcmp(spc_result_error(result), "") == 0);
    CHECK(spc_result_loss_count(result) == 0);
    CHECK(spc_result_max_impact(result) == SPC_IMPACT_NONE);
    spc_result_free(result);

    spc_options options = {.struct_size = sizeof(spc_options), .target_version = "3.4"};
    spc_status status = spc_convert((const uint8_t *)json, strlen(json), &options, NULL, &result);
    CHECK(status == SPC_ERR_UNSUPPORTED_VERSION);
    CHECK(spc_result_status(result) == SPC_ERR_UNSUPPORTED_VERSION);
    CHECK(spc_result_data(result, &length) == NULL && length == 0);
    CHECK(strlen(spc_result_error(result)) > 0);
    spc_result_free(result);

    options.target_version = "not a version";
    status = spc_convert((const uint8_t *)json, strlen(json), &options, NULL, &result);
    CHECK(status == SPC_ERR_INVALID_ARGUMENT);
    CHECK(result == NULL);
    spc_result_free(NULL);
    return 0;
}

static int rewrite(void) {
    static const char *mix =
        "{\"skeleton\":{\"spine\":\"3.8.99\"},\"bones\":[{\"name\":\"root\"},{\"name\":\"b\",\"parent\":\"root\"}],"
        "\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\",\"scaleMix\":-1}]}";
    spc_options options = {.struct_size = sizeof(spc_options), .target_version = "4.3"};
    spc_result *result = NULL;
    CHECK(spc_convert((const uint8_t *)mix, strlen(mix), &options, NULL, &result) == SPC_OK);
    CHECK(spc_result_loss_count(result) == 0);
    CHECK(strstr(spc_result_report(result, NULL), "transform.scaleMix.rewritten") != NULL);
    spc_result_free(result);

    options.flags = SPC_FLAG_NO_REWRITE;
    CHECK(spc_convert((const uint8_t *)mix, strlen(mix), &options, NULL, &result) == SPC_OK);
    CHECK(spc_result_loss_count(result) == 1);
    CHECK(spc_result_remedy_count(result, SPC_REMEDY_REWRITE) == 1);
    spc_result_free(result);

    options.flags = 1u << 3;
    CHECK(
        spc_convert((const uint8_t *)mix, strlen(mix), &options, NULL, &result)
        == SPC_ERR_INVALID_ARGUMENT
    );
    spc_result_free(result);
    return 0;
}

static int atlas(void) {
    static const char *page = "a.png\n\tsize: 2, 2\n\tpma: true\nr\n\tbounds: 0, 0, 1, 1\n";
    spc_detect_result detected;
    CHECK(spc_detect((const uint8_t *)page, strlen(page), &detected) == SPC_OK);
    CHECK(detected.format == SPC_FORMAT_ATLAS && detected.major == 0);
    spc_options options = {.struct_size = sizeof(spc_options), .target_version = "3.8"};
    spc_result *result = NULL;
    CHECK(spc_convert((const uint8_t *)page, strlen(page), &options, NULL, &result) == SPC_OK);
    CHECK(spc_result_loss_count(result) == 1);
    CHECK(spc_result_max_impact(result) == SPC_IMPACT_RENDER);
    size_t length = 0;
    const uint8_t *data = spc_result_data(result, &length);
    static const char *legacy = "a.png\nsize: 2,2\nformat: RGBA8888\n";
    CHECK(length > strlen(legacy) && memcmp(data, legacy, strlen(legacy)) == 0);
    spc_result_free(result);

    options.target_format = SPC_FORMAT_JSON;
    CHECK(
        spc_convert((const uint8_t *)page, strlen(page), &options, NULL, &result)
        == SPC_ERR_INVALID_ARGUMENT
    );
    spc_result_free(result);

    options.target_format = (spc_format)7;
    CHECK(
        spc_convert((const uint8_t *)page, strlen(page), &options, NULL, &result)
        == SPC_ERR_INVALID_ARGUMENT
    );
    CHECK(result == NULL);
    return 0;
}

/** Output data is not NUL-terminated */
static int output_contains(const spc_result *result, const char *needle) {
    size_t length = 0, n = strlen(needle);
    const uint8_t *data = spc_result_data(result, &length);
    for (size_t i = 0; i + n <= length; i++)
        if (memcmp(data + i, needle, n) == 0) return 1;
    return 0;
}

static int skeleton_atlas(void) {
    static const char *page =
        "\na.png\nsize: 64,64\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\n"
        "r\n  rotate: false\n  xy: 2, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n";
    static const char *skeleton =
        "{\"skeleton\":{\"spine\":\"3.6.53\"},\"bones\":[{\"name\":\"root\"}],"
        "\"slots\":[{\"name\":\"s\",\"bone\":\"root\"}],\"skins\":{\"default\":{\"s\":{\"r\":{"
        "\"type\":\"mesh\",\"uvs\":[0,0,1,0,1,1,0.25,0.7],\"triangles\":[0,1,2,0,2,3],"
        "\"vertices\":[0,0,10,0,10,10,0,10],\"hull\":4}}}}}";
    spc_options options = {.struct_size = sizeof(spc_options), .target_version = "3.7"};
    spc_result *result = NULL;
    CHECK(spc_convert((const uint8_t *)skeleton, strlen(skeleton), &options, NULL, &result) == SPC_OK);
    CHECK(spc_result_loss_count(result) == 1);
    spc_result_free(result);

    options.atlas = (const uint8_t *)page;
    options.atlas_length = strlen(page);
    CHECK(spc_convert((const uint8_t *)skeleton, strlen(skeleton), &options, NULL, &result) == SPC_OK);
    CHECK(spc_result_loss_count(result) == 0);
    CHECK(output_contains(result, "0.15625,0.175"));
    spc_result_free(result);

    options.atlas = NULL;
    CHECK(
        spc_convert((const uint8_t *)skeleton, strlen(skeleton), &options, NULL, &result)
        == SPC_ERR_INVALID_ARGUMENT
    );
    CHECK(result == NULL);
    return 0;
}

int main(void) {
    CHECK(spc_abi_version() == SPC_ABI_VERSION);
    CHECK(strcmp(spc_status_string(SPC_ERR_UNKNOWN_FORMAT), "not Spine skeleton data") == 0);
    return detect() || convert() || loss() || rewrite() || atlas() || skeleton_atlas();
}
