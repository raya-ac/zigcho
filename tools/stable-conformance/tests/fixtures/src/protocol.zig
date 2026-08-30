pub const ClientPacket = enum(u16) {
    ping = 4,
    beatmap_info_request = 68,
    logout = 2,
    _,
};
