use std::{panic::catch_unwind, slice};

use rosu_map::section::general::GameMode;
use akatsuki_pp::{Beatmap, Performance, any::ScoreState};

#[repr(C)]
pub struct ZigchoPpInput {
    pub mode: u8,
    pub lazer: u8,
    pub _padding: [u8; 2],
    pub mods: u32,
    pub max_combo: u32,
    pub large_tick_hits: u32,
    pub small_tick_hits: u32,
    pub slider_end_hits: u32,
    pub n_geki: u32,
    pub n_katu: u32,
    pub n300: u32,
    pub n100: u32,
    pub n50: u32,
    pub misses: u32,
    pub legacy_total_score: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct ZigchoPpOutput {
    pub pp: f64,
    pub stars: f64,
    pub max_combo: u32,
}

fn game_mode(value: u8) -> Option<GameMode> {
    match value {
        0 => Some(GameMode::Osu),
        1 => Some(GameMode::Taiko),
        2 => Some(GameMode::Catch),
        3 => Some(GameMode::Mania),
        _ => None,
    }
}

fn calculate(map_bytes: &[u8], input: &ZigchoPpInput) -> Result<ZigchoPpOutput, ()> {
    let map = Beatmap::from_bytes(map_bytes).map_err(|_| ())?;
    let mode = game_mode(input.mode).ok_or(())?;
    let performance = Performance::new(&map).try_mode(mode).map_err(|_| ())?;
    let state = ScoreState {
        max_combo: input.max_combo,
        osu_large_tick_hits: input.large_tick_hits,
        slider_end_hits: input.slider_end_hits,
        n_geki: input.n_geki,
        n_katu: input.n_katu,
        n300: input.n300,
        n100: input.n100,
        n50: input.n50,
        misses: input.misses,
    };
    let attributes = performance
        .mods(input.mods)
        .lazer(input.lazer != 0)
        .state(state)
        .calculate();
    Ok(ZigchoPpOutput {
        pp: attributes.pp(),
        stars: attributes.stars(),
        max_combo: attributes.max_combo(),
    })
}

/// Returns zero on success. Any non-zero result means the score must not be ranked.
///
/// # Safety
/// `map_ptr` must point to `map_len` readable bytes, and both struct pointers must
/// be non-null and correctly aligned for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zigcho_pp_calculate(
    map_ptr: *const u8,
    map_len: usize,
    input: *const ZigchoPpInput,
    output: *mut ZigchoPpOutput,
) -> i32 {
    if map_ptr.is_null() || map_len == 0 || input.is_null() || output.is_null() {
        return 1;
    }
    let result = catch_unwind(|| {
        // SAFETY: pointers and length are validated by the caller contract above.
        let map_bytes = unsafe { slice::from_raw_parts(map_ptr, map_len) };
        // SAFETY: pointer validity is part of the caller contract above.
        let input = unsafe { &*input };
        calculate(map_bytes, input)
    });
    match result {
        Ok(Ok(value)) => {
            // SAFETY: pointer validity is part of the caller contract above.
            unsafe { output.write(value) };
            0
        }
        Ok(Err(())) => 2,
        Err(_) => 3,
    }
}
