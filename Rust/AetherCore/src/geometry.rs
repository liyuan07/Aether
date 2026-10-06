// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    fn overlap(self, other: Self) -> f64 {
        let w = (self.x + self.width).min(other.x + other.width) - self.x.max(other.x);
        let h = (self.y + self.height).min(other.y + other.height) - self.y.max(other.y);
        if w < 0.0 || h < 0.0 { 0.0 } else { w * h }
    }
    fn distance(self, other: Self) -> f64 {
        (self.x + self.width / 2.0 - other.x - other.width / 2.0).powi(2)
            + (self.y + self.height / 2.0 - other.y - other.height / 2.0).powi(2)
    }
    fn contains(self, other: Self) -> bool {
        other.x >= self.x
            && other.y >= self.y
            && other.x + other.width <= self.x + self.width
            && other.y + other.height <= self.y + self.height
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_rect_quartz(rect: Rect, top: f64) -> Rect {
    Rect {
        y: top - rect.y - rect.height,
        ..rect
    }
}
/// # Safety
/// Screens must be readable for count rectangles, or null with count zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rect_source(
    window: Rect,
    screens: *const Rect,
    count: usize,
) -> isize {
    if count == 0 || screens.is_null() {
        return -1;
    }
    let screens = unsafe { std::slice::from_raw_parts(screens, count) };
    let mut best = 0;
    for index in 1..count {
        let a = window.overlap(screens[index]);
        let b = window.overlap(screens[best]);
        if a > b || a == b && window.distance(screens[index]) < window.distance(screens[best]) {
            best = index;
        }
    }
    best as isize
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_rect_destination(
    window: Rect,
    source: Rect,
    target: Rect,
    resizable: u8,
) -> Rect {
    let width = if resizable != 0 {
        window.width.min(target.width)
    } else {
        window.width
    };
    let height = if resizable != 0 {
        window.height.min(target.height)
    } else {
        window.height
    };
    fn position(
        value: f64,
        source: f64,
        source_length: f64,
        target: f64,
        target_length: f64,
        window_length: f64,
    ) -> f64 {
        (target + (value - source) / source_length.max(1.0) * target_length)
            .max(target)
            .min(target + (target_length - window_length).max(0.0))
    }
    Rect {
        x: position(
            window.x,
            source.x,
            source.width,
            target.x,
            target.width,
            width,
        ),
        y: position(
            window.y,
            source.y,
            source.height,
            target.y,
            target.height,
            height,
        ),
        width,
        height,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_rect_approximately_equal(a: Rect, b: Rect) -> u8 {
    u8::from(
        (a.x - b.x).abs() <= 3.0
            && (a.y - b.y).abs() <= 3.0
            && (a.width - b.width).abs() <= 3.0
            && (a.height - b.height).abs() <= 3.0,
    )
}
/// # Safety
/// Occupied must be readable for count rectangles, or null with count zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rect_avoid_overlap(
    frame: Rect,
    occupied: *const Rect,
    count: usize,
    bounds: Rect,
) -> Rect {
    if count == 0 || occupied.is_null() {
        return frame;
    }
    let occupied = unsafe { std::slice::from_raw_parts(occupied, count) };
    let collides = |candidate: Rect| {
        occupied
            .iter()
            .any(|r| (r.x - candidate.x).abs() < 20.0 && (r.y - candidate.y).abs() < 20.0)
    };
    if !collides(frame) {
        return frame;
    }
    for distance in 1..=12 {
        for (dx, dy) in [(1.0, 1.0), (-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0)] {
            let offset = f64::from(distance * 28);
            let candidate = Rect {
                x: frame.x + dx * offset,
                y: frame.y + dy * offset,
                ..frame
            };
            if bounds.contains(candidate) && !collides(candidate) {
                return candidate;
            }
        }
    }
    frame
}
