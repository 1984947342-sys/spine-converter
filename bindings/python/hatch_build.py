import os

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class PlatformTag(BuildHookInterface):
    """Tags the wheel for the one native library it carries"""

    def initialize(self, version, build_data):
        tag = os.environ.get("SPINE_CONVERTER_WHEEL_TAG")
        if not tag:
            raise RuntimeError("set SPINE_CONVERTER_WHEEL_TAG, such as py3-none-win_amd64")
        build_data["pure_python"] = False
        build_data["tag"] = tag
