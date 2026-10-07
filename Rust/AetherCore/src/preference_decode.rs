// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Preference decoding. Synchronous native key tokens retain Foundation Unicode equality.
use crate::{
    abi::Bytes,
    json::{self, Text},
    preference_codec::Entry,
    preferences,
    rule_codec::Span,
    rule_decode::Object,
};
use serde::{
    Deserialize,
    de::{self, MapAccess, Visitor},
};
use serde_json::value::RawValue;
use std::{collections::HashSet, ffi::c_void, fmt};
pub type KeyToken = unsafe extern "C" fn(*mut c_void, u8, Bytes) -> usize;
struct Seen<T> {
    exists: bool,
    value: Option<T>,
}
impl<T> Default for Seen<T> {
    fn default() -> Self {
        Self {
            exists: false,
            value: None,
        }
    }
}
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Seen<T> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self {
            exists: true,
            value: Option::deserialize(d)?,
        })
    }
}
#[derive(Deserialize)]
struct General {
    #[serde(rename = "launchAtLogin")]
    launch: Option<bool>,
    #[serde(rename = "blockAutomaticABC")]
    block: Option<bool>,
    #[serde(rename = "showModifierButtons")]
    show: Option<bool>,
}
#[derive(Deserialize)]
struct Legacy<'a> {
    #[serde(rename = "launchAtLogin", borrow)]
    launch: Option<&'a RawValue>,
    #[serde(rename = "blockAutomaticABC", borrow)]
    block: Option<&'a RawValue>,
}
#[derive(Deserialize)]
struct Shortcuts<'a> {
    #[serde(rename = "defaultBundleIdentifiers", borrow)]
    defaults: Option<&'a RawValue>,
    #[serde(rename = "orderedBundleIdentifiers", borrow)]
    orders: Option<&'a RawValue>,
    #[serde(rename = "windowBehaviorOverrides", borrow)]
    behaviors: Option<&'a RawValue>,
    #[serde(rename = "holdDuration", borrow)]
    hold: Option<&'a RawValue>,
    #[serde(rename = "restoreMinimizedWindows")]
    restore: Option<bool>,
}
#[derive(Deserialize)]
struct Wire<'a> {
    #[serde(rename = "schemaVersion", borrow)]
    version: Option<&'a RawValue>,
    #[serde(default)]
    app: Seen<Object<General>>,
    #[serde(default, borrow)]
    general: Seen<&'a RawValue>,
    #[serde(rename = "applicationShortcuts", borrow)]
    shortcuts: Option<&'a RawValue>,
}
// Capture dictionary values as raw JSON first: duplicate canonical keys must not decode their value.
struct Pairs<'a>(Vec<(Text<'a>, &'a RawValue)>);
impl<'de: 'a, 'a> Deserialize<'de> for Pairs<'a> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Map;
        impl<'de> Visitor<'de> for Map {
            type Value = Pairs<'de>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a dictionary object")
            }
            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut values = Vec::new();
                while let Some(key) = map.next_key::<Text>()? {
                    values.push((key, map.next_value::<&RawValue>()?));
                }
                Ok(Pairs(values))
            }
        }
        d.deserialize_map(Map)
    }
}
#[repr(C)]
pub struct Row {
    pub entry: Entry,
    pub native_key: usize,
}
pub struct Owner {
    hold: f64,
    launch: u8,
    block: u8,
    show: u8,
    restore: u8,
    version: i64,
    version_known: u8,
    defaults: Vec<Row>,
    orders: Vec<Row>,
    behaviors: Vec<Row>,
    values: Vec<Span>,
    bytes: Vec<u8>,
}
impl Owner {
    fn text(&mut self, value: &str) -> Span {
        let start = self.bytes.len();
        self.bytes.extend_from_slice(value.as_bytes());
        Span {
            start,
            length: value.len(),
        }
    }
    fn dictionary(
        &mut self,
        raw: Option<&RawValue>,
        kind: u8,
        token: Option<KeyToken>,
        context: *mut c_void,
    ) -> Result<Vec<Row>, serde_json::Error> {
        let Some(raw) = raw else {
            return Ok(Vec::new());
        };
        let Pairs(pairs) = serde_json::from_str(raw.get())?;
        let mut rows = Vec::new();
        let mut seen = HashSet::new();
        for (key, value) in pairs {
            let token = token.ok_or_else(|| {
                <serde_json::Error as de::Error>::custom("missing native key interner")
            })?;
            let native_key = unsafe {
                token(
                    context,
                    kind,
                    Bytes {
                        data: key.as_ptr(),
                        length: key.len(),
                    },
                )
            };
            if !seen.insert(native_key) {
                continue;
            }
            let mut entry = Entry {
                key: self.text(&key),
                value: Span::default(),
                start: 0,
                count: 0,
                behavior: 0,
            };
            match kind {
                0 => {
                    let value: Text = serde_json::from_str(value.get())?;
                    entry.value = self.text(&value);
                }
                1 => {
                    let values: Vec<Text> = serde_json::from_str(value.get())?;
                    entry.start = self.values.len();
                    entry.count = values.len();
                    for value in values {
                        let span = self.text(&value);
                        self.values.push(span);
                    }
                }
                _ => {
                    let value: Text = serde_json::from_str(value.get())?;
                    entry.behavior = match value.as_ref() {
                        "followGlobal" => 0,
                        "keepMinimized" => 1,
                        "restoreMinimized" => 2,
                        "activateOnly" => 3,
                        _ => {
                            return Err(<serde_json::Error as de::Error>::custom(
                                "invalid window behavior",
                            ));
                        }
                    };
                }
            }
            rows.push(Row { entry, native_key });
        }
        Ok(rows)
    }
}
fn decode(
    bytes: &[u8],
    token: Option<KeyToken>,
    context: *mut c_void,
) -> Result<Owner, serde_json::Error> {
    let Object(wire): Object<Wire> = serde_json::from_slice(bytes)?;
    let defaults = preferences::aether_preferences_defaults();
    let mut general = preferences::General {
        launch: defaults.launch,
        block: defaults.block,
        show: defaults.show,
    };
    if let Some(Object(app)) = wire.app.value {
        general.launch = app.launch.map_or(general.launch, u8::from);
        general.block = app.block.map_or(general.block, u8::from);
        general.show = app.show.map_or(general.show, u8::from);
    }
    if wire.general.exists {
        let raw = wire
            .general
            .value
            .ok_or_else(|| <serde_json::Error as de::Error>::custom("null legacy general"))?;
        let Object(legacy): Object<Legacy> = serde_json::from_str(raw.get())?;
        let launch = if wire.app.exists {
            None
        } else {
            legacy
                .launch
                .map(|raw| serde_json::from_str::<bool>(raw.get()))
                .transpose()?
        };
        let block = legacy
            .block
            .map(|raw| serde_json::from_str::<bool>(raw.get()))
            .transpose()?;
        general = preferences::aether_preferences_migrate(
            general,
            u8::from(wire.app.exists),
            u8::from(launch == Some(true)),
            u8::from(launch.is_some()),
            u8::from(block == Some(true)),
            u8::from(block.is_some()),
        );
    }
    let (version, version_known) = match wire.version {
        None => (defaults.stored_default, 1),
        Some(raw) => match raw.get().parse::<i64>() {
            Ok(version) => (version, 1),
            Err(_)
                if raw
                    .get()
                    .as_bytes()
                    .first()
                    .is_some_and(|c| c.is_ascii_digit() || *c == b'-') =>
            {
                (defaults.stored_default, 0)
            }
            Err(_) => (defaults.stored_default, 1),
        },
    };
    let mut output = Owner {
        hold: defaults.hold,
        launch: general.launch,
        block: general.block,
        show: general.show,
        restore: defaults.restore,
        version,
        version_known,
        defaults: Vec::new(),
        orders: Vec::new(),
        behaviors: Vec::new(),
        values: Vec::new(),
        bytes: Vec::new(),
    };
    if let Some(raw) = wire.shortcuts {
        let Object(shortcuts): Object<Shortcuts> = serde_json::from_str(raw.get())?;
        if let Some(raw) = shortcuts.hold {
            let value: f64 = serde_json::from_str(raw.get())?;
            let mantissa = raw.get().split(['e', 'E']).next().unwrap_or("");
            // Foundation rejects nonzero values rounded all the way down to zero.
            if !value.is_finite()
                || value == 0.0 && mantissa.bytes().any(|b| (b'1'..=b'9').contains(&b))
            {
                return Err(<serde_json::Error as de::Error>::custom(
                    "floating point underflow",
                ));
            }
            output.hold = value;
        }
        output.restore = shortcuts.restore.map_or(output.restore, u8::from);
        output.defaults = output.dictionary(shortcuts.defaults, 0, token, context)?;
        output.orders = output.dictionary(shortcuts.orders, 1, token, context)?;
        output.behaviors = output.dictionary(shortcuts.behaviors, 2, token, context)?;
    }
    Ok(output)
}
#[repr(C)]
pub struct View {
    pub hold: f64,
    pub version: i64,
    pub launch: u8,
    pub block: u8,
    pub show: u8,
    pub restore: u8,
    pub version_known: u8,
    pub defaults: *const Row,
    pub default_count: usize,
    pub orders: *const Row,
    pub order_count: usize,
    pub behaviors: *const Row,
    pub behavior_count: usize,
    pub values: *const Span,
    pub value_count: usize,
    pub bytes: Bytes,
    pub status: u32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_preferences_decode(
    bytes: Bytes,
    token: Option<KeyToken>,
    context: *mut c_void,
) -> *mut Owner {
    unsafe { bytes.slice() }
        .filter(|b| json::native_depth_supported(b))
        .and_then(|b| json::with_first_wins(b, |b| decode(b, token, context)).ok())
        .map_or(std::ptr::null_mut(), |owner| Box::into_raw(Box::new(owner)))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_preferences_decoded_view(handle: *const Owner) -> View {
    match unsafe { handle.as_ref() } {
        Some(o) => View {
            hold: o.hold,
            version: o.version,
            launch: o.launch,
            block: o.block,
            show: o.show,
            restore: o.restore,
            version_known: o.version_known,
            defaults: o.defaults.as_ptr(),
            default_count: o.defaults.len(),
            orders: o.orders.as_ptr(),
            order_count: o.orders.len(),
            behaviors: o.behaviors.as_ptr(),
            behavior_count: o.behaviors.len(),
            values: o.values.as_ptr(),
            value_count: o.values.len(),
            bytes: Bytes {
                data: o.bytes.as_ptr(),
                length: o.bytes.len(),
            },
            status: 0,
        },
        None => View {
            hold: 0.0,
            version: 0,
            launch: 0,
            block: 0,
            show: 0,
            restore: 0,
            version_known: 0,
            defaults: std::ptr::null(),
            default_count: 0,
            orders: std::ptr::null(),
            order_count: 0,
            behaviors: std::ptr::null(),
            behavior_count: 0,
            values: std::ptr::null(),
            value_count: 0,
            bytes: Bytes {
                data: std::ptr::null(),
                length: 0,
            },
            status: 2,
        },
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_preferences_decoded_destroy(handle: *mut Owner) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_legacy_presence_and_floating_underflow() {
        let o = decode(
            br#"{"app":null,"general":{"launchAtLogin":"ignored","blockAutomaticABC":true}}"#,
            None,
            std::ptr::null_mut(),
        )
        .unwrap();
        assert_eq!((o.launch, o.block, o.show, o.restore), (0, 1, 1, 1));
        assert!(decode(br#"{"general":null}"#, None, std::ptr::null_mut()).is_err());
        assert!(decode(br#"{"app":[]}"#, None, std::ptr::null_mut()).is_err());
        for (literal, expected) in [
            ("1e-9999", false),
            ("1e-324", false),
            ("1e9999", false),
            ("0e-9999", true),
            ("-0e-9999", true),
            ("5e-324", true),
            ("-0", true),
        ] {
            let source = format!("{{\"applicationShortcuts\":{{\"holdDuration\":{literal}}}}}");
            assert_eq!(
                decode(source.as_bytes(), None, std::ptr::null_mut()).is_ok(),
                expected,
                "{literal}"
            );
        }
        let o = decode(br#"{"schemaVersion":9e0}"#, None, std::ptr::null_mut()).unwrap();
        assert_eq!(o.version_known, 0);
        let o = decode(br#"{"schemaVersion":9999}"#, None, std::ptr::null_mut()).unwrap();
        assert_eq!((o.version_known, o.version), (1, 9999));
    }
    unsafe extern "C" fn token(context: *mut c_void, _: u8, _: Bytes) -> usize {
        if !context.is_null() {
            unsafe {
                *(context.cast::<usize>()) += 1;
            }
        }
        0 // This fixture supplies two native-equivalent keys in one dictionary.
    }
    #[test]
    fn native_tokens_skip_duplicate_values_and_owner_outlives_inputs() {
        let bytes = br#"{"applicationShortcuts":{"defaultBundleIdentifiers":{"caf\u00e9":"first","cafe\u0301":null}}}"#.to_vec();
        let mut calls = 0_usize;
        let handle = unsafe {
            aether_preferences_decode(
                Bytes {
                    data: bytes.as_ptr(),
                    length: bytes.len(),
                },
                Some(token),
                (&mut calls as *mut usize).cast(),
            )
        };
        drop(bytes);
        assert_eq!(calls, 2);
        let view = unsafe { aether_preferences_decoded_view(handle) };
        assert_eq!(view.status, 0);
        assert_eq!(view.default_count, 1);
        let row = unsafe { &*view.defaults };
        let bytes = unsafe { view.bytes.slice().unwrap() };
        assert_eq!(row.entry.key.text(bytes), Some("café"));
        assert_eq!(row.entry.value.text(bytes), Some("first"));
        assert_eq!(row.native_key, 0);
        unsafe { aether_preferences_decoded_destroy(handle) };
        assert_eq!(
            unsafe { aether_preferences_decoded_view(std::ptr::null()) }.status,
            2
        );
        unsafe { aether_preferences_decoded_destroy(std::ptr::null_mut()) };
        let bad = unsafe {
            aether_preferences_decode(
                Bytes {
                    data: std::ptr::null(),
                    length: 1,
                },
                None,
                std::ptr::null_mut(),
            )
        };
        assert!(bad.is_null());
        let dict = br#"{"applicationShortcuts":{"defaultBundleIdentifiers":{"a":"value"}}}"#;
        assert!(
            unsafe {
                aether_preferences_decode(
                    Bytes {
                        data: dict.as_ptr(),
                        length: dict.len(),
                    },
                    None,
                    std::ptr::null_mut(),
                )
            }
            .is_null()
        );
    }
}
