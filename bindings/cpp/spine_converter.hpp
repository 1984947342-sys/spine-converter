/*
 * spine-converter, unofficial converter for Spine skeleton data
 * Spine is a trademark of Esoteric Software
 * Users must hold their own Spine Editor license, see LICENSE
 *
 * Header only C++17 wrapper of spine_converter.h
 */
#ifndef SPINE_CONVERTER_HPP
#define SPINE_CONVERTER_HPP

#include "spine_converter.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

namespace spine_converter {

class Error : public std::runtime_error {
public:
    Error(spc_status status, const std::string &message)
        : std::runtime_error(message.empty() ? spc_status_string(status) : message),
          status_(status) {}

    spc_status status() const noexcept { return status_; }

private:
    spc_status status_;
};

struct Detection {
    spc_format format = SPC_FORMAT_UNKNOWN;
    /** Empty when the data carries no version */
    std::string version;
    uint16_t major = 0;
    uint16_t minor = 0;
    uint16_t patch = 0;
};

struct Options {
    /** Empty keeps the source version */
    std::string target_version;
    spc_format target_format = SPC_FORMAT_UNKNOWN;
    uint32_t flags = 0;
    /** Atlas text of a 3.5 or 3.6 skeleton, empty when absent */
    std::string_view atlas{};
};

/** Output and report of one conversion */
class Result {
public:
    const uint8_t *data() const noexcept { return spc_result_data(result_.get(), nullptr); }

    size_t size() const noexcept {
        size_t length = 0;
        spc_result_data(result_.get(), &length);
        return length;
    }

    /** JSON array, see docs/report.md */
    std::string_view report() const noexcept {
        size_t length = 0;
        const char *text = spc_result_report(result_.get(), &length);
        return std::string_view(text, length);
    }

    size_t loss_count() const noexcept { return spc_result_loss_count(result_.get()); }
    spc_impact max_impact() const noexcept { return spc_result_max_impact(result_.get()); }

    size_t remedy_count(spc_remedy remedy) const noexcept {
        return spc_result_remedy_count(result_.get(), remedy);
    }

private:
    struct Free {
        void operator()(spc_result *result) const noexcept { spc_result_free(result); }
    };

    explicit Result(spc_result *result) : result_(result) {}

    std::unique_ptr<spc_result, Free> result_;

    friend Result convert(const void *, size_t, const Options &);
};

inline uint32_t abi_version() noexcept { return spc_abi_version(); }
inline std::string_view library_version() noexcept { return spc_library_version(); }

/** Format SPC_FORMAT_UNKNOWN when the data is not Spine data */
inline Detection detect(const void *data, size_t size) {
    spc_detect_result out;
    spc_status status = spc_detect(static_cast<const uint8_t *>(data), size, &out);
    if (status == SPC_ERR_UNKNOWN_FORMAT) return Detection{};
    if (status != SPC_OK) throw Error(status, "");
    return Detection{out.format, out.version, out.major, out.minor, out.patch};
}

/** Throws Error on failure, including SPC_ERR_LOSSY_REJECTED */
inline Result convert(const void *data, size_t size, const Options &options = {}) {
    spc_options native = {
        sizeof(spc_options),
        options.target_version.empty() ? nullptr : options.target_version.c_str(),
        options.target_format,
        options.flags,
        options.atlas.empty() ? nullptr : reinterpret_cast<const uint8_t *>(options.atlas.data()),
        options.atlas.size(),
    };
    spc_result *out = nullptr;
    spc_status status =
        spc_convert(static_cast<const uint8_t *>(data), size, &native, nullptr, &out);
    Result result(out);
    if (status != SPC_OK) throw Error(status, out ? spc_result_error(out) : "");
    return result;
}

} // namespace spine_converter

#endif
