// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Preference encoding borrows Swift's already-resolved dictionary contents synchronously.
use crate::{
    abi::Bytes,
    preferences,
    rule_codec::Span,
    storage::{self, Buffer},
};
use serde::{
    Serialize, Serializer,
    ser::{SerializeMap, SerializeSeq},
};
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Entry {
    pub key: Span,
    pub value: Span,
    pub start: usize,
    pub count: usize,
    pub behavior: u8,
}
#[repr(C)]
pub struct Input {
    pub hold: f64,
    pub launch: u8,
    pub block: u8,
    pub show: u8,
    pub restore: u8,
    pub defaults: *const Entry,
    pub default_count: usize,
    pub orders: *const Entry,
    pub order_count: usize,
    pub values: *const Span,
    pub value_count: usize,
    pub behaviors: *const Entry,
    pub behavior_count: usize,
}
struct Map<'a, T>(Vec<(&'a str, T)>);
impl<'a, T> Map<'a, T> {
    fn new(mut values: Vec<(&'a str, T)>) -> Option<Self> {
        values.sort_unstable_by(|a, b| a.0.cmp(b.0));
        if values.windows(2).any(|v| v[0].0 == v[1].0) {
            return None;
        }
        Some(Self(values))
    }
}
impl<T: Serialize> Serialize for Map<'_, T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (key, value) in &self.0 {
            map.serialize_entry(key, value)?;
        }
        map.end()
    }
}
struct Strings<'a> {
    spans: &'a [Span],
    bytes: &'a [u8],
}
impl Serialize for Strings<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.spans.len()))?;
        for span in self.spans {
            seq.serialize_element(
                span.text(self.bytes)
                    .ok_or_else(|| serde::ser::Error::custom("invalid preference text"))?,
            )?;
        }
        seq.end()
    }
}
#[derive(Serialize)]
struct General {
    #[serde(rename = "blockAutomaticABC")]
    block: bool,
    #[serde(rename = "launchAtLogin")]
    launch: bool,
    #[serde(rename = "showModifierButtons")]
    show: bool,
}
#[derive(Serialize)]
struct Shortcuts<'a> {
    #[serde(rename = "defaultBundleIdentifiers")]
    defaults: Map<'a, &'a str>,
    #[serde(rename = "holdDuration")]
    hold: f64,
    #[serde(rename = "orderedBundleIdentifiers")]
    orders: Map<'a, Strings<'a>>,
    #[serde(rename = "restoreMinimizedWindows")]
    restore: bool,
    #[serde(rename = "windowBehaviorOverrides")]
    behaviors: Map<'a, &'static str>,
}
#[derive(Serialize)]
struct Configuration<'a> {
    app: General,
    #[serde(rename = "applicationShortcuts")]
    shortcuts: Shortcuts<'a>,
    #[serde(rename = "schemaVersion")]
    version: i64,
}
unsafe fn slice<'a, T>(pointer: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        Some(&[])
    } else if pointer.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(pointer, count) })
    }
}
unsafe fn encode(input: &Input, bytes: &[u8]) -> Option<Vec<u8>> {
    if !input.hold.is_finite() {
        return None;
    }
    let defaults = unsafe { slice(input.defaults, input.default_count) }?;
    let orders = unsafe { slice(input.orders, input.order_count) }?;
    let values = unsafe { slice(input.values, input.value_count) }?;
    let behaviors = unsafe { slice(input.behaviors, input.behavior_count) }?;
    let defaults = Map::new(
        defaults
            .iter()
            .map(|v| Some((v.key.text(bytes)?, v.value.text(bytes)?)))
            .collect::<Option<Vec<_>>>()?,
    )?;
    let orders = Map::new(
        orders
            .iter()
            .map(|v| {
                Some((
                    v.key.text(bytes)?,
                    Strings {
                        spans: values.get(v.start..v.start.checked_add(v.count)?)?,
                        bytes,
                    },
                ))
            })
            .collect::<Option<Vec<_>>>()?,
    )?;
    let behaviors = Map::new(
        behaviors
            .iter()
            .map(|v| {
                Some((
                    v.key.text(bytes)?,
                    match v.behavior {
                        0 => "followGlobal",
                        1 => "keepMinimized",
                        2 => "restoreMinimized",
                        3 => "activateOnly",
                        _ => return None,
                    },
                ))
            })
            .collect::<Option<Vec<_>>>()?,
    )?;
    serde_json::to_vec_pretty(&Configuration {
        app: General {
            block: input.block != 0,
            launch: input.launch != 0,
            show: input.show != 0,
        },
        shortcuts: Shortcuts {
            defaults,
            hold: input.hold,
            orders,
            restore: input.restore != 0,
            behaviors,
        },
        version: preferences::VERSION,
    })
    .ok()
}
/// Borrowed arrays/arena must be readable for the call. All spans, ranges and tags are checked.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_preferences_encode(
    input: *const Input,
    bytes: Bytes,
) -> *mut Buffer {
    let result = unsafe { input.as_ref() }
        .zip(unsafe { bytes.slice() })
        .and_then(|(input, bytes)| unsafe { encode(input, bytes) });
    match result {
        Some(bytes) => storage::buffer(bytes, 0),
        None => storage::buffer(Vec::new(), 3),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn input() -> Input {
        Input {
            hold: 0.5,
            launch: 0,
            block: 1,
            show: 1,
            restore: 1,
            defaults: std::ptr::null(),
            default_count: 0,
            orders: std::ptr::null(),
            order_count: 0,
            values: std::ptr::null(),
            value_count: 0,
            behaviors: std::ptr::null(),
            behavior_count: 0,
        }
    }
    #[test]
    fn shape_version_and_invalid_arrays_spans_tags_are_checked() {
        let mut input = input();
        let encoded = unsafe { encode(&input, &[]) }.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(value["schemaVersion"], 9);
        assert_eq!(value["app"]["blockAutomaticABC"], true);
        assert_eq!(
            value["applicationShortcuts"]["orderedBundleIdentifiers"],
            serde_json::json!({})
        );
        input.hold = f64::NAN;
        assert!(unsafe { encode(&input, &[]) }.is_none());
        input.hold = 0.5;
        input.default_count = 1;
        assert!(unsafe { encode(&input, &[]) }.is_none());
        input.default_count = 0;
        let mut rows = [Entry {
            key: Span {
                start: 0,
                length: 1,
            },
            value: Span {
                start: 1,
                length: 1,
            },
            start: 0,
            count: 0,
            behavior: 4,
        }];
        input.behaviors = rows.as_ptr();
        input.behavior_count = 1;
        assert!(unsafe { encode(&input, b"kv") }.is_none());
        rows[0].behavior = 3;
        assert!(unsafe { encode(&input, b"kv") }.is_some());
        rows[0].key.start = usize::MAX;
        assert!(unsafe { encode(&input, b"kv") }.is_none());
        rows[0].key.start = 0;
        assert!(unsafe { encode(&input, &[255, 0]) }.is_none());
        input.behavior_count = 0;
        input.orders = rows.as_ptr();
        input.order_count = 1;
        rows[0].start = usize::MAX;
        rows[0].count = 1;
        assert!(unsafe { encode(&input, b"kv") }.is_none());
        rows[0].start = 0;
        assert!(unsafe { encode(&input, b"kv") }.is_none());
        let values = [Span {
            start: 1,
            length: usize::MAX,
        }];
        input.values = values.as_ptr();
        input.value_count = 1;
        assert!(unsafe { encode(&input, b"kv") }.is_none());
    }
    #[test]
    fn duplicate_keys_and_failed_output_never_escape() {
        let mut input = input();
        let row = Entry {
            key: Span {
                start: 0,
                length: 1,
            },
            value: Span {
                start: 1,
                length: 1,
            },
            start: 0,
            count: 0,
            behavior: 0,
        };
        let rows = [row, row];
        input.defaults = rows.as_ptr();
        input.default_count = rows.len();
        assert!(unsafe { encode(&input, b"kv") }.is_none());
        let handle = unsafe {
            aether_preferences_encode(
                &input,
                Bytes {
                    data: b"kv".as_ptr(),
                    length: 2,
                },
            )
        };
        let view = unsafe { storage::aether_buffer_view(handle) };
        assert_eq!(view.status, 3);
        assert_eq!(view.length, 0);
        unsafe { storage::aether_buffer_destroy(handle) };
        let handle = unsafe {
            aether_preferences_encode(
                std::ptr::null(),
                Bytes {
                    data: std::ptr::null(),
                    length: 0,
                },
            )
        };
        assert_eq!(unsafe { storage::aether_buffer_view(handle) }.status, 3);
        unsafe { storage::aether_buffer_destroy(handle) };
    }
}
