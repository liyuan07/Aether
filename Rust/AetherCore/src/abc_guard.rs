// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
#[repr(C)]
pub struct State {
    pressed: f64,
    has_pressed: u8,
    manual: u8,
    decision: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_abc_decide(
    mut s: State,
    block: u8,
    abc: u8,
    observe: u8,
    now: f64,
    duration: f64,
) -> State {
    s.decision = 0;
    if abc == 0 {
        s.manual = 0;
        s.has_pressed = 0;
    } else if block != 0 && observe != 0 {
        if s.manual != 0 {
            s.decision = 1;
        } else if s.has_pressed != 0 && now >= s.pressed && now - s.pressed <= duration {
            s.has_pressed = 0;
            s.manual = 1;
            s.decision = 1;
        } else {
            s.has_pressed = 0;
            s.decision = 2;
        }
    }
    s
}
