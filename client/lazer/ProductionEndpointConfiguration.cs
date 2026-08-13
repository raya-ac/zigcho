// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

namespace osu.Game.Online
{
    public class ProductionEndpointConfiguration : EndpointConfiguration
    {
        public ProductionEndpointConfiguration()
        {
            RealtimeServicesAvailable = false;
            WebsiteUrl = @"https://kai.ovh";
            APIUrl = @"https://api.kai.ovh";
            APIClientSecret = @"zigcho-lazer";
            APIClientID = "5";
            SpectatorUrl = "https://spectator.kai.ovh/spectator";
            MultiplayerUrl = "https://spectator.kai.ovh/multiplayer";
            MetadataUrl = "https://spectator.kai.ovh/metadata";
            BeatmapSubmissionServiceUrl = "https://bss.kai.ovh";
        }
    }
}
