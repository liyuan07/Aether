// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
pub(crate) const VERSION: i64 = 9;
pub(crate) const ARCHIVE_VERSION: i64 = 2;
pub(crate) const ARCHIVE_DEFAULT: i64 = 1;
#[repr(C)]
pub struct Defaults {
    version: i64,
    archive_version: i64,
    archive_default: i64,
    stored_default: i64,
    hold: f64,
    launch: u8,
    block: u8,
    show: u8,
    restore: u8,
}
#[repr(C)]
pub struct General {
    launch: u8,
    block: u8,
    show: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_defaults() -> Defaults {
    Defaults {
        version: VERSION,
        archive_version: ARCHIVE_VERSION,
        archive_default: ARCHIVE_DEFAULT,
        stored_default: 1,
        hold: 0.5,
        launch: 0,
        block: 0,
        show: 1,
        restore: 1,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_hold(value: f64) -> f64 {
    if value < 0.3 {
        0.3
    } else if value > 1.5 {
        1.5
    } else {
        value
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_window(behavior: u8, restore: u8) -> u8 {
    match behavior {
        1 => 1,
        2 => 3,
        3 => 0,
        _ => 1 | (u8::from(restore != 0) << 1),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_legacy_launch(app_key: u8) -> u8 {
    u8::from(app_key == 0)
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_migrate(
    mut current: General,
    app_key: u8,
    launch: u8,
    has_launch: u8,
    block: u8,
    has_block: u8,
) -> General {
    if app_key == 0 && has_launch != 0 {
        current.launch = launch;
    }
    if has_block != 0 {
        current.block = block;
    }
    current
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_source(current_exists: u8, legacy_exists: u8) -> i8 {
    if current_exists != 0 {
        0
    } else if legacy_exists != 0 {
        1
    } else {
        -1
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_preferences_should_write(persist: u8, legacy: u8, version: i64) -> u8 {
    u8::from(persist != 0 && (legacy != 0 || version < VERSION))
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_physical_input_switch(code: u16) -> u8 {
    u8::from(matches!(code, 57 | 63 | 102 | 104))
}
const LETTER_KEYS: [u16; 26] = [
    0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
];
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_letter(code: u16) -> u8 {
    LETTER_KEYS
        .iter()
        .position(|&key| key == code)
        .map_or(0, |i| b'A' + i as u8)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_application_letter_key(p: *const u8, count: usize) -> i32 {
    if count != 1 || p.is_null() {
        return -1;
    }
    let letter = unsafe { *p };
    if !letter.is_ascii_uppercase() {
        return -1;
    }
    i32::from(LETTER_KEYS[(letter - b'A') as usize])
}
