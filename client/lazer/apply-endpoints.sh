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
cp "$script_dir/TrustedDomainOnlineStore.cs" "$checkout/osu.Game/Online/TrustedDomainOnlineStore.cs"
cp "$script_dir/TrustedDomainOnlineStoreTest.cs" "$checkout/osu.Game.Tests/TrustedDomainOnlineStoreTest.cs"
cp "$script_dir/PollingChatClient.cs" "$checkout/osu.Game/Online/Chat/PollingChatClient.cs"
cp "$script_dir/PollingChatClientTest.cs" "$checkout/osu.Game.Tests/PollingChatClientTest.cs"
cp "$script_dir/ZigchoLeaderboardAvailability.cs" "$checkout/osu.Game/Online/Leaderboards/ZigchoLeaderboardAvailability.cs"
cp "$script_dir/ZigchoLeaderboardAvailabilityTest.cs" "$checkout/osu.Game.Tests/ZigchoLeaderboardAvailabilityTest.cs"
python3 "$script_dir/patch-unavailable-realtime.py" "$checkout"
echo "zigcho endpoints and trusted resource domains applied to $checkout"
