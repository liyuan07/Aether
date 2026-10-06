// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::{HashMap, HashSet};
#[repr(C)]
pub struct Contract {
    key: u64,
    power: i64,
    voltage: i64,
    current: i64,
    outgoing_label: u8,
}
#[repr(C)]
pub struct Port {
    key: u64,
    id: i64,
    usb: u8,
    connected: u8,
    has_power: u8,
    incoming: u8,
}
#[repr(C)]
pub struct Node {
    id: i64,
    usb: u8,
    winning: u8,
}
#[repr(C)]
pub struct PowerOut {
    key: u64,
    watts: f64,
}
#[repr(C)]
pub struct Result {
    index: i64,
    port_id: i64,
}
fn consistent(c: &Contract) -> bool {
    if c.power <= 0 || c.current <= 0 {
        return false;
    }
    let product = c.voltage as f64 * c.current as f64 / 1000.0;
    let stated = c.power as f64;
    (product - stated).abs() / stated <= 0.02
}
fn plausible(c: &Contract, out: Option<f64>) -> bool {
    c.power > 0
        && c.voltage >= 4500
        && consistent(c)
        && c.outgoing_label == 0
        && !out.is_some_and(|w| w > 0.5)
}
fn enabled_for_resolution(enabled: u8, external: u8) -> bool {
    enabled != 0 && external != 0
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_smc_resolution_enabled(enabled: u8, external: u8) -> u8 {
    u8::from(enabled_for_resolution(enabled, external))
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_smc_contract_consistent(power: i64, voltage: i64, current: i64) -> u8 {
    u8::from(consistent(&Contract {
        key: 0,
        power,
        voltage,
        current,
        outgoing_label: 0,
    }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_smc_contract_plausible(
    c: *const Contract,
    has_out: u8,
    watts: f64,
) -> u8 {
    unsafe { c.as_ref() }.map_or(0, |c| {
        u8::from(plausible(c, (has_out != 0).then_some(watts)))
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_smc_sourcing_power(watts: f64, present: u8) -> u8 {
    u8::from(present != 0 && watts > 0.5)
}
unsafe fn span<'a, T>(p: *const T, n: usize) -> Option<&'a [T]> {
    if n == 0 {
        Some(&[])
    } else if p.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(p, n) })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_smc_describes_charging(nodes: *const Node, count: usize) -> u8 {
    unsafe { span(nodes, count) }.map_or(0, |nodes| u8::from(nodes.iter().any(|n| n.winning != 0)))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_smc_contract_select(
    contracts: *const Contract,
    contract_count: usize,
    ports: *const Port,
    port_count: usize,
    nodes: *const Node,
    node_count: usize,
    outputs: *const PowerOut,
    output_count: usize,
    external: u8,
    enabled: u8,
    candidate_only: u8,
) -> Result {
    let none = || Result {
        index: -1,
        port_id: 0,
    };
    let (Some(contracts), Some(ports), Some(nodes), Some(outputs)) = (
        unsafe { span(contracts, contract_count) },
        unsafe { span(ports, port_count) },
        unsafe { span(nodes, node_count) },
        unsafe { span(outputs, output_count) },
    ) else {
        return none();
    };
    if candidate_only == 0
        && (!enabled_for_resolution(enabled, external)
            || ports.iter().any(|p| p.incoming != 0)
            || nodes.iter().any(|n| n.winning != 0))
    {
        return none();
    }
    let with_node: HashSet<i64> = nodes.iter().filter(|n| n.usb != 0).map(|n| n.id).collect();
    let mut power_out = HashMap::new();
    for out in outputs {
        power_out.entry(out.key).or_insert(out.watts);
    }
    // Resolve uses the first UUID match even if that port is ineligible; evidence uses any eligible match.
    let mut first_port = HashMap::new();
    let mut candidate_port = HashMap::new();
    for port in ports {
        if port.key == 0 {
            continue;
        }
        first_port.entry(port.key).or_insert(port);
        if port.usb != 0 && port.connected != 0 {
            candidate_port.entry(port.key).or_insert(port);
        }
    }
    let mut result = none();
    for (index, c) in contracts.iter().enumerate() {
        if !plausible(c, power_out.get(&c.key).copied()) {
            continue;
        }
        let source = if candidate_only != 0 {
            &candidate_port
        } else {
            &first_port
        };
        let Some(port) = source.get(&c.key) else {
            continue;
        };
        if port.usb == 0 || port.connected == 0 {
            continue;
        }
        if candidate_only != 0 {
            return Result {
                index: index as i64,
                port_id: port.id,
            };
        }
        if port.has_power != 0 || with_node.contains(&port.id) {
            continue;
        }
        if result.index >= 0 {
            return none();
        }
        result = Result {
            index: index as i64,
            port_id: port.id,
        };
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numeric_and_direction_boundaries_are_shared() {
        let c = Contract {
            key: 1,
            power: 10000,
            voltage: 5000,
            current: 2000,
            outgoing_label: 0,
        };
        assert!(plausible(&c, Some(0.5)));
        assert!(!plausible(&c, Some(0.50001)));
        assert!(plausible(&c, Some(f64::NAN)));
        assert!(!consistent(&Contract { current: 0, ..c }));
    }
}
