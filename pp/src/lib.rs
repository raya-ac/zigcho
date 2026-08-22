use std::{panic::catch_unwind, slice};

use akatsuki_pp::{
    Beatmap as AkatsukiBeatmap, Performance as AkatsukiPerformance,
    any::ScoreState as AkatsukiScoreState,
};
use rosu_map::section::general::GameMode as AkatsukiGameMode;
use rosu_mods::{GameMod, GameModSimple, GameMode, GameMods, serde::GameModSeed};
use rosu_pp_lazer::{
    Beatmap as LazerBeatmap, Performance as LazerPerformance, any::ScoreState as LazerScoreState,
    model::mode::GameMode as LazerGameMode,
};
use rosu_pp_stable::{
    Beatmap as StableBeatmap, Performance as StablePerformance,
    any::ScoreState as StableScoreState, model::mode::GameMode as StableGameMode,
};

const RELAX: u32 = 1 << 7;
const AUTOPILOT: u32 = 1 << 13;

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

fn passed_objects(input: &ZigchoPpInput) -> Option<u32> {
    let total = match input.mode {
        0 => input
            .n300
            .checked_add(input.n100)?
            .checked_add(input.n50)?
            .checked_add(input.misses)?,
        1 => input
            .n300
            .checked_add(input.n100)?
            .checked_add(input.misses)?,
        2 => input
            .n300
            .checked_add(input.n100)?
            .checked_add(input.n50)?
            .checked_add(input.n_katu)?
            .checked_add(input.misses)?,
        3 => input
            .n_geki
            .checked_add(input.n300)?
            .checked_add(input.n_katu)?
            .checked_add(input.n100)?
            .checked_add(input.n50)?
            .checked_add(input.misses)?,
        _ => return None,
    };

    (total > 0).then_some(total)
}

fn stable_mode(value: u8) -> Option<StableGameMode> {
    match value {
        0 => Some(StableGameMode::Osu),
        1 => Some(StableGameMode::Taiko),
        2 => Some(StableGameMode::Catch),
        3 => Some(StableGameMode::Mania),
        _ => None,
    }
}

fn lazer_mode(value: u8) -> Option<LazerGameMode> {
    match value {
        0 => Some(LazerGameMode::Osu),
        1 => Some(LazerGameMode::Taiko),
        2 => Some(LazerGameMode::Catch),
        3 => Some(LazerGameMode::Mania),
        _ => None,
    }
}

fn akatsuki_mode(value: u8) -> Option<AkatsukiGameMode> {
    match value {
        0 => Some(AkatsukiGameMode::Osu),
        1 => Some(AkatsukiGameMode::Taiko),
        2 => Some(AkatsukiGameMode::Catch),
        3 => Some(AkatsukiGameMode::Mania),
        _ => None,
    }
}

fn calculate_stable_vanilla(
    map_bytes: &[u8],
    input: &ZigchoPpInput,
    passed: u32,
) -> Result<ZigchoPpOutput, ()> {
    let map = StableBeatmap::from_bytes(map_bytes).map_err(|_| ())?;
    let mode = stable_mode(input.mode).ok_or(())?;
    let state = StableScoreState {
        max_combo: input.max_combo,
        osu_large_tick_hits: input.large_tick_hits,
        osu_small_tick_hits: input.small_tick_hits,
        slider_end_hits: input.slider_end_hits,
        n_geki: input.n_geki,
        n_katu: input.n_katu,
        n300: input.n300,
        n100: input.n100,
        n50: input.n50,
        misses: input.misses,
        legacy_total_score: (input.legacy_total_score > 0).then_some(input.legacy_total_score),
    };
    let attributes = StablePerformance::new(&map)
        .try_mode(mode)
        .map_err(|_| ())?
        .mods(input.mods)
        .lazer(false)
        .passed_objects(passed)
        .state(state)
        .calculate();

    Ok(ZigchoPpOutput {
        pp: attributes.pp(),
        stars: attributes.stars(),
        max_combo: attributes.max_combo(),
    })
}

