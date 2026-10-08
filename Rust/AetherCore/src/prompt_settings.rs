// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Synchronous settings transaction policy; credential values never enter this interface.
use std::ffi::c_void;
// Step 0 reads the old key: 0=unchanged, 1=changed, other=failure.
// Steps 1/2/3 write the new key/configuration/old key: 0=success, other=failure.
type Step = unsafe extern "C" fn(*mut c_void, u8) -> u8;
/// Outcomes: 0=saved, 1=empty instruction, 2=old key read failure, 3=key write failure,
/// 4=config failure with key preserved/restored, 5=config failure and rollback failure.
/// # Safety
/// Callback/context are live and exclusively used synchronously; callback must not unwind.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_settings_commit(
    instruction_valid: u8,
    step: Option<Step>,
    context: *mut c_void,
) -> u32 {
    if instruction_valid == 0 {
        return 1;
    }
    let Some(step) = step else { return 2 };
    let changed = match unsafe { step(context, 0) } {
        0 => false,
        1 => true,
        _ => return 2,
    };
    if changed && unsafe { step(context, 1) } != 0 {
        return 3;
    }
    if unsafe { step(context, 2) } == 0 {
        return 0;
    }
    if changed && unsafe { step(context, 3) } != 0 {
        return 5;
    }
    4
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_settings_trim_required(
    save_history: u8,
    count: usize,
    limit: usize,
) -> u8 {
    u8::from(save_history != 0 && count > limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Context {
        replies: [u8; 4],
        calls: Vec<u8>,
    }
    unsafe extern "C" fn step(pointer: *mut c_void, phase: u8) -> u8 {
        let context = unsafe { &mut *pointer.cast::<Context>() };
        context.calls.push(phase);
        context.replies[phase as usize]
    }
    #[test]
    fn callback_order_and_outcomes_match_original_transaction_for_all_failures() {
        for valid in 0..=1 {
            for read in 0..=3 {
                for write in 0..=2 {
                    for config in 0..=2 {
                        for rollback in 0..=2 {
                            // Independent transcription of the original sequential Swift transaction.
                            let mut calls = Vec::new();
                            let expected = if valid == 0 {
                                1
                            } else {
                                calls.push(0);
                                if read > 1 {
                                    2
                                } else if read == 1 && {
                                    calls.push(1);
                                    write != 0
                                } {
                                    3
                                } else {
                                    calls.push(2);
                                    if config == 0 {
                                        0
                                    } else if read == 1 && {
                                        calls.push(3);
                                        rollback != 0
                                    } {
                                        5
                                    } else {
                                        4
                                    }
                                }
                            };
                            let mut context = Context {
                                replies: [read, write, config, rollback],
                                calls: Vec::new(),
                            };
                            let result = unsafe {
                                aether_prompt_settings_commit(
                                    valid,
                                    Some(step),
                                    (&mut context as *mut Context).cast(),
                                )
                            };
                            assert_eq!((result, context.calls), (expected, calls));
                        }
                    }
                }
            }
        }
        assert_eq!(
            unsafe { aether_prompt_settings_commit(0, None, std::ptr::null_mut()) },
            1
        );
        assert_eq!(
            unsafe { aether_prompt_settings_commit(1, None, std::ptr::null_mut()) },
            2
        );
    }
    #[test]
    fn history_trim_uses_current_preference_and_exact_limit() {
        for enabled in [0, 1, 255] {
            for limit in [0, 1, 200, 1000, usize::MAX] {
                for count in [0, 1, 199, 200, 201, 999, 1000, 1001, usize::MAX] {
                    assert_eq!(
                        aether_prompt_settings_trim_required(enabled, count, limit),
                        u8::from(enabled != 0 && count > limit)
                    );
                }
            }
        }
    }
}
