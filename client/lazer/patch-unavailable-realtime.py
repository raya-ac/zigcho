#!/usr/bin/env python3

from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    data = path.read_bytes()
    normalized = data.replace(b"\r\n", b"\n")
    if new.encode() in normalized:
        return
    newline = b"\r\n" if data.count(b"\r\n") > data.count(b"\n") // 2 else b"\n"
    old_bytes = old.encode()
    new_bytes = new.encode()
    if old_bytes not in normalized:
        marker = old.splitlines()[0].strip()
        raise SystemExit(f"pinned client source changed near {marker!r}: {path}")
    updated = normalized.replace(old_bytes, new_bytes, 1)
    path.write_bytes(updated if newline == b"\n" else updated.replace(b"\n", newline))


checkout = Path(sys.argv[1])
api_access = checkout / "osu.Game/Online/API/APIAccess.cs"
endpoint = checkout / "osu.Game/Online/EndpointConfiguration.cs"
desktop_program = checkout / "osu.Desktop/Program.cs"
desktop_project = checkout / "osu.Desktop/osu.Desktop.csproj"
osu_game = checkout / "osu.Game/OsuGame.cs"
beatmap_metadata_source = checkout / "osu.Game/Beatmaps/APIBeatmapMetadataSource.cs"
leaderboard_manager = checkout / "osu.Game/Online/Leaderboards/LeaderboardManager.cs"
scores_container = checkout / "osu.Game/Overlays/BeatmapSet/Scores/ScoresContainer.cs"

replace_once(
    api_access,
    "            NotificationsClient = setUpNotificationsClient();",
    """            NotificationsClient = endpoints.RealtimeServicesAvailable
                ? setUpNotificationsClient()
                : new DummyNotificationsClient { HandleMessage = _ => true };""",
)
replace_once(
    api_access,
    "            new HubClientConnector(clientName, endpoint, this, versionHash);",
    "            Endpoints.RealtimeServicesAvailable ? new HubClientConnector(clientName, endpoint, this, versionHash) : null;",
)
if b"new UnavailableRealtimeChatClient()" in api_access.read_bytes():
    replace_once(
        api_access,
        """        public IChatClient GetChatClient() =>
            Endpoints.RealtimeServicesAvailable ? new WebSocketChatClient(this) : new UnavailableRealtimeChatClient();""",
        """        public IChatClient GetChatClient() =>
            Endpoints.RealtimeServicesAvailable ? new WebSocketChatClient(this) : new PollingChatClient(this);""",
    )
else:
    replace_once(
        api_access,
        "        public IChatClient GetChatClient() => new WebSocketChatClient(this);",
        """        public IChatClient GetChatClient() =>
            Endpoints.RealtimeServicesAvailable ? new WebSocketChatClient(this) : new PollingChatClient(this);""",
    )
replace_once(
    endpoint,
    """    public class EndpointConfiguration
    {""",
    """    public class EndpointConfiguration
    {
        /// <summary>
        /// Whether websocket and SignalR services are available for this endpoint set.
        /// </summary>
        public bool RealtimeServicesAvailable { get; set; } = true;
""",
)

# Keep the custom client away from an installed official lazer client. This changes
# both its storage directory and IPC pipe, and also prevents the official updater
# from replacing a zigcho build after startup.
replace_once(
    desktop_program,
    '        private const string base_game_name = @"osu-development";',
    '        private const string base_game_name = @"zigcho-lazer-development";',
)
replace_once(
    desktop_program,
    '        private const string base_game_name = @"osu";',
    '        private const string base_game_name = @"zigcho-lazer";',
)
replace_once(
    desktop_program,
    """        public static void Main(string[] args)
        {
            // IMPORTANT DON'T IGNORE: For general sanity, velopack's setup needs to run before anything else.""",
    """        public static void Main(string[] args)
        {
            Environment.SetEnvironmentVariable("OSU_EXTERNAL_UPDATE_PROVIDER", "zigcho");

            // IMPORTANT DON'T IGNORE: For general sanity, velopack's setup needs to run before anything else.""",
)
replace_once(
    osu_game,
    '        public const string IPC_PIPE_NAME = "osu-lazer-debug";',
    '        public const string IPC_PIPE_NAME = "zigcho-lazer-debug";',
)
replace_once(
    osu_game,
    '        public const string IPC_PIPE_NAME = "osu-lazer";',
    '        public const string IPC_PIPE_NAME = "zigcho-lazer";',
)
replace_once(desktop_project, "    <AssemblyTitle>osu!(lazer)</AssemblyTitle>", "    <AssemblyTitle>zigcho lazer</AssemblyTitle>")
replace_once(desktop_project, "    <Product>osu!(lazer)</Product>", "    <Product>zigcho lazer</Product>")
replace_once(desktop_project, "    <Title>osu!</Title>", "    <Title>zigcho lazer</Title>")

# The upstream gameplay metadata path omits an already-known online ID and sends
# only checksum + filename. A cold zigcho cache cannot resolve a checksum back to
# a set without an official API key, while the local realm already has the ID.
replace_once(
    beatmap_metadata_source,
    "            var req = new GetBeatmapRequest(md5Hash: beatmapInfo.MD5Hash, filename: beatmapInfo.Path);",
    "            var req = new GetBeatmapRequest(onlineId: beatmapInfo.OnlineID, md5Hash: beatmapInfo.MD5Hash, filename: beatmapInfo.Path);",
)

# Official lazer treats cached pending/unknown status as proof that an online
# leaderboard cannot exist. That is not true for zigcho: local metadata can lag
# the server, and the server also owns leaderboards for custom statuses. Once a
# map has an online ID, ask zigcho and let its response decide what is available.
replace_once(
    leaderboard_manager,
    "                    if (newCriteria.Beatmap.OnlineID <= 0 || newCriteria.Beatmap.Status <= BeatmapOnlineStatus.Pending)",
    "                    if (!ZigchoLeaderboardAvailability.IsAvailable(newCriteria.Beatmap))",
)
replace_once(
    scores_container,
    "            if (Beatmap.Value == null || Beatmap.Value.OnlineID <= 0 || (Beatmap.Value.Status <= BeatmapOnlineStatus.Pending))",
    "            if (!osu.Game.Online.Leaderboards.ZigchoLeaderboardAvailability.IsAvailable(Beatmap.Value))",
)
