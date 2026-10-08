// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! One-way migration sequencing. Native effects handle files, property lists and preference APIs.
use std::ffi::c_void;
#[repr(C)]
pub struct EffectResult {
    pub value: usize,
    pub failed: u8,
}
type Effect = unsafe extern "C" fn(*mut c_void, u8, usize) -> EffectResult;
/// # Safety
/// Effect/context are valid for this synchronous call and never retained. Native errors abort
/// immediately; the caller owns staging cleanup. No destination is published before validation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_data_migration_run(
    effect: Option<Effect>,
    context: *mut c_void,
) -> u8 {
    let Some(effect) = effect else {
        return 1;
    };
    let invoke = |step, index| {
        let result = unsafe { effect(context, step, index) };
        if result.failed == 0 {
            Ok(result.value)
        } else {
            Err(())
        }
    };
    let run = || -> Result<(), ()> {
        if invoke(0, 0)? == 1 {
            return Ok(());
        } // Completed receipt: no further effects.
        if invoke(1, 0)? == 1 {
            invoke(9, 0)?; // Copied receipt: validate destination before retrying preferences.
        } else {
            invoke(2, 0)?; // Refuse an existing destination without a resumable receipt.
            invoke(3, 0)?;
            let count = invoke(4, 0)?;
            for index in 0..count {
                invoke(5, index)?;
            }
            invoke(6, 0)?;
            invoke(7, 0)?;
            invoke(8, 0)?;
        }
        let count = invoke(10, 0)?; // Receipt sources, not current invocation sources.
        for index in 0..count {
            invoke(11, index)?;
        }
        invoke(12, 0)?;
        Ok(())
    };
    u8::from(run().is_err())
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Effects {
        phase: u8,
        fail: Option<u8>,
        calls: Vec<(u8, usize)>,
    }
    unsafe extern "C" fn effect(pointer: *mut c_void, step: u8, index: usize) -> EffectResult {
        let state = unsafe { &mut *pointer.cast::<Effects>() };
        state.calls.push((step, index));
        EffectResult {
            failed: u8::from(state.fail == Some(step)),
            value: match step {
                0 => usize::from(state.phase == 1),
                1 => usize::from(state.phase == 2),
                4 | 10 => 2,
                _ => 0,
            },
        }
    }
    #[test]
    fn first_run_resume_complete_and_failure_stop_in_order() {
        for (phase, expected) in [
            (0, vec![0, 1, 2, 3, 4, 5, 5, 6, 7, 8, 10, 11, 11, 12]),
            (1, vec![0]),
            (2, vec![0, 1, 9, 10, 11, 11, 12]),
        ] {
            let mut state = Effects {
                phase,
                fail: None,
                calls: vec![],
            };
            assert_eq!(
                unsafe {
                    aether_data_migration_run(Some(effect), (&mut state as *mut Effects).cast())
                },
                0
            );
            assert_eq!(
                state.calls.iter().map(|v| v.0).collect::<Vec<_>>(),
                expected
            );
            for fail in expected {
                let mut state = Effects {
                    phase,
                    fail: Some(fail),
                    calls: vec![],
                };
                assert_eq!(
                    unsafe {
                        aether_data_migration_run(Some(effect), (&mut state as *mut Effects).cast())
                    },
                    1
                );
                assert_eq!(state.calls.last().unwrap().0, fail);
            }
        }
        assert_eq!(
            unsafe { aether_data_migration_run(None, std::ptr::null_mut()) },
            1
        );
    }
}

// Optional preference codes: 0 absent, 1 false, 2 true.
#[unsafe(no_mangle)]
pub extern "C" fn aether_migration_login(
    existing: u8,
    timer: u8,
    clipboard: u8,
    shortcuts: u8,
) -> u8 {
    if existing != 0 {
        return u8::from(existing == 2);
    }
    let choices = [timer, clipboard, shortcuts];
    u8::from(choices.iter().all(|&v| v == 0) || choices.contains(&2))
}
// Destination codes: 0 app, 1 clipboard, 2 shortcuts.
#[unsafe(no_mangle)]
pub extern "C" fn aether_migration_destination(clipboard: u8, shortcuts: u8) -> u8 {
    if clipboard != 0 {
        1
    } else if shortcuts != 0 {
        2
    } else {
        0
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_migration_preference(
    general: u8,
    login_key: u8,
    permission_key: u8,
) -> u8 {
    u8::from(permission_key == 0 && (login_key == 0 || general != 0))
}
