const std = @import("std");

// This is the numeric country table used by osu! stable and bancho.py.
const country_codes =
    "oceuadaeafagaialamanaoaqarasatauawazbabbbdbebfbgbhbibjbmbnbobrbsbtbvbwbybzcacccdcfcgchcickclcmcn" ++
    "cocrcucvcxcyczdedjdkdmdodzeceeegeheresetfifjfkfmfofrfxgagbgdgegfghgiglgmgngpgqgrgsgtgugwgyhkhmhn" ++
    "hrhthuidieilinioiqirisitjmjojpkekgkhkikmknkpkrkwkykzlalblclilklrlsltlulvlymamcmdmgmhmkmlmmmnmomp" ++
    "mqmrmsmtmumvmwmxmymznancnenfngninlnonpnrnunzompapepfpgphpkplpmpnprpsptpwpyqarerorurwsasbscsdsesg" ++
    "shsisjskslsmsnsosrstsvsysztctdtftgthtjtktmtntotltrtttvtwtzuaugumusuyuzvavcvevgvivnvuwfwsyeytrsza" ++
    "zmmezwxxa2o1axggimjeblmf";

pub fn normalized(value: []const u8) ?[2]u8 {
    if (value.len != 2 or !std.ascii.isAlphabetic(value[0]) or !std.ascii.isAlphabetic(value[1])) return null;
    const code = [2]u8{ std.ascii.toUpper(value[0]), std.ascii.toUpper(value[1]) };
    // Cloudflare uses these pseudo-countries when a real location is unavailable.
    if (std.mem.eql(u8, &code, "T1")) return null;
    return code;
}

pub fn numeric(value: []const u8) u8 {
    const code = normalized(value) orelse return 244;
    var i: usize = 0;
    while (i < country_codes.len) : (i += 2) {
        if (std.ascii.toLower(code[0]) == country_codes[i] and std.ascii.toLower(code[1]) == country_codes[i + 1]) {
            return @intCast((i / 2) + 1);
        }
    }
    return 244;
}

test "stable country numbers match bancho" {
    try std.testing.expectEqual(@as(u8, 16), numeric("AU"));
    try std.testing.expectEqual(@as(u8, 77), numeric("gb"));
    try std.testing.expectEqual(@as(u8, 225), numeric("US"));
    try std.testing.expectEqual(@as(u8, 244), numeric("XX"));
    try std.testing.expectEqual(@as(u8, 244), numeric("?"));
}
