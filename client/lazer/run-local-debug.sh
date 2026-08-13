#!/bin/sh
set -eu

app=${ZIGCHO_LAZER_DEBUG_APP:-work/Zigcho lazer Debug.app}
executable="$app/Contents/MacOS/osu!"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -x "$executable" ]; then
    echo "debug client executable not found: $executable" >&2
    exit 1
fi

if ! grep -q 'APIUrl = @"http://127\.0\.0\.1:' "$script_dir/DevelopmentEndpointConfiguration.cs"; then
    echo "refusing insecure requests because the checked-in Debug API is not loopback" >&2
    exit 1
fi

OSU_INSECURE_REQUESTS=1 exec "$executable" "$@"
