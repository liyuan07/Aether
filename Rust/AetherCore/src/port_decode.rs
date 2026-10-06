// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
#[repr(C)]
pub struct Lane {
    transport: u8,
    on: u8,
}
unsafe fn bytes<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if n == 0 || p.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(p, n) }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_lane(
    t: *const u8,
    tn: usize,
    p: *const u8,
    pn: usize,
) -> Lane {
    let transport = match unsafe { bytes(t, tn) } {
        b"cio" => 1,
        b"displayport" => 2,
        b"usb3" => 3,
        _ => 0,
    };
    Lane {
        transport,
        on: u8::from(unsafe { bytes(p, pn) } == b"on"),
    }
}
#[repr(C)]
pub struct State {
    watts: f64,
    tx: i64,
    rx: i64,
    gbps: i64,
    generation: u8,
    link: u8,
    power: u8,
    energy: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_port_decode(
    tb: u8,
    width: i64,
    speed: i64,
    power: u8,
    watts: i64,
    samples: i64,
    energy: i64,
) -> State {
    let (tx, rx) = match width {
        1 => (1, 1),
        2 => (2, 2),
        4 => (3, 1),
        8 => (1, 3),
        _ => (1, 1),
    };
    let (generation, gbps) = match speed {
        2 => (5, 40),
        8 => (3, 10),
        _ => (4, 20),
    };
    State {
        watts: watts as f64 / 1000.0,
        tx,
        rx,
        gbps,
        generation,
        link: u8::from(tb != 0 && width > 0 && speed > 0),
        power: u8::from(power != 0 && watts > 0),
        energy: u8::from(power != 0 && samples > 0 && energy >= 0),
    }
}
