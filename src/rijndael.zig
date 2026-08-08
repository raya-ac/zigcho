const std = @import("std");

/// Rijndael-256: 256-bit key and 256-bit block. This is the cipher used by
/// osu!stable score submissions. It is not AES-256, whose block is 128 bits.
pub const Rijndael256 = struct {
    const nb = 8;
    const nk = 8;
    const nr = 14;

    round_keys: [nb * (nr + 1)]u32,
    sbox: [256]u8,
    inverse_sbox: [256]u8,

    pub fn init(key: [32]u8) Rijndael256 {
        var self: Rijndael256 = undefined;
        for (0..256) |i| {
            const value: u8 = @intCast(i);
            self.sbox[i] = makeSbox(value);
        }
        for (self.sbox, 0..) |value, i| self.inverse_sbox[value] = @intCast(i);

        for (0..nk) |i| self.round_keys[i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .big);
        var rcon: u8 = 1;
        for (nk..self.round_keys.len) |i| {
            var temp = self.round_keys[i - 1];
            if (i % nk == 0) {
                temp = self.subWord(std.math.rotl(u32, temp, 8)) ^ (@as(u32, rcon) << 24);
                rcon = xtime(rcon);
            } else if (i % nk == 4) {
                temp = self.subWord(temp);
            }
            self.round_keys[i] = self.round_keys[i - nk] ^ temp;
        }
        return self;
    }

    pub fn encryptBlock(self: *const Rijndael256, input: [32]u8) [32]u8 {
        var state = input;
        self.addRoundKey(&state, 0);
        for (1..nr) |round| {
            self.subBytes(&state);
            shiftRows(&state, false);
            mixColumns(&state, false);
            self.addRoundKey(&state, round);
        }
        self.subBytes(&state);
        shiftRows(&state, false);
        self.addRoundKey(&state, nr);
        return state;
    }

    pub fn decryptBlock(self: *const Rijndael256, input: [32]u8) [32]u8 {
        var state = input;
        self.addRoundKey(&state, nr);
        var round: usize = nr - 1;
        while (round > 0) : (round -= 1) {
            shiftRows(&state, true);
            self.inverseSubBytes(&state);
            self.addRoundKey(&state, round);
            mixColumns(&state, true);
        }
        shiftRows(&state, true);
        self.inverseSubBytes(&state);
        self.addRoundKey(&state, 0);
        return state;
    }

    fn subWord(self: *const Rijndael256, word: u32) u32 {
        return @as(u32, self.sbox[(word >> 24) & 0xff]) << 24 |
            @as(u32, self.sbox[(word >> 16) & 0xff]) << 16 |
            @as(u32, self.sbox[(word >> 8) & 0xff]) << 8 |
            self.sbox[word & 0xff];
    }

    fn subBytes(self: *const Rijndael256, state: *[32]u8) void {
        for (state) |*byte| byte.* = self.sbox[byte.*];
    }

    fn inverseSubBytes(self: *const Rijndael256, state: *[32]u8) void {
        for (state) |*byte| byte.* = self.inverse_sbox[byte.*];
    }

    fn addRoundKey(self: *const Rijndael256, state: *[32]u8, round: usize) void {
        for (0..nb) |column| {
            const word = self.round_keys[round * nb + column];
            state[column * 4] ^= @truncate(word >> 24);
            state[column * 4 + 1] ^= @truncate(word >> 16);
            state[column * 4 + 2] ^= @truncate(word >> 8);
            state[column * 4 + 3] ^= @truncate(word);
        }
    }
};

pub fn decryptCbcPkcs7(
    allocator: std.mem.Allocator,
    key: [32]u8,
    iv: [32]u8,
    ciphertext: []const u8,
) ![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 32 != 0) return error.InvalidCiphertextLength;
    const cipher = Rijndael256.init(key);
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    var previous = iv;
    var offset: usize = 0;
    while (offset < ciphertext.len) : (offset += 32) {
        const encrypted: [32]u8 = ciphertext[offset..][0..32].*;
        const decrypted = cipher.decryptBlock(encrypted);
        for (0..32) |i| plaintext[offset + i] = decrypted[i] ^ previous[i];
        previous = encrypted;
    }
    const padding = plaintext[plaintext.len - 1];
    if (padding == 0 or padding > 32 or padding > plaintext.len) return error.InvalidPadding;
    var mismatch: u8 = 0;
    for (plaintext[plaintext.len - padding ..]) |byte| mismatch |= byte ^ padding;
    if (mismatch != 0) return error.InvalidPadding;
    return allocator.realloc(plaintext, plaintext.len - padding);
}

fn shiftRows(state: *[32]u8, inverse: bool) void {
    const forward = [_]usize{ 0, 1, 3, 4 };
    const copy = state.*;
    for (0..4) |row| {
        const shift = if (inverse and forward[row] != 0) 8 - forward[row] else forward[row];
        for (0..8) |column| state[column * 4 + row] = copy[((column + shift) % 8) * 4 + row];
    }
}

fn mixColumns(state: *[32]u8, inverse: bool) void {
    for (0..8) |column| {
        const i = column * 4;
        const a = state[i..][0..4].*;
        if (inverse) {
            state[i] = gfMul(a[0], 14) ^ gfMul(a[1], 11) ^ gfMul(a[2], 13) ^ gfMul(a[3], 9);
            state[i + 1] = gfMul(a[0], 9) ^ gfMul(a[1], 14) ^ gfMul(a[2], 11) ^ gfMul(a[3], 13);
            state[i + 2] = gfMul(a[0], 13) ^ gfMul(a[1], 9) ^ gfMul(a[2], 14) ^ gfMul(a[3], 11);
            state[i + 3] = gfMul(a[0], 11) ^ gfMul(a[1], 13) ^ gfMul(a[2], 9) ^ gfMul(a[3], 14);
        } else {
            state[i] = gfMul(a[0], 2) ^ gfMul(a[1], 3) ^ a[2] ^ a[3];
            state[i + 1] = a[0] ^ gfMul(a[1], 2) ^ gfMul(a[2], 3) ^ a[3];
            state[i + 2] = a[0] ^ a[1] ^ gfMul(a[2], 2) ^ gfMul(a[3], 3);
            state[i + 3] = gfMul(a[0], 3) ^ a[1] ^ a[2] ^ gfMul(a[3], 2);
        }
    }
}

fn makeSbox(value: u8) u8 {
    const inverse: u8 = if (value == 0) 0 else gfPow(value, 254);
    return inverse ^ std.math.rotl(u8, inverse, 1) ^ std.math.rotl(u8, inverse, 2) ^
        std.math.rotl(u8, inverse, 3) ^ std.math.rotl(u8, inverse, 4) ^ 0x63;
}

fn gfPow(value: u8, power: u8) u8 {
    var result: u8 = 1;
    var base = value;
    var exponent = power;
    while (exponent != 0) : (exponent >>= 1) {
        if (exponent & 1 != 0) result = gfMul(result, base);
        base = gfMul(base, base);
    }
    return result;
}

fn xtime(value: u8) u8 {
    return (value *% 2) ^ if (value & 0x80 != 0) @as(u8, 0x1b) else 0;
}

fn gfMul(left: u8, right: u8) u8 {
    var a = left;
    var b = right;
    var result: u8 = 0;
    while (b != 0) : (b >>= 1) {
        if (b & 1 != 0) result ^= a;
        a = xtime(a);
    }
    return result;
}