fn calculate_lazer_vanilla(
    map_bytes: &[u8],
    input: &ZigchoPpInput,
    passed: u32,
    mods: GameMods,
) -> Result<ZigchoPpOutput, ()> {
    let map = LazerBeatmap::from_bytes(map_bytes).map_err(|_| ())?;
    let mode = lazer_mode(input.mode).ok_or(())?;
    let state = LazerScoreState {
        max_combo: input.max_combo,
        osu_large_tick_hits: input.large_tick_hits,
        osu_small_tick_hits: input.small_tick_hits,
        slider_end_hits: input.slider_end_hits,
        n_geki: input.n_geki,
        n_katu: input.n_katu,
        n300: input.n300,
        n100: input.n100,
        n50: input.n50,
        misses: input.misses,
        legacy_total_score: None,
    };
    let attributes = LazerPerformance::new(&map)
        .try_mode(mode)
        .map_err(|_| ())?
        .mods(mods)
        .lazer(true)
        .passed_objects(passed)
        .state(state)
        .calculate();

    Ok(ZigchoPpOutput {
        pp: attributes.pp(),
        stars: attributes.stars(),
        max_combo: attributes.max_combo(),
    })
}

fn calculate_custom(
    map_bytes: &[u8],
    input: &ZigchoPpInput,
    passed: u32,
) -> Result<ZigchoPpOutput, ()> {
    let map = AkatsukiBeatmap::from_bytes(map_bytes).map_err(|_| ())?;
    let mode = akatsuki_mode(input.mode).ok_or(())?;
    let state = AkatsukiScoreState {
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
    let attributes = AkatsukiPerformance::new(&map)
        .try_mode(mode)
        .map_err(|_| ())?
        .mods(input.mods)
        .lazer(input.lazer != 0)
        .passed_objects(passed)
        .state(state)
        .calculate();

    Ok(ZigchoPpOutput {
        pp: attributes.pp(),
        stars: attributes.stars(),
        max_combo: attributes.max_combo(),
    })
}

fn calculate(map_bytes: &[u8], input: &ZigchoPpInput) -> Result<ZigchoPpOutput, ()> {
    let passed = passed_objects(input).ok_or(())?;
    if input.mods & (RELAX | AUTOPILOT) != 0 {
        calculate_custom(map_bytes, input, passed)
    } else {
        calculate_stable_vanilla(map_bytes, input, passed)
    }
}

fn parse_lazer_mods(bytes: &[u8], mode: u8) -> Result<GameMods, ()> {
    let mode = match mode {
        0 => GameMode::Osu,
        1 => GameMode::Taiko,
        2 => GameMode::Catch,
        3 => GameMode::Mania,
        _ => return Err(()),
    };
    let simple: Vec<GameModSimple> = serde_json::from_slice(bytes).map_err(|_| ())?;
    let mut mods = GameMods::new();
    for item in simple {
        let gamemod = item
            .try_as_mod(GameModSeed::Mode {
                mode,
                deny_unknown_fields: true,
            })
            .map_err(|_| ())?;
        if matches!(
            gamemod,
            GameMod::UnknownOsu(_)
                | GameMod::UnknownTaiko(_)
                | GameMod::UnknownCatch(_)
                | GameMod::UnknownMania(_)
        ) {
            return Err(());
        }
        mods.insert(gamemod);
    }
    Ok(mods)
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
        let map_bytes = unsafe { slice::from_raw_parts(map_ptr, map_len) };
        let input = unsafe { &*input };
        calculate(map_bytes, input)
    });

    match result {
        Ok(Ok(value)) => {
            unsafe { output.write(value) };
            0
        }
        Ok(Err(())) => 2,
        Err(_) => 3,
    }
}

/// Lazer counterpart to `zigcho_pp_calculate`. The mod array is the exact
/// object/settings JSON sent by the client so modern rate and difficulty
/// settings are not collapsed into legacy bitflags.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zigcho_lazer_pp_calculate(
    map_ptr: *const u8,
    map_len: usize,
    mods_ptr: *const u8,
    mods_len: usize,
    input: *const ZigchoPpInput,
    output: *mut ZigchoPpOutput,
) -> i32 {
    if map_ptr.is_null()
        || map_len == 0
        || mods_ptr.is_null()
        || mods_len == 0
        || input.is_null()
        || output.is_null()
    {
        return 1;
    }

    let result = catch_unwind(|| {
        let map_bytes = unsafe { slice::from_raw_parts(map_ptr, map_len) };
        let mods_bytes = unsafe { slice::from_raw_parts(mods_ptr, mods_len) };
        let input = unsafe { &*input };
        let passed = passed_objects(input).ok_or(())?;
        let mods = parse_lazer_mods(mods_bytes, input.mode)?;
        calculate_lazer_vanilla(map_bytes, input, passed, mods)
    });

    match result {
        Ok(Ok(value)) => {
            unsafe { output.write(value) };
            0
        }
        Ok(Err(())) => 2,
        Err(_) => 3,
    }
}
