#include <spine_converter.hpp>

#include <cstdio>
#include <cstring>
#include <string>

#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); \
            return 1;                                                  \
        }                                                              \
    } while (0)

namespace sc = spine_converter;

static const std::string json = R"({"skeleton":{"spine":"3.8.99","hash":""},"bones":[]})";
static const std::string physics =
    R"({"skeleton":{"spine":"4.2.43","referenceScale":50},)"
    R"("bones":[{"name":"root"}],"physics":[{"name":"p","bone":"root"}]})";

static const std::string page =
    "\na.png\nsize: 64,64\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\n"
    "r\n  rotate: false\n  xy: 2, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n";
static const std::string stripped =
    R"({"skeleton":{"spine":"3.6.53"},"bones":[{"name":"root"}],)"
    R"("slots":[{"name":"s","bone":"root"}],"skins":{"default":{"s":{"r":{)"
    R"("type":"mesh","uvs":[0,0,1,0,1,1,0.25,0.7],"triangles":[0,1,2,0,2,3],)"
    R"("vertices":[0,0,10,0,10,10,0,10],"hull":4}}}}})";

int main() {
    CHECK(sc::abi_version() == SPC_ABI_VERSION);
    CHECK(!sc::library_version().empty());

    sc::Detection detected = sc::detect(json.data(), json.size());
    CHECK(detected.format == SPC_FORMAT_JSON && detected.version == "3.8.99");
    CHECK(detected.major == 3 && detected.minor == 8 && detected.patch == 99);

    sc::Result same = sc::convert(json.data(), json.size());
    CHECK(same.size() == json.size() && memcmp(same.data(), json.data(), json.size()) == 0);
    CHECK(same.report() == "[]" && same.loss_count() == 0);

    sc::Result lossy = sc::convert(physics.data(), physics.size(), {"4.1"});
    CHECK(lossy.loss_count() == 2 && lossy.max_impact() == SPC_IMPACT_POSE);
    CHECK(lossy.remedy_count(SPC_REMEDY_NONE) == 2);
    CHECK(lossy.report().find("physics.dropped") != std::string_view::npos);

    sc::Options to37{"3.7"};
    CHECK(sc::convert(stripped.data(), stripped.size(), to37).loss_count() == 1);
    to37.atlas = page;
    sc::Result uvs = sc::convert(stripped.data(), stripped.size(), to37);
    std::string_view out(reinterpret_cast<const char *>(uvs.data()), uvs.size());
    CHECK(uvs.loss_count() == 0 && out.find("0.15625,0.175") != std::string_view::npos);

    CHECK(sc::detect("PNG", 3).format == SPC_FORMAT_UNKNOWN);
    try {
        sc::convert(physics.data(), physics.size(), {"4.1", SPC_FORMAT_UNKNOWN, SPC_FLAG_FAIL_ON_LOSS});
        CHECK(false);
    } catch (const sc::Error &e) {
        CHECK(e.status() == SPC_ERR_LOSSY_REJECTED);
    }
    try {
        sc::convert(json.data(), json.size(), {"3.4"});
        CHECK(false);
    } catch (const sc::Error &e) {
        CHECK(e.status() == SPC_ERR_UNSUPPORTED_VERSION && strlen(e.what()) > 0);
    }
    try {
        sc::convert(json.data(), json.size(), {"not a version"});
        CHECK(false);
    } catch (const sc::Error &e) {
        CHECK(e.status() == SPC_ERR_INVALID_ARGUMENT);
    }
    return 0;
}
