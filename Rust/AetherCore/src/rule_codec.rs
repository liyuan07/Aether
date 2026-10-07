// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Legacy shortcut JSON encoding. Inputs are borrowed only for the synchronous call.
use crate::{
    abi::{Bytes, Uuid},
    shortcuts::Key,
    storage::{self, Buffer},
};
use serde::{
    Serialize, Serializer,
    ser::{SerializeSeq, SerializeStruct},
};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Span {
    pub start: usize,
    pub length: usize,
}
impl Span {
    pub(crate) fn text(self, bytes: &[u8]) -> Option<&str> {
        std::str::from_utf8(bytes.get(self.start..self.start.checked_add(self.length)?)?).ok()
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Row {
    pub id: Uuid,
    pub source: Key,
    pub target: Key,
    pub name: Span,
    pub display_name: Span,
    pub bundle: Span,
    pub path: Span,
    pub kind: u8,
    pub enabled: u8,
    pub bundle_present: u8,
    pub mode: u8,
    pub layout: u8,
    pub use_finder: u8,
}
struct Combination(Key);
impl Serialize for Combination {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let key = self.0;
        let mut value =
            serializer.serialize_struct("KeyCombination", if key.physical == 0 { 2 } else { 3 })?;
        value.serialize_field("keyCode", &key.code)?;
        // Encoding preserves raw bits; the existing decoder masks logical modifiers.
        value.serialize_field("modifiers", &key.modifiers)?;
        if key.physical != 0 {
            value.serialize_field("physicalModifiers", &key.physical)?;
        }
        value.end()
    }
}
#[derive(Serialize)]
struct Target<'a> {
    #[serde(rename = "applicationPath")]
    path: &'a str,
    #[serde(rename = "bundleIdentifier", skip_serializing_if = "Option::is_none")]
    bundle: Option<&'a str>,
    #[serde(rename = "displayName")]
    name: &'a str,
}
#[derive(Serialize)]
enum Action<'a> {
    #[serde(rename = "application")]
    Application {
        mode: &'static str,
        target: Target<'a>,
    },
    #[serde(rename = "finderFolder")]
    Finder { path: &'a str },
    #[serde(rename = "terminal")]
    Terminal {
        #[serde(rename = "fallbackPath")]
        path: &'a str,
        #[serde(rename = "useFrontmostFinder")]
        use_finder: bool,
    },
    #[serde(rename = "showDesktop")]
    Desktop {},
    #[serde(rename = "windowLayout")]
    Layout { _0: &'static str },
    #[serde(rename = "remap")]
    Remap { to: Combination },
}
struct Rule<'a> {
    row: &'a Row,
    name: &'a str,
    action: Action<'a>,
}
impl Serialize for Rule<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        const HEX: &[u8; 16] = b"0123456789ABCDEF";
        let mut uuid = [b'-'; 36];
        let mut position = 0;
        for byte in self.row.id.bytes {
            if [8, 13, 18, 23].contains(&position) {
                position += 1;
            }
            uuid[position] = HEX[(byte >> 4) as usize];
            uuid[position + 1] = HEX[(byte & 15) as usize];
            position += 2;
        }
        let mut value = serializer.serialize_struct("ShortcutRule", 5)?;
        value.serialize_field("action", &self.action)?;
        value.serialize_field("id", std::str::from_utf8(&uuid).unwrap())?;
        value.serialize_field("isEnabled", &(self.row.enabled != 0))?;
        value.serialize_field("name", self.name)?;
        value.serialize_field("source", &Combination(self.row.source))?;
        value.end()
    }
}
fn rule<'a>(row: &'a Row, bytes: &'a [u8]) -> Option<Rule<'a>> {
    let name = row.name.text(bytes)?;
    let action = match row.kind {
        0 => Action::Application {
            mode: match row.mode {
                0 => "activateExisting",
                1 => "newWindow",
                _ => return None,
            },
            target: Target {
                path: row.path.text(bytes)?,
                bundle: if row.bundle_present == 0 {
                    None
                } else {
                    Some(row.bundle.text(bytes)?)
                },
                name: row.display_name.text(bytes)?,
            },
        },
        1 => Action::Finder {
            path: row.path.text(bytes)?,
        },
        2 => Action::Terminal {
            path: row.path.text(bytes)?,
            use_finder: row.use_finder != 0,
        },
        3 => Action::Desktop {},
        4 => Action::Layout {
            _0: match row.layout {
                0 => "leftHalf",
                1 => "rightHalf",
                2 => "topHalf",
                3 => "bottomHalf",
                4 => "topLeft",
                5 => "topRight",
                6 => "bottomLeft",
                7 => "bottomRight",
                _ => return None,
            },
        },
        5 => Action::Remap {
            to: Combination(row.target),
        },
        _ => return None,
    };
    Some(Rule { row, name, action })
}
pub(crate) struct Rules<'a> {
    pub(crate) rows: &'a [Row],
    pub(crate) bytes: &'a [u8],
}
impl Serialize for Rules<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(self.rows.len()))?;
        for row in self.rows {
            let rule = rule(row, self.bytes)
                .ok_or_else(|| serde::ser::Error::custom("invalid rule record"))?;
            sequence.serialize_element(&rule)?;
        }
        sequence.end()
    }
}
fn encode(rows: &[Row], bytes: &[u8]) -> Option<Vec<u8>> {
    serde_json::to_vec_pretty(&Rules { rows, bytes }).ok()
}
/// Null pointers are accepted only for zero lengths. Spans are checked, including overflow and UTF-8.
/// Invalid inputs return status 3 and no partial output. No borrowed pointer survives return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_encode(
    rows: *const Row,
    count: usize,
    bytes: Bytes,
) -> *mut Buffer {
    if rows.is_null() && count != 0 {
        return storage::buffer(Vec::new(), 3);
    }
    let rows = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(rows, count) }
    };
    let result = unsafe { bytes.slice() }.and_then(|bytes| encode(rows, bytes));
    match result {
        Some(bytes) => storage::buffer(bytes, 0),
        None => storage::buffer(Vec::new(), 3),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Row {
        Row {
            id: Uuid { bytes: [0xab; 16] },
            source: Key {
                code: 65535,
                physical: 0,
                modifiers: 255,
            },
            target: Key {
                code: 0,
                physical: 65535,
                modifiers: 128,
            },
            name: Span {
                start: 0,
                length: 3,
            },
            display_name: Span::default(),
            bundle: Span::default(),
            path: Span::default(),
            kind: 3,
            enabled: 1,
            bundle_present: 0,
            mode: 0,
            layout: 0,
            use_finder: 0,
        }
    }
    #[test]
    fn legacy_shape_and_invalid_inputs() {
        let mut row = sample();
        let encoded = encode(&[row], b"a\0b").unwrap();
        let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(value[0]["id"], "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB");
        assert_eq!(value[0]["name"], "a\0b");
        assert_eq!(value[0]["action"]["showDesktop"], serde_json::json!({}));
        assert_eq!(value[0]["source"]["modifiers"], 255);
        assert!(value[0]["source"].get("physicalModifiers").is_none());
        row.kind = 5;
        assert!(encode(&[row], b"a\0b").is_some());
        row.name.start = usize::MAX;
        assert!(encode(&[row], b"a\0b").is_none());
        assert!(encode(&[sample()], &[255, 0, 0]).is_none());
        let invalid = unsafe {
            aether_rule_encode(
                std::ptr::null(),
                1,
                Bytes {
                    data: std::ptr::null(),
                    length: 0,
                },
            )
        };
        assert_eq!(unsafe { storage::aether_buffer_view(invalid) }.status, 3);
        unsafe { storage::aether_buffer_destroy(invalid) };
    }
    #[test]
    fn invalid_tags_spans_and_partial_output_are_rejected() {
        let bytes = "合成".as_bytes();
        let mut row = sample();
        row.kind = 255;
        assert!(encode(&[row], bytes).is_none());
        row.kind = 0;
        row.mode = 2;
        assert!(encode(&[row], bytes).is_none());
        row.kind = 4;
        row.layout = 8;
        assert!(encode(&[row], bytes).is_none());
        row.kind = 3;
        row.name.start = 1; // Within the buffer, but inside a multibyte scalar.
        assert!(encode(&[row], bytes).is_none());
        row.name = Span {
            start: bytes.len(),
            length: 1,
        };
        assert!(encode(&[row], bytes).is_none());
        let rows = [sample(), row];
        let handle = unsafe {
            aether_rule_encode(
                rows.as_ptr(),
                rows.len(),
                Bytes {
                    data: bytes.as_ptr(),
                    length: bytes.len(),
                },
            )
        };
        let view = unsafe { storage::aether_buffer_view(handle) };
        assert_eq!(view.status, 3);
        assert_eq!(view.length, 0);
        unsafe { storage::aether_buffer_destroy(handle) };
        let handle = unsafe {
            aether_rule_encode(
                std::ptr::null(),
                0,
                Bytes {
                    data: std::ptr::null(),
                    length: 0,
                },
            )
        };
        let view = unsafe { storage::aether_buffer_view(handle) };
        assert_eq!(view.status, 0);
        assert_eq!(
            unsafe { std::slice::from_raw_parts(view.bytes, view.length) },
            b"[]"
        );
        unsafe { storage::aether_buffer_destroy(handle) };
    }
}
