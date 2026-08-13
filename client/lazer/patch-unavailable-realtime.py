#!/usr/bin/env python3

from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    data = path.read_bytes()
    normalized = data.replace(b"\r\n", b"\n")
    if new.encode() in normalized:
        return
    newline = b"\r\n" if data.count(b"\r\n") > data.count(b"\n") // 2 else b"\n"
    old_bytes = old.encode().replace(b"\n", newline)
    new_bytes = new.encode().replace(b"\n", newline)
    if old_bytes not in data:
        raise SystemExit(f"pinned client source changed: {path}")
    path.write_bytes(data.replace(old_bytes, new_bytes, 1))


checkout = Path(sys.argv[1])
api_access = checkout / "osu.Game/Online/API/APIAccess.cs"
endpoint = checkout / "osu.Game/Online/EndpointConfiguration.cs"
desktop_program = checkout / "osu.Desktop/Program.cs"
desktop_project = checkout / "osu.Desktop/osu.Desktop.csproj"
osu_game = checkout / "osu.Game/OsuGame.cs"

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
replace_once(
    api_access,
    "        public IChatClient GetChatClient() => new WebSocketChatClient(this);",
    """        public IChatClient GetChatClient() =>
            Endpoints.RealtimeServicesAvailable ? new WebSocketChatClient(this) : new UnavailableRealtimeChatClient();""",
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
