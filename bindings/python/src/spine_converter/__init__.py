# spine-converter, unofficial converter for Spine skeleton data
# Spine is a trademark of Esoteric Software
# Users must hold their own Spine Editor license, see LICENSE

from __future__ import annotations

import ctypes
import json
import os
import sys
from dataclasses import dataclass
from enum import IntEnum, IntFlag
from pathlib import Path
from typing import List, Optional, Union

__all__ = [
    "Status",
    "Format",
    "Impact",
    "Remedy",
    "Flags",
    "Detection",
    "ReportEntry",
    "Conversion",
    "ConverterError",
    "abi_version",
    "library_version",
    "describe",
    "detect",
    "convert",
]

ABI_VERSION = 1


class Status(IntEnum):
    """Values mirror spc_status"""

    OK = 0
    INVALID_ARGUMENT = 1
    UNKNOWN_FORMAT = 2
    UNSUPPORTED_VERSION = 3
    MALFORMED = 4
    OUT_OF_MEMORY = 5
    LOSSY_REJECTED = 6


class Format(IntEnum):
    """Values mirror spc_format"""

    UNKNOWN = 0
    JSON = 1
    BINARY = 2
    ATLAS = 3


class Impact(IntEnum):
    """Values mirror spc_impact, ordered by severity"""

    NONE = 0
    EDITOR = 1
    CONTROL = 2
    POSE = 3
    RENDER = 4


class Remedy(IntEnum):
    """Values mirror spc_remedy"""

    NONE = 0
    REWRITE = 1
    RUNTIME = 2


class Flags(IntFlag):
    """Values mirror the SPC_FLAG_ bits"""

    NONE = 0
    FAIL_ON_LOSS = 1 << 0
    PRETTY_JSON = 1 << 1
    NO_REWRITE = 1 << 2


@dataclass(frozen=True)
class Detection:
    format: Format
    version: str
    major: int
    minor: int
    patch: int


@dataclass(frozen=True)
class ReportEntry:
    """Fields of one docs/report.md entry"""

    code: str
    severity: str
    impact: Impact
    step: str
    path: str
    message: str
    remedy: Remedy


@dataclass(frozen=True)
class Conversion:
    data: bytes
    report_json: str
    report: List[ReportEntry]
    loss_count: int
    max_impact: Impact


class ConverterError(Exception):
    def __init__(self, status: Status, message: str) -> None:
        super().__init__(message)
        self.status = status


class _Options(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("target_version", ctypes.c_char_p),
        ("target_format", ctypes.c_int),
        ("flags", ctypes.c_uint32),
        ("atlas", ctypes.c_char_p),
        ("atlas_length", ctypes.c_size_t),
    ]


class _DetectResult(ctypes.Structure):
    _fields_ = [
        ("format", ctypes.c_int),
        ("version", ctypes.c_char * 32),
        ("major", ctypes.c_uint16),
        ("minor", ctypes.c_uint16),
        ("patch", ctypes.c_uint16),
    ]


def _library_name() -> str:
    if sys.platform == "win32":
        return "spine_converter.dll"
    if sys.platform == "darwin":
        return "libspine_converter.dylib"
    return "libspine_converter.so"


def _load() -> ctypes.CDLL:
    override = os.environ.get("SPINE_CONVERTER_LIBRARY")
    path = os.path.abspath(override) if override else str(Path(__file__).with_name(_library_name()))
    lib = ctypes.CDLL(path)
    p, size, u8p = ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint8)
    signatures = {
        "spc_abi_version": ([], ctypes.c_uint32),
        "spc_library_version": ([], ctypes.c_char_p),
        "spc_status_string": ([ctypes.c_int], ctypes.c_char_p),
        "spc_detect": ([ctypes.c_char_p, size, ctypes.POINTER(_DetectResult)], ctypes.c_int),
        "spc_convert": ([ctypes.c_char_p, size, ctypes.POINTER(_Options), p, ctypes.POINTER(p)], ctypes.c_int),
        "spc_result_data": ([p, ctypes.POINTER(size)], u8p),
        "spc_result_report": ([p, ctypes.POINTER(size)], u8p),
        "spc_result_loss_count": ([p], size),
        "spc_result_max_impact": ([p], ctypes.c_int),
        "spc_result_error": ([p], ctypes.c_char_p),
        "spc_result_free": ([p], None),
    }
    for name, (args, result) in signatures.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result
    found = lib.spc_abi_version()
    if found != ABI_VERSION:
        raise ConverterError(Status.INVALID_ARGUMENT, f"{path} ABI {found}, binding expects {ABI_VERSION}")
    return lib


_lib = _load()


def abi_version() -> int:
    return _lib.spc_abi_version()


def library_version() -> str:
    return _lib.spc_library_version().decode()


def describe(status: Status) -> str:
    return _lib.spc_status_string(int(status)).decode()


def detect(data: bytes) -> Detection:
    """Format UNKNOWN when the data is not Spine data"""
    out = _DetectResult()
    status = Status(_lib.spc_detect(bytes(data), len(data), ctypes.byref(out)))
    if status == Status.UNKNOWN_FORMAT:
        return Detection(Format.UNKNOWN, "", 0, 0, 0)
    if status != Status.OK:
        raise ConverterError(status, describe(status))
    return Detection(Format(out.format), out.version.decode(), out.major, out.minor, out.patch)


def convert(
    data: bytes,
    target_version: Optional[str] = None,
    target_format: Union[Format, int] = Format.UNKNOWN,
    flags: Union[Flags, int] = Flags.NONE,
    atlas: Optional[bytes] = None,
) -> Conversion:
    """None and UNKNOWN keep the source version and format, raises ConverterError on failure

    atlas is the atlas text of a 3.5 or 3.6 skeleton, it keeps mesh UVs of stripped regions
    """
    atlas_bytes = None if atlas is None else bytes(atlas)
    options = _Options(
        ctypes.sizeof(_Options),
        None if target_version is None else target_version.encode(),
        int(target_format),
        int(flags),
        atlas_bytes,
        0 if atlas_bytes is None else len(atlas_bytes),
    )
    result = ctypes.c_void_p()
    status = Status(_lib.spc_convert(bytes(data), len(data), ctypes.byref(options), None, ctypes.byref(result)))
    try:
        if status != Status.OK:
            message = _lib.spc_result_error(result).decode() if result.value else describe(status)
            raise ConverterError(status, message)
        length = ctypes.c_size_t()
        output = _lib.spc_result_data(result, ctypes.byref(length))
        payload = ctypes.string_at(output, length.value)
        report = _lib.spc_result_report(result, ctypes.byref(length))
        report_json = ctypes.string_at(report, length.value).decode()
        return Conversion(
            payload,
            report_json,
            [
                ReportEntry(
                    e["code"],
                    e["severity"],
                    Impact[e["impact"].upper()],
                    e["step"],
                    e["path"],
                    e["message"],
                    Remedy[e["remedy"].upper()],
                )
                for e in json.loads(report_json)
            ],
            _lib.spc_result_loss_count(result),
            Impact(_lib.spc_result_max_impact(result)),
        )
    finally:
        _lib.spc_result_free(result)
