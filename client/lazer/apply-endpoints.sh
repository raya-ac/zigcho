#!/bin/sh
set -eu

checkout=${1:-work/osu-client}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
expected_commit=$(tr -d '\r\n' < "$script_dir/upstream-commit.txt")
actual_commit=$(git -C "$checkout" rev-parse HEAD)

if [ "$actual_commit" != "$expected_commit" ]; then
    echo "expected osu! $expected_commit, got $actual_commit" >&2
    exit 1
fi

cp "$script_dir/ProductionEndpointConfiguration.cs" "$checkout/osu.Game/Online/ProductionEndpointConfiguration.cs"
cp "$script_dir/DevelopmentEndpointConfiguration.cs" "$checkout/osu.Game/Online/DevelopmentEndpointConfiguration.cs"
echo "zigcho endpoints applied to $checkout"
