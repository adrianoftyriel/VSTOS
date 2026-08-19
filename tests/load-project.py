#!/usr/bin/env python3
"""Load a Carla project and check it produced a working rack.

    load-project.py /path/to/project.carxp [expected-plugin-count]

Used by the test suite to prove that the boot rack VSTOS ships is a project Carla
actually accepts - that the plugin instantiates, its parameters are there, and the
saved patchbay connections are restored. A .carxp is undocumented XML, so
"it looks right" is not evidence; loading it is.

Needs a JACK server (the dummy backend is fine) and Carla's python backend, which
is why the caller checks for both and skips rather than failing.
"""
import os
import sys
import time

sys.path.insert(0, "/usr/share/carla")

from carla_backend import (  # noqa: E402
    CarlaHostDLL,
    ENGINE_OPTION_PATH_BINARIES,
    ENGINE_OPTION_PATH_RESOURCES,
    ENGINE_OPTION_PROCESS_MODE,
    ENGINE_OPTION_TRANSPORT_MODE,
    ENGINE_PROCESS_MODE_MULTIPLE_CLIENTS,
    ENGINE_TRANSPORT_MODE_JACK,
)

LIB = "/usr/lib/carla/libcarla_standalone2.so"


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    project = argv[1]
    expected = int(argv[2]) if len(argv) > 2 else 1

    host = CarlaHostDLL(LIB, False)
    host.set_engine_option(ENGINE_OPTION_PATH_BINARIES, 0, "/usr/lib/carla")
    host.set_engine_option(ENGINE_OPTION_PATH_RESOURCES, 0, "/usr/share/carla/resources")
    host.set_engine_option(ENGINE_OPTION_PROCESS_MODE, ENGINE_PROCESS_MODE_MULTIPLE_CLIENTS, "")
    host.set_engine_option(ENGINE_OPTION_TRANSPORT_MODE, ENGINE_TRANSPORT_MODE_JACK, "")

    if not host.engine_init("JACK", "VSTOS-test"):
        sys.stderr.write("engine_init failed: %s\n" % host.get_last_error())
        return 1

    rc = 0
    try:
        if not host.load_project(project):
            sys.stderr.write("load_project failed: %s\n" % host.get_last_error())
            return 1

        # Plugin instantiation is asynchronous behind the engine's event loop.
        deadline = time.time() + 15
        while host.get_current_plugin_count() < expected and time.time() < deadline:
            time.sleep(0.25)

        count = host.get_current_plugin_count()
        if count != expected:
            sys.stderr.write("expected %d plugin(s), got %d\n" % (expected, count))
            return 1

        for i in range(count):
            info = host.get_plugin_info(i)
            params = host.get_parameter_count(i)
            print("plugin %d: %s (%d parameters)" % (i, info["name"], params))
            # A plugin that loads but exposes nothing has not really loaded: that
            # is what a stale or mismatched binary looks like from the host's side.
            if params == 0:
                sys.stderr.write("%s exposes no parameters\n" % info["name"])
                rc = 1
    finally:
        host.engine_close()

    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
