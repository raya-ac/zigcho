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


def replace_one_of(path: Path, old_values: tuple[str, ...], new: str) -> None:
    data = path.read_bytes()
    normalized = data.replace(b"\r\n", b"\n")
    if new.encode() in normalized:
        return
    newline = b"\r\n" if data.count(b"\r\n") > data.count(b"\n") // 2 else b"\n"
    for old in old_values:
        if old.encode() in normalized:
            updated = normalized.replace(old.encode(), new.encode(), 1)
            path.write_bytes(updated if newline == b"\n" else updated.replace(b"\n", newline))
            return
    raise SystemExit(f"pinned client source changed near {old_values[0].strip()!r}: {path}")


checkout = Path(sys.argv[1])
api_access = checkout / "osu.Game/Online/API/APIAccess.cs"
endpoint = checkout / "osu.Game/Online/EndpointConfiguration.cs"
desktop_program = checkout / "osu.Desktop/Program.cs"
desktop_project = checkout / "osu.Desktop/osu.Desktop.csproj"
osu_game = checkout / "osu.Game/OsuGame.cs"
osu_game_base = checkout / "osu.Game/OsuGameBase.cs"
beatmap_metadata_source = checkout / "osu.Game/Beatmaps/APIBeatmapMetadataSource.cs"
leaderboard_manager = checkout / "osu.Game/Online/Leaderboards/LeaderboardManager.cs"
scores_container = checkout / "osu.Game/Overlays/BeatmapSet/Scores/ScoresContainer.cs"
submit_score_request = checkout / "osu.Game/Online/Rooms/SubmitScoreRequest.cs"
submit_solo_score_request = checkout / "osu.Game/Online/Solo/SubmitSoloScoreRequest.cs"
submit_room_score_request = checkout / "osu.Game/Online/Rooms/SubmitRoomScoreRequest.cs"
solo_player = checkout / "osu.Game/Screens/Play/SoloPlayer.cs"
room_submitting_player = checkout / "osu.Game/Screens/Play/RoomSubmittingPlayer.cs"

