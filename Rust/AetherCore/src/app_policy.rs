// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! App routing and application launch decisions; native adapters execute platform effects.
#[repr(C)]
pub struct RoutePlan {
    presentation: u8,
    capture_targets: u8,
    hide_menu: u8,
    hide_clipboard: u8,
}
/// Route: 0 overview,1 clipboard,2 prompt,3 settings,4 dismiss.
/// Presentation: 0 none,1 overview,2 clipboard,3 prompt,4 requested settings,5 general settings.
#[unsafe(no_mangle)]
pub extern "C" fn aether_app_route_plan(route: u8, ready: u8) -> RoutePlan {
    let ready = ready != 0;
    let (presentation, capture_targets, hide_menu, hide_clipboard) = match route {
        0 => (1, false, false, false),
        1 if ready => (2, true, true, false),
        2 if ready => (3, false, false, true),
        1 | 2 => (5, false, false, false),
        3 => (4, ready, true, false),
        4 => (0, false, true, ready),
        _ => (0, false, false, false),
    };
    RoutePlan {
        presentation,
        capture_targets: u8::from(capture_targets),
        hide_menu: u8::from(hide_menu),
        hide_clipboard: u8::from(hide_clipboard),
    }
}
/// Native String equality supplies match masks, preserving canonical Unicode equivalence.
/// A present identifier always takes precedence, even when unknown or empty.
#[unsafe(no_mangle)]
pub extern "C" fn aether_legacy_route(
    identifier_present: u8,
    identifier_matches: u8,
    path_matches: u8,
) -> u8 {
    let matches = if identifier_present != 0 {
        identifier_matches
    } else {
        path_matches
    };
    (0..3)
        .find(|&index| matches & (1 << index) != 0)
        .map_or(0, |index| index + 1)
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct LaunchFacts {
    running: u8,
    has_url: u8,
    has_display: u8,
    new_window: u8,
    has_windows: u8,
    read_failed: u8,
    timed_out: u8,
    display_disconnected: u8,
}
#[repr(C)]
pub struct LaunchPlan {
    activate_now: u8,
    open_existing_background: u8,
    launch: u8,
    reopen_existing: u8,
    request_new_window: u8,
    followup_prepare: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_application_launch_plan(facts: LaunchFacts) -> LaunchPlan {
    let existing = facts.new_window == 0;
    let report_known =
        facts.read_failed == 0 && facts.timed_out == 0 && facts.display_disconnected == 0;
    LaunchPlan {
        activate_now: u8::from(facts.running != 0 && existing),
        open_existing_background: u8::from(
            facts.running != 0 && existing && facts.has_display == 0 && facts.has_url != 0,
        ),
        launch: u8::from(facts.running == 0 && facts.has_url != 0),
        reopen_existing: u8::from(
            existing
                && facts.has_display != 0
                && facts.has_url != 0
                && facts.has_windows == 0
                && report_known,
        ),
        request_new_window: u8::from(!existing),
        followup_prepare: u8::from(facts.has_display != 0 && report_known),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routes_preserve_readiness_and_identifier_priority() {
        assert_eq!(aether_app_route_plan(1, 0).presentation, 5);
        assert_eq!(aether_app_route_plan(2, 0).presentation, 5);
        let clipboard = aether_app_route_plan(1, 1);
        assert_eq!(
            (
                clipboard.presentation,
                clipboard.capture_targets,
                clipboard.hide_menu,
                clipboard.hide_clipboard
            ),
            (2, 1, 1, 0)
        );
        let prompt = aether_app_route_plan(2, 1);
        assert_eq!((prompt.presentation, prompt.hide_clipboard), (3, 1));
        assert_eq!(aether_app_route_plan(3, 0).capture_targets, 0);
        assert_eq!(aether_app_route_plan(3, 1).capture_targets, 1);
        assert_eq!(aether_app_route_plan(4, 0).hide_clipboard, 0);
        assert_eq!(aether_app_route_plan(4, 1).hide_clipboard, 1);
        assert_eq!(aether_legacy_route(1, 0, 7), 0);
        assert_eq!(aether_legacy_route(0, 7, 4), 3);
        assert_eq!(aether_legacy_route(1, 3, 4), 1);
    }
    #[test]
    fn application_reopen_requires_known_empty_inventory_and_safe_followup() {
        let mut facts = LaunchFacts {
            running: 1,
            has_url: 1,
            has_display: 1,
            new_window: 0,
            has_windows: 0,
            read_failed: 0,
            timed_out: 0,
            display_disconnected: 0,
        };
        assert_eq!(
            aether_application_launch_plan(LaunchFacts {
                has_display: 0,
                ..facts
            })
            .open_existing_background,
            1
        );
        assert_eq!(
            aether_application_launch_plan(LaunchFacts {
                read_failed: 1,
                ..facts
            })
            .reopen_existing,
            0
        );
        assert_eq!(
            aether_application_launch_plan(LaunchFacts {
                timed_out: 1,
                ..facts
            })
            .followup_prepare,
            0
        );
        let plan = aether_application_launch_plan(LaunchFacts { ..facts });
        assert_eq!((plan.activate_now, plan.reopen_existing), (1, 1));
        facts.new_window = 1;
        let plan = aether_application_launch_plan(facts);
        assert_eq!(
            (
                plan.activate_now,
                plan.reopen_existing,
                plan.request_new_window
            ),
            (0, 0, 1)
        );
    }
}

#[repr(C)]
pub struct DesktopShortcut {
    enabled: u8,
    key: u16,
    flags: u64,
}
/// Native preference decoding supplies the enabled/parameter facts and platform's Fn flag.
#[unsafe(no_mangle)]
pub extern "C" fn aether_desktop_shortcut_plan(
    record_present: u8,
    explicitly_disabled: u8,
    parameters_valid: u8,
    key: i64,
    flags: i64,
    default_fn: u64,
) -> DesktopShortcut {
    if record_present != 0 && explicitly_disabled != 0 {
        return DesktopShortcut {
            enabled: 0,
            key: 0,
            flags: 0,
        };
    }
    if record_present != 0
        && parameters_valid != 0
        && (0..=u16::MAX as i64).contains(&key)
        && flags >= 0
    {
        DesktopShortcut {
            enabled: 1,
            key: key as u16,
            flags: flags as u64,
        }
    } else {
        DesktopShortcut {
            enabled: 1,
            key: 103,
            flags: default_fn,
        }
    }
}
#[cfg(test)]
mod desktop_tests {
    use super::*;
    #[test]
    fn desktop_shortcut_preserves_disabled_and_fallback_rules() {
        assert_eq!(aether_desktop_shortcut_plan(1, 1, 1, 42, 256, 8).enabled, 0);
        let valid = aether_desktop_shortcut_plan(1, 0, 1, 42, 256, 8);
        assert_eq!((valid.key, valid.flags), (42, 256));
        for (present, parameters, key, flags) in [
            (0, 1, 42, 256),
            (1, 0, 42, 256),
            (1, 1, -1, 256),
            (1, 1, 65536, 256),
            (1, 1, 42, -1),
        ] {
            let fallback = aether_desktop_shortcut_plan(present, 0, parameters, key, flags, 8);
            assert_eq!(
                (fallback.enabled, fallback.key, fallback.flags),
                (1, 103, 8)
            );
        }
    }
}
