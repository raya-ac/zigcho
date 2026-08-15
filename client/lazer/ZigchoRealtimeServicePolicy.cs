// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using System;

namespace osu.Game.Online.API
{
    public static class ZigchoRealtimeServicePolicy
    {
        public static bool AllowsHub(EndpointConfiguration endpoints, string endpoint) =>
            endpoints.RealtimeServicesAvailable
            || (endpoints.MultiplayerServicesAvailable
                && string.Equals(endpoint, endpoints.MultiplayerUrl, StringComparison.Ordinal));
    }
}
