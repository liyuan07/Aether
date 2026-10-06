// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::{BTreeMap, HashSet};
#[repr(C)]
pub struct Reading {
    id: i64,
    watts: f64,
    has_power: u8,
    direction: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Event {
    id: i64,
    token: u64,
    timestamp: f64,
    watts: f64,
    segment: i64,
    removed: u8,
}
#[derive(Clone, Default)]
struct Port {
    points: Vec<Event>,
    segment: i64,
    direction: u8,
    last: Option<f64>,
}
#[derive(Clone, Default)]
pub struct History {
    ports: BTreeMap<i64, Port>,
    next_token: u64,
    events: Vec<Event>,
}
impl History {
    fn prune(&mut self, now: f64) {
        for port in self.ports.values_mut() {
            port.points.retain(|point| {
                if now - point.timestamp > 60.0 {
                    self.events.push(Event {
                        removed: 1,
                        ..*point
                    });
                    false
                } else {
                    true
                }
            });
            // Match the native removal of an empty per-port point array, releasing its capacity.
            if port.points.is_empty() {
                port.points = Vec::new();
            }
        }
    }
    fn append(&mut self, readings: &[Reading], now: f64) {
        self.events.clear();
        self.prune(now);
        let readable: HashSet<i64> = readings
            .iter()
            .filter(|r| r.has_power != 0)
            .map(|r| r.id)
            .collect();
        for (id, port) in &mut self.ports {
            if !readable.contains(id) {
                port.last = None;
            }
        }
        // Preserve input order, including repeated IDs with conflicting readings.
        for reading in readings {
            if reading.has_power == 0 || !reading.watts.is_finite() || reading.watts < 0.0 {
                if let Some(port) = self.ports.get_mut(&reading.id) {
                    port.last = None;
                }
                continue;
            }
            let port = self.ports.entry(reading.id).or_default();
            if port.last.is_some_and(|last| now <= last) {
                continue;
            }
            let continuous = port
                .last
                .is_some_and(|last| now - last <= 2.5 && port.direction == reading.direction);
            if !continuous {
                port.segment += 1;
            }
            // Direction changes within a burst still advance the segment before the point is skipped.
            if port.last.is_some_and(|last| now - last < 0.1) {
                continue;
            }
            self.next_token += 1;
            let event = Event {
                id: reading.id,
                token: self.next_token,
                timestamp: now,
                watts: reading.watts,
                segment: port.segment,
                removed: 0,
            };
            port.points.push(event);
            self.events.push(event);
            port.last = Some(now);
            port.direction = reading.direction;
        }
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_port_history_create() -> *mut History {
    Box::into_raw(Box::default())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_history_clone(core: *const History) -> *mut History {
    unsafe { core.as_ref() }.map_or(std::ptr::null_mut(), |c| Box::into_raw(Box::new(c.clone())))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_history_destroy(core: *mut History) {
    if !core.is_null() {
        drop(unsafe { Box::from_raw(core) });
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_history_break(core: *mut History) {
    if let Some(core) = unsafe { core.as_mut() } {
        for port in core.ports.values_mut() {
            port.last = None;
        }
        core.events.clear();
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_history_append(
    core: *mut History,
    readings: *const Reading,
    count: usize,
    now: f64,
) {
    let rows = if count == 0 {
        &[]
    } else {
        if readings.is_null() {
            return;
        }
        unsafe { std::slice::from_raw_parts(readings, count) }
    };
    if let Some(core) = unsafe { core.as_mut() } {
        core.append(rows, now);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_history_prune(core: *mut History, now: f64) {
    if let Some(core) = unsafe { core.as_mut() } {
        core.events.clear();
        core.prune(now);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_history_events(
    core: *const History,
    output: *mut Event,
    capacity: usize,
) -> usize {
    let Some(core) = (unsafe { core.as_ref() }) else {
        return 0;
    };
    if !output.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(
                core.events.as_ptr(),
                output,
                capacity.min(core.events.len()),
            );
        }
    }
    core.events.len()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_readings_do_not_create_state_and_expired_points_release_capacity() {
        let mut core = History::default();
        let rows: Vec<Reading> = (0..1000)
            .map(|id| Reading {
                id,
                watts: 0.0,
                has_power: 0,
                direction: 0,
            })
            .collect();
        core.append(&rows, 0.0);
        assert!(core.ports.is_empty());
        for timestamp in 0..60 {
            core.append(
                &[Reading {
                    id: 1,
                    watts: 5.0,
                    has_power: 1,
                    direction: 0,
                }],
                timestamp as f64,
            );
        }
        assert_eq!(core.ports[&1].points.len(), 60);
        core.prune(120.0);
        assert_eq!(core.ports[&1].points.capacity(), 0);
        assert_eq!(core.ports[&1].last, Some(59.0));
    }
    #[test]
    fn burst_direction_change_advances_segment_without_extra_point() {
        let mut core = History::default();
        let read = |direction| Reading {
            id: 1,
            watts: 3.0,
            has_power: 1,
            direction,
        };
        core.append(&[read(0)], 100.0);
        core.append(&[read(1)], 100.01);
        assert!(core.events.is_empty());
        core.append(&[read(0)], 100.2);
        assert_eq!(core.events[0].segment, 2);
        core.prune(160.0);
        assert_eq!(core.ports[&1].points.len(), 2);
        core.prune(160.1);
        assert_eq!(core.ports[&1].points.len(), 1);
    }
}
