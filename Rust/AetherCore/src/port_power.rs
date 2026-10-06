// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::HashMap;
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Power {
    watts: f64,
    current: i64,
    voltage: i64,
    configured_voltage: i64,
    configured_current: i64,
    vconn_current: i64,
    vconn_power: i64,
    vconn_max_current: i64,
    incoming: u8,
    estimated: u8,
}
#[repr(C)]
pub struct Port {
    id: i64,
    key: u64,
    connected: u8,
    has_power: u8,
    power: Power,
}
#[repr(C)]
pub struct Charger {
    id: i64,
    max_watts: i64,
    voltage: i64,
    current: i64,
    usb: u8,
    winning: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Telemetry {
    present: u8,
    power: i64,
    current: i64,
    voltage: i64,
}
#[repr(C)]
pub struct Output {
    key: u64,
    volts: f64,
    amps: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Patch {
    index: usize,
    power: Power,
    raw_current: f64,
    raw_voltage: f64,
    convert_raw: u8,
}
fn incoming(index: usize, voltage: i64, current: i64, estimated: u8, t: Telemetry) -> Patch {
    Patch {
        index,
        power: Power {
            watts: if t.present != 0 {
                t.power as f64 / 1000.0
            } else {
                0.0
            },
            current: if t.present != 0 { t.current } else { 0 },
            voltage: if t.present != 0 { t.voltage } else { voltage },
            configured_voltage: voltage,
            configured_current: current,
            incoming: 1,
            estimated,
            ..Power::default()
        },
        raw_current: 0.0,
        raw_voltage: 0.0,
        convert_raw: 0,
    }
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
unsafe fn write(rows: &[Patch], out: *mut Patch, cap: usize) -> usize {
    if !out.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap));
        }
    }
    rows.len()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_charger_power(
    ports: *const Port,
    n: usize,
    chargers: *const Charger,
    c: usize,
    telemetry: Telemetry,
    out: *mut Patch,
    cap: usize,
) -> usize {
    let (Some(ports), Some(chargers)) = (unsafe { span(ports, n) }, unsafe { span(chargers, c) })
    else {
        return 0;
    };
    let mut first = HashMap::new();
    for charger in chargers {
        if charger.usb != 0 && charger.id > 0 && charger.max_watts > 0 {
            first.entry(charger.id).or_insert(charger);
        }
    }
    let rows: Vec<Patch> = ports
        .iter()
        .enumerate()
        .filter_map(|(index, p)| {
            if p.has_power != 0 || p.connected == 0 {
                return None;
            }
            first.get(&p.id).map(|c| {
                incoming(
                    index,
                    c.voltage,
                    c.current,
                    u8::from(c.winning == 0),
                    telemetry,
                )
            })
        })
        .collect();
    unsafe { write(&rows, out, cap) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_contract_power(
    ports: *const Port,
    n: usize,
    id: i64,
    voltage: i64,
    current: i64,
    telemetry: Telemetry,
    out: *mut Patch,
    cap: usize,
) -> usize {
    let Some(ports) = (unsafe { span(ports, n) }) else {
        return 0;
    };
    let Some(index) = ports.iter().position(|p| p.id == id) else {
        return 0;
    };
    unsafe { write(&[incoming(index, voltage, current, 1, telemetry)], out, cap) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_output_power(
    ports: *const Port,
    n: usize,
    channels: *const Output,
    c: usize,
    out: *mut Patch,
    cap: usize,
) -> usize {
    let (Some(ports), Some(channels)) = (unsafe { span(ports, n) }, unsafe { span(channels, c) })
    else {
        return 0;
    };
    let mut first = HashMap::new();
    for c in channels {
        first.entry(c.key).or_insert(c);
    }
    let rows: Vec<Patch> = ports
        .iter()
        .enumerate()
        .filter_map(|(index, p)| {
            if p.key == 0 || (p.has_power != 0 && p.power.incoming != 0) {
                return None;
            }
            let c = first.get(&p.key)?;
            let watts = c.volts * c.amps;
            if !(watts > 0.0) {
                return None;
            }
            let existing = if p.has_power != 0 {
                p.power
            } else {
                Power::default()
            };
            Some(Patch {
                index,
                power: Power {
                    watts,
                    incoming: 0,
                    ..existing
                },
                raw_current: (c.amps * 1000.0).round(),
                raw_voltage: (c.volts * 1000.0).round(),
                convert_raw: 1,
            })
        })
        .collect();
    unsafe { write(&rows, out, cap) }
}

#[repr(C)]
pub struct Connector {
    id: i64,
    active: u8,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_connector_power(
    connectors: *const Connector,
    count: usize,
    chargers: *const Charger,
    charger_count: usize,
    smc_ports: *const i64,
    smc_count: usize,
    t: Telemetry,
    usb_node: u8,
    usb_smc: u8,
    output: *mut Patch,
    capacity: usize,
) -> usize {
    let (Some(connectors), Some(chargers), Some(smc_ports)) = (
        unsafe { span(connectors, count) },
        unsafe { span(chargers, charger_count) },
        unsafe { span(smc_ports, smc_count) },
    ) else {
        return 0;
    };
    if usb_node != 0 || t.present == 0 || t.power <= 0 {
        return 0;
    }
    let mut negotiated = HashMap::new();
    for charger in chargers {
        if charger.usb == 0 && charger.winning != 0 {
            negotiated.entry(charger.id).or_insert(charger);
        }
    }
    let smc_ports: std::collections::HashSet<i64> = smc_ports.iter().copied().collect();
    let mut rows = Vec::new();
    for (index, connector) in connectors.iter().enumerate() {
        let contract = negotiated.get(&connector.id);
        if connector.active != 0
            && (contract.is_some() || smc_ports.contains(&connector.id) || usb_smc == 0)
        {
            rows.push(incoming(
                index,
                contract.map_or(0, |c| c.voltage),
                contract.map_or(0, |c| c.current),
                0,
                t,
            ));
        }
    }
    unsafe { write(&rows, output, capacity) }
}
