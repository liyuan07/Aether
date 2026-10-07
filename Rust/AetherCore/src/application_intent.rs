// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Value states only. Swift owns locks, monotonic clock input and platform objects.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Intent {
    pub revision: u64,
    pub current: u8,
    pub cancel: u8,
    pub clear: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_intent_update(
    mut state: Intent,
    event: u8,
    accepted: u8,
) -> Intent {
    state.cancel = 0;
    state.clear = 0;
    match event {
        0 => {
            state.cancel = state.current;
            state.current = 1;
        }
        1 => {
            state.revision = state.revision.wrapping_add(1);
            state.cancel = state.current;
            state.current = 0;
            state.clear = 1;
        }
        2 if state.current != 0 && accepted == 0 => {
            state.revision = state.revision.wrapping_add(1);
            state.cancel = 1;
            state.current = 0;
            state.clear = 1;
        }
        _ => {}
    }
    state
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Deadline {
    pub deadline: f64,
    pub cancelled: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_action_deadline_create(now: f64, duration: f64) -> Deadline {
    Deadline {
        deadline: now + duration,
        cancelled: 0,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_action_deadline_cancel(mut state: Deadline) -> Deadline {
    state.cancelled = 1;
    state
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_action_deadline_active(state: Deadline, now: f64) -> u8 {
    u8::from(state.cancelled == 0 && now < state.deadline)
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Action {
    pub timeout: Deadline,
    pub source: i32,
    pub target: i32,
    pub source_present: u8,
    pub target_present: u8,
    pub target_activated: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_action_create(
    source: i32,
    source_present: u8,
    target: i32,
    target_present: u8,
    now: f64,
) -> Action {
    Action {
        timeout: aether_action_deadline_create(now, 15.0),
        source,
        target,
        source_present,
        target_present,
        target_activated: u8::from(source_present != 0 && target_present != 0 && target == source),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_action_target(mut state: Action, target: i32) -> Action {
    state.target = target;
    state.target_present = 1;
    state
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_action_cancel(mut state: Action) -> Action {
    state.timeout = aether_action_deadline_cancel(state.timeout);
    state
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_action_active(state: Action, now: f64) -> u8 {
    aether_action_deadline_active(state.timeout, now)
}
#[repr(C)]
pub struct Activation {
    pub state: Action,
    pub accepted: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_action_activate(mut state: Action, pid: i32) -> Activation {
    let accepted = if state.target_present != 0 && pid == state.target {
        state.target_activated = 1;
        true
    } else {
        state.target_activated == 0 && state.source_present != 0 && pid == state.source
    };
    Activation {
        state,
        accepted: u8::from(accepted),
    }
}
/// Native adapter separately samples active state and then locks target matching,
/// preserving the original lock boundaries rather than introducing a nested lock.
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_action_matches(
    state: Action,
    pid: i32,
    front: i32,
    front_present: u8,
) -> u8 {
    u8::from(state.target_present != 0 && state.target == pid && front_present != 0 && front == pid)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn intent_events_and_revision_wrap() {
        let initial = Intent {
            revision: u64::MAX,
            ..Intent::default()
        };
        let begun = aether_application_intent_update(initial, 0, 0);
        assert_eq!(
            (begun.current, begun.cancel, begun.revision),
            (1, 0, u64::MAX)
        );
        let replacement = aether_application_intent_update(begun, 0, 0);
        assert_eq!((replacement.current, replacement.cancel), (1, 1));
        let accepted = aether_application_intent_update(replacement, 2, 1);
        assert_eq!(
            (accepted.current, accepted.cancel, accepted.clear),
            (1, 0, 0)
        );
        let rejected = aether_application_intent_update(accepted, 2, 0);
        assert_eq!(
            (
                rejected.current,
                rejected.cancel,
                rejected.clear,
                rejected.revision
            ),
            (0, 1, 1, 0)
        );
        let absent = aether_application_intent_update(rejected, 2, 0);
        assert_eq!(absent.revision, 0);
        assert_eq!(aether_application_intent_update(absent, 1, 0).revision, 1);
    }
    #[test]
    fn activation_latches_and_late_target_never_revives_cancelled_action() {
        let state = aether_application_action_create(1, 1, 2, 1, 0.0);
        assert_eq!(aether_application_action_activate(state, 1).accepted, 1);
        let activation = aether_application_action_activate(state, 2);
        assert_eq!(activation.accepted, 1);
        assert_eq!(
            aether_application_action_activate(activation.state, 1).accepted,
            0
        );
        let changed = aether_application_action_target(activation.state, 3);
        assert_eq!(aether_application_action_activate(changed, 1).accepted, 0);
        let cancelled =
            aether_application_action_target(aether_application_action_cancel(changed), 4);
        assert_eq!(aether_application_action_active(cancelled, 1.0), 0);
        assert_eq!(aether_application_action_matches(cancelled, 4, 4, 1), 1); // matches alone does not imply active
        assert_eq!(aether_application_action_matches(cancelled, 4, 4, 0), 0);
        let nil = aether_application_action_create(0, 0, 0, 0, 0.0);
        assert_eq!(aether_application_action_activate(nil, 0).accepted, 0);
    }
    #[test]
    fn exact_deadline_and_ieee_values_keep_native_comparison_semantics() {
        let state = aether_action_deadline_create(10.0, 0.35);
        assert_eq!(aether_action_deadline_active(state, state.deadline), 0);
        assert_eq!(
            aether_action_deadline_active(state, state.deadline - 0.001),
            1
        );
        assert_eq!(
            aether_action_deadline_active(aether_action_deadline_cancel(state), 0.0),
            0
        );
        for now in [
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            -0.0,
            0.0,
            f64::MAX,
            -f64::MAX,
        ] {
            for duration in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 15.0, -1.0, 0.0] {
                let state = aether_action_deadline_create(now, duration);
                assert_eq!(
                    aether_action_deadline_active(state, 0.0),
                    u8::from(0.0 < now + duration)
                );
            }
        }
    }
}
