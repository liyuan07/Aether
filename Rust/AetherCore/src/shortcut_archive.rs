// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Archive framing and rule payload. Native preferences retain Foundation dictionary semantics.
use crate::{
    abi::Bytes,
    json, preferences,
    rule_codec::{Row, Rules},
    rule_decode::{self, Decoded, Object},
    storage::{self, Buffer},
};
use serde::{Deserialize, Serialize, de};
use serde_json::value::RawValue;

#[derive(Serialize)]
struct Archive<'a> {
    preferences: &'a RawValue,
    #[serde(rename = "schemaVersion")]
    version: i64,
    shortcuts: Rules<'a>,
}
fn encode(rows: &[Row], bytes: &[u8], preferences: &[u8]) -> Option<Vec<u8>> {
    let preferences: &RawValue = serde_json::from_slice(preferences).ok()?;
    if !preferences.get().starts_with('{') {
        return None;
    }
    serde_json::to_vec_pretty(&Archive {
        preferences,
        version: preferences::ARCHIVE_VERSION,
        shortcuts: Rules { rows, bytes },
    })
    .ok()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_archive_encode(
    rows: *const Row,
    count: usize,
    bytes: Bytes,
    preferences: Bytes,
) -> *mut Buffer {
    if rows.is_null() && count != 0 {
        return storage::buffer(Vec::new(), 3);
    }
    let rows = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(rows, count) }
    };
    let result = unsafe { bytes.slice() }
        .zip(unsafe { preferences.slice() })
        .and_then(|(bytes, preferences)| encode(rows, bytes, preferences));
    match result {
        Some(bytes) => storage::buffer(bytes, 0),
        None => storage::buffer(Vec::new(), 3),
    }
}
struct Version(i64);
impl<'de> Deserialize<'de> for Version {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = <&RawValue>::deserialize(d)?;
        raw.get()
            .parse::<i64>()
            .map(Self)
            .map_err(de::Error::custom)
    }
}
#[derive(Deserialize)]
struct Wire<'a> {
    #[serde(rename = "schemaVersion")]
    version: Option<Version>,
    #[serde(borrow)]
    shortcuts: &'a RawValue,
    #[serde(borrow)]
    preferences: Option<&'a RawValue>,
    #[serde(rename = "inputAutomation", borrow)]
    legacy: Option<&'a RawValue>,
}
pub struct Owner {
    rules: Option<Decoded>,
    preferences: Vec<u8>,
    version: i64,
    status: u32,
}
fn decode(bytes: &[u8]) -> Result<Owner, serde_json::Error> {
    let Object(wire): Object<Wire> = serde_json::from_slice(bytes)?;
    let preferences = wire
        .preferences
        .or(wire.legacy)
        .ok_or_else(|| <serde_json::Error as de::Error>::custom("missing preferences"))?;
    Ok(Owner {
        rules: Some(rule_decode::decode(wire.shortcuts.get().as_bytes())?),
        preferences: preferences.get().as_bytes().to_vec(),
        version: wire.version.map_or(preferences::ARCHIVE_DEFAULT, |v| v.0),
        status: 0,
    })
}
#[repr(C)]
pub struct View {
    pub rules: rule_decode::View,
    pub preferences: Bytes,
    pub version: i64,
    pub status: u32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_archive_decode(bytes: Bytes) -> *mut Owner {
    let result = unsafe { bytes.slice() }
        .filter(|b| json::native_depth_supported(b))
        .and_then(|b| json::with_first_wins(b, decode).ok());
    Box::into_raw(Box::new(result.unwrap_or_else(|| Owner {
        rules: None,
        preferences: Vec::new(),
        version: 0,
        status: 2,
    })))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_archive_view(handle: *const Owner) -> View {
    let rules = |pointer| unsafe { rule_decode::aether_rule_decoded_view(pointer) };
    match unsafe { handle.as_ref() } {
        Some(value) => View {
            rules: rules(value.rules.as_ref().map_or(std::ptr::null(), |r| r)),
            preferences: Bytes {
                data: value.preferences.as_ptr(),
                length: value.preferences.len(),
            },
            version: value.version,
            status: value.status,
        },
        None => View {
            rules: rules(std::ptr::null()),
            preferences: Bytes {
                data: std::ptr::null(),
                length: 0,
            },
            version: 0,
            status: 2,
        },
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_archive_destroy(handle: *mut Owner) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_shortcut_archive_supported(
    archive: i64,
    normalized_preferences: i64,
) -> u8 {
    u8::from(
        archive <= preferences::ARCHIVE_VERSION && normalized_preferences <= preferences::VERSION,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_ownership_legacy_selection_and_versions() {
        let source = br#"{"shortcuts":[],"preferences":null,"inputAutomation":{"app":{"launchAtLogin":true}}}"#.to_vec();
        let handle = unsafe {
            aether_shortcut_archive_decode(Bytes {
                data: source.as_ptr(),
                length: source.len(),
            })
        };
        drop(source);
        let view = unsafe { aether_shortcut_archive_view(handle) };
        assert_eq!(view.status, 0);
        assert_eq!(view.version, 1);
        assert_eq!(view.rules.status, 0);
        assert_eq!(view.rules.count, 0);
        assert_eq!(
            unsafe { view.preferences.text() },
            Some(r#"{"app":{"launchAtLogin":true}}"#)
        );
        unsafe { aether_shortcut_archive_destroy(handle) };
        for version in [i64::MIN, -1, 0, 1, 2, 3, i64::MAX] {
            for prefs in [i64::MIN, 0, 9, 10, i64::MAX] {
                assert_eq!(
                    aether_shortcut_archive_supported(version, prefs),
                    u8::from(version <= 2 && prefs <= 9)
                );
            }
        }
        let encoded = encode(&[], &[], b"{}").unwrap();
        let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(
            value,
            serde_json::json!({"preferences": {}, "schemaVersion": 2, "shortcuts": []})
        );
    }
    #[test]
    fn failed_inputs_have_no_partial_rules_and_nulls_are_safe() {
        for source in [
            b"{}".as_slice(),
            b"[]",
            b"null",
            br#"{"shortcuts":[{}],"preferences":{}}"#,
        ] {
            let handle = unsafe {
                aether_shortcut_archive_decode(Bytes {
                    data: source.as_ptr(),
                    length: source.len(),
                })
            };
            let view = unsafe { aether_shortcut_archive_view(handle) };
            assert_eq!(view.status, 2);
            assert_eq!(view.rules.count, 0);
            assert_eq!(view.preferences.length, 0);
            unsafe { aether_shortcut_archive_destroy(handle) };
        }
        assert_eq!(
            unsafe { aether_shortcut_archive_view(std::ptr::null()) }.status,
            2
        );
        unsafe { aether_shortcut_archive_destroy(std::ptr::null_mut()) };
        assert!(encode(&[], &[], b"null").is_none());
        let handle = unsafe {
            aether_shortcut_archive_encode(
                std::ptr::null(),
                1,
                Bytes {
                    data: std::ptr::null(),
                    length: 0,
                },
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
