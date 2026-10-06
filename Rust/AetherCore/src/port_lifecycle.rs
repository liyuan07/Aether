// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::BTreeMap;
#[derive(Clone)]
struct Episode {
    phase: u8,
    started: f64,
    last: f64,
}
#[derive(Clone, Default)]
pub struct Lifecycle {
    episodes: BTreeMap<i64, Episode>,
}
impl Lifecycle {
    fn handle(&mut self, signal: u8, id: i64, now: f64) {
        if signal == 3 {
            self.episodes.remove(&id);
            return;
        }
        if signal > 3 {
            return;
        }
        let episode = self.episodes.entry(id).or_insert(Episode {
            phase: if signal == 0 { 0 } else { 1 },
            started: now,
            last: now,
        });
        if signal != 0 {
            episode.phase = 1;
        }
        episode.last = now;
    }
    fn reconcile(&mut self, disconnected: &[i64], resolved: &[i64], now: f64) {
        for id in disconnected.iter().chain(resolved) {
            self.episodes.remove(id);
        }
        self.episodes.retain(|_, episode| {
            if now < episode.last || now < episode.started {
                episode.started = now;
                episode.last = now;
                return true;
            }
            !(now - episode.last >= 3.0 || now - episode.started >= 6.0)
        });
    }
}
#[repr(C)]
pub struct Phase {
    port_id: i64,
    phase: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_port_lifecycle_create() -> *mut Lifecycle {
    Box::into_raw(Box::default())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_lifecycle_clone(core: *const Lifecycle) -> *mut Lifecycle {
    unsafe { core.as_ref() }.map_or(std::ptr::null_mut(), |c| Box::into_raw(Box::new(c.clone())))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_lifecycle_destroy(core: *mut Lifecycle) {
    if !core.is_null() {
        drop(unsafe { Box::from_raw(core) });
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_lifecycle_handle(
    core: *mut Lifecycle,
    signal: u8,
    id: i64,
    now: f64,
) {
    if let Some(core) = unsafe { core.as_mut() } {
        core.handle(signal, id, now);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_lifecycle_reconcile(
    core: *mut Lifecycle,
    disconnected: *const i64,
    disconnected_count: usize,
    resolved: *const i64,
    resolved_count: usize,
    now: f64,
) {
    // Empty arrays may have a null base pointer; nonempty spans are borrowed for this call only.
    let disconnected = if disconnected_count == 0 {
        &[]
    } else {
        if disconnected.is_null() {
            return;
        }
        unsafe { std::slice::from_raw_parts(disconnected, disconnected_count) }
    };
    let resolved = if resolved_count == 0 {
        &[]
    } else {
        if resolved.is_null() {
            return;
        }
        unsafe { std::slice::from_raw_parts(resolved, resolved_count) }
    };
    if let Some(core) = unsafe { core.as_mut() } {
        core.reconcile(disconnected, resolved, now);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_lifecycle_phases(
    core: *const Lifecycle,
    output: *mut Phase,
    capacity: usize,
) -> usize {
    let Some(core) = (unsafe { core.as_ref() }) else {
        return 0;
    };
    if !output.is_null() {
        for (i, (&port_id, episode)) in core.episodes.iter().take(capacity).enumerate() {
            unsafe {
                output.add(i).write(Phase {
                    port_id,
                    phase: episode.phase,
                });
            }
        }
    }
    core.episodes.len()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ceiling_and_backward_clock_preserve_episode_bounds() {
        let mut core = Lifecycle::default();
        core.handle(1, -1, 100.0);
        core.handle(0, -1, 102.0);
        assert_eq!(core.episodes[&-1].phase, 1);
        core.reconcile(&[], &[], 90.0);
        assert_eq!(core.episodes[&-1].started, 90.0);
        core.handle(1, -1, 95.0);
        core.reconcile(&[], &[], 96.0);
        assert!(core.episodes.is_empty());
    }
}
