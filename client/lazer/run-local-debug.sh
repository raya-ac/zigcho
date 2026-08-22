#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$script_dir/../.." && pwd)
checkout=${ZIGCHO_LAZER_CHECKOUT:-$repo/work/osu-client}
if [ -n "${ZIGCHO_LAZER_DEBUG_APP:-}" ]; then
    executable="$ZIGCHO_LAZER_DEBUG_APP/Contents/MacOS/osu!"
else
    executable="$checkout/osu.Desktop/bin/Debug/net8.0/osx-arm64/publish/osu!"
fi
development_config="$checkout/osu.Game/Online/DevelopmentEndpointConfiguration.cs"

if [ ! -x "$executable" ]; then
    echo "debug client executable not found: $executable" >&2
    exit 1
fi

if ! grep -q 'APIUrl = @"http://127\.0\.0\.1:' "$development_config"; then
    echo "refusing insecure requests because the checked-in Debug API is not loopback" >&2
    exit 1
fi

OSU_INSECURE_REQUESTS=1 exec "$executable" "$@"