replace_once(
    api_access,
    "            NotificationsClient = setUpNotificationsClient();",
    """            NotificationsClient = endpoints.RealtimeServicesAvailable
                ? setUpNotificationsClient()
                : new DummyNotificationsClient { HandleMessage = _ => true };""",
)
replace_one_of(
    api_access,
    (
        "            new HubClientConnector(clientName, endpoint, this, versionHash);",
        "            Endpoints.RealtimeServicesAvailable ? new HubClientConnector(clientName, endpoint, this, versionHash) : null;",
    ),
    "            ZigchoRealtimeServicePolicy.AllowsHub(Endpoints, endpoint) ? new HubClientConnector(clientName, endpoint, this, versionHash) : null;",
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
replace_once(
    endpoint,
    """        public bool RealtimeServicesAvailable { get; set; } = true;
""",
    """        public bool RealtimeServicesAvailable { get; set; } = true;

        /// <summary>
        /// Whether the normal multiplayer SignalR hub is available independently.
        /// </summary>
        public bool MultiplayerServicesAvailable { get; set; }
""",
)

# Keep the custom client away from an installed official lazer client. This changes
# both its storage directory and IPC pipe, and also prevents the official updater
# from replacing a zigcho build after startup.
replace_one_of(
    desktop_program,
    ('        private const string base_game_name = @"osu-development";', '        private const string base_game_name = @"zigcho-lazer-development";'),
    '        private const string base_game_name = @"zigcho-lazer-debug";',
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
replace_one_of(desktop_project, ("    <AssemblyTitle>osu!(lazer)</AssemblyTitle>", "    <AssemblyTitle>zigcho lazer</AssemblyTitle>"), "    <AssemblyTitle>zigcho!lazer</AssemblyTitle>")
replace_one_of(desktop_project, ("    <Product>osu!(lazer)</Product>", "    <Product>zigcho lazer</Product>"), "    <Product>zigcho!lazer</Product>")
replace_one_of(desktop_project, ("    <Title>osu!</Title>", "    <Title>zigcho lazer</Title>"), "    <Title>zigcho!lazer</Title>")
replace_one_of(
    osu_game_base,
    (
        """#if DEBUG
        public const string GAME_NAME = "osu! (development)";
#else
        public const string GAME_NAME = "osu!";
#endif""",
        """#if DEBUG
        public const string GAME_NAME = "zigcho!lazer";
#else
        public const string GAME_NAME = "osu!";
#endif""",
    ),
    """#if DEBUG
        public const string GAME_NAME = "zigcho!lazer";
#else
        public const string GAME_NAME = "zigcho!lazer";
#endif""",
)

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
replace_once(
    scores_container,
    "using osu.Game.Graphics.UserInterface;",
    """using osu.Game.Graphics.Sprites;
using osu.Game.Graphics.UserInterface;""",
)
replace_once(
    scores_container,
    "        private readonly LeaderboardModSelector modSelector;",
    """        private readonly LeaderboardModSelector modSelector;
        private readonly OsuSpriteText namespaceLabel;""",
)
replace_once(
    scores_container,
    """                                modSelector = new LeaderboardModSelector
                                {
                                    Anchor = Anchor.TopCentre,
                                    Origin = Anchor.TopCentre,
                                    Ruleset = { BindTarget = ruleset }
                                }""",
    """                                namespaceLabel = new OsuSpriteText
                                {
                                    Anchor = Anchor.TopCentre,
                                    Origin = Anchor.TopCentre,
                                    Text = "vanilla leaderboard"
                                },
                                modSelector = new LeaderboardModSelector
                                {
                                    Anchor = Anchor.TopCentre,
                                    Origin = Anchor.TopCentre,
                                    Ruleset = { BindTarget = ruleset }
                                }""",
)
replace_once(
    scores_container,
    "            modSelector.SelectedMods.CollectionChanged += (_, _) => getScores();",
    """            modSelector.SelectedMods.CollectionChanged += (_, _) =>
            {
                updateZigchoLeaderboardNamespace();
                getScores();
            };""",
)
replace_once(
    scores_container,
    "        private bool userIsSupporter => api.IsLoggedIn && api.LocalUser.Value.IsSupporter;",
    """        private void updateZigchoLeaderboardNamespace()
        {
            var acronyms = modSelector.SelectedMods.Select(mod => mod.Acronym.ToString()).ToArray();
            namespaceLabel.Text = acronyms.Contains("AP")
                ? "autopilot leaderboard"
                : acronyms.Contains("RX")
                    ? "relax leaderboard"
                    : "vanilla leaderboard";
        }

        private bool userIsSupporter => api.IsLoggedIn && api.LocalUser.Value.IsSupporter;""",
)

# Zigcho stores the exact replay beside the score. Official infrastructure gets
# this data from the spectator service; the isolated client submits its encoded
# .osr in the same authenticated request so score and replay cannot diverge.
replace_once(
    submit_score_request,
    "using System.Net.Http;",
    """using System;
using System.IO;
using System.Net.Http;""",
)
replace_once(
    submit_score_request,
    "using Newtonsoft.Json;",
    """using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using osu.Game.Beatmaps;""",
)
replace_once(
    submit_score_request,
    "using osu.Game.Scoring;",
    """using osu.Game.Scoring;
using osu.Game.Scoring.Legacy;""",
)
replace_once(
    submit_score_request,
    """        protected readonly long ScoreId;

        protected SubmitScoreRequest(ScoreInfo scoreInfo, long scoreId)
        {
            Score = SoloScoreInfo.ForSubmission(scoreInfo);
            ScoreId = scoreId;
        }""",
    """        protected readonly long ScoreId;

        private readonly string serializedScore;

        protected SubmitScoreRequest(Score score, IBeatmap beatmap, long scoreId)
        {
            Score = SoloScoreInfo.ForSubmission(score.ScoreInfo);
            ScoreId = scoreId;

            var settings = new JsonSerializerSettings
            {
                ReferenceLoopHandling = ReferenceLoopHandling.Ignore
            };
            var payload = JObject.FromObject(Score, JsonSerializer.Create(settings));
            using var replay = new MemoryStream();
            new LegacyScoreEncoder(score, beatmap).Encode(replay, leaveOpen: true);
            payload[\"replay\"] = Convert.ToBase64String(replay.ToArray());
            serializedScore = payload.ToString(Formatting.None);
        }""",
)
replace_once(
    submit_score_request,
    """            req.AddRaw(JsonConvert.SerializeObject(Score, new JsonSerializerSettings
            {
                ReferenceLoopHandling = ReferenceLoopHandling.Ignore
            }));""",
    "            req.AddRaw(serializedScore);",
)
replace_once(
    submit_solo_score_request,
    "using osu.Game.Online.Rooms;",
    """using osu.Game.Beatmaps;
using osu.Game.Online.Rooms;""",
)
replace_once(
    submit_solo_score_request,
    """        public SubmitSoloScoreRequest(ScoreInfo scoreInfo, long scoreId, int beatmapId)
            : base(scoreInfo, scoreId)""",
    """        public SubmitSoloScoreRequest(Score score, IBeatmap beatmap, long scoreId, int beatmapId)
            : base(score, beatmap, scoreId)""",
)
replace_once(
    submit_room_score_request,
    "using osu.Game.Scoring;",
    """using osu.Game.Beatmaps;
using osu.Game.Scoring;""",
)
replace_once(
    submit_room_score_request,
    """        public SubmitRoomScoreRequest(ScoreInfo scoreInfo, long scoreId, long roomId, long playlistItemId)
            : base(scoreInfo, scoreId)""",
    """        public SubmitRoomScoreRequest(Score score, IBeatmap beatmap, long scoreId, long roomId, long playlistItemId)
            : base(score, beatmap, scoreId)""",
)
replace_once(
    solo_player,
    "            return new SubmitSoloScoreRequest(score.ScoreInfo, token, beatmap.OnlineID);",
    "            return new SubmitSoloScoreRequest(score, GameplayState.Beatmap, token, beatmap.OnlineID);",
)
replace_once(
    room_submitting_player,
    "            return new SubmitRoomScoreRequest(score.ScoreInfo, token, Room.RoomID.Value, PlaylistItem.ID);",
    "            return new SubmitRoomScoreRequest(score, GameplayState.Beatmap, token, Room.RoomID.Value, PlaylistItem.ID);",
)
