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

if git -C "$checkout" apply --ignore-space-change --ignore-whitespace --check "$script_dir/zigcho-client.patch" 2>/dev/null; then
    git -C "$checkout" apply --ignore-space-change --ignore-whitespace "$script_dir/zigcho-client.patch"
    echo "zigcho client patch applied to $checkout"
    exit 0
fi

if git -C "$checkout" apply --ignore-space-change --ignore-whitespace --reverse --check "$script_dir/zigcho-client.patch" 2>/dev/null; then
    echo "zigcho client patch already applied to $checkout"
    exit 0
fi

echo "zigcho client patch does not apply cleanly to the pinned osu! checkout" >&2
exit 1
