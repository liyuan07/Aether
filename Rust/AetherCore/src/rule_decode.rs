// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Owned decoded rules; no JSON/input pointer survives this call.
use crate::{
    abi::{Bytes, Uuid},
    json::{self, Text},
    rule_codec::{Row, Span},
    shortcuts::Key,
    versioned,
};
use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, Visitor},
};
use serde_json::value::RawValue;
use std::{fmt, marker::PhantomData};

// Derive's struct visitor also accepts positional arrays. Foundation's keyed containers do not.
struct Object<T>(T);
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Object<T> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Map<T>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>> Visitor<'de> for Map<T> {
            type Value = Object<T>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<M: MapAccess<'de>>(self, map: M) -> Result<Self::Value, M::Error> {
                T::deserialize(de::value::MapAccessDeserializer::new(map)).map(Object)
            }
        }
        d.deserialize_map(Map(PhantomData))
    }
}
// Exact decimal arithmetic for small unsigned fields; never round fractional JSON via f64.
fn unsigned(raw: &str, max: u64) -> Option<u64> {
    if let Ok(value) = raw.parse::<u64>() {
        return (value <= max).then_some(value);
    }
    let negative = raw.starts_with('-');
    let raw = raw.strip_prefix('-').unwrap_or(raw);
    if !raw.as_bytes().first()?.is_ascii_digit() {
        return None;
    }
    let mut parts = raw.split(['e', 'E']);
    let mantissa = parts.next()?;
    let exponent = parts
        .next()
        .map(str::parse::<i64>)
        .transpose()
        .ok()?
        .unwrap_or(0);
    if parts.next().is_some() {
        return None;
    }
    let fraction = mantissa.split_once('.').map_or(0, |(_, tail)| tail.len());
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let significant = digits.trim_start_matches('0');
    if significant.is_empty() {
        return Some(0);
    }
    if negative {
        return None;
    }
    let trimmed = significant.trim_end_matches('0');
    let scale = exponent
        .checked_sub(i64::try_from(fraction).ok()?)?
        .checked_add(i64::try_from(significant.len() - trimmed.len()).ok()?)?;
    if !(0..=5).contains(&scale) {
        return None;
    }
    let value = trimmed
        .parse::<u64>()
        .ok()?
        .checked_mul(10_u64.pow(scale as u32))?;
    (value <= max).then_some(value)
}
macro_rules! number {
    ($name:ident, $type:ty) => {
        struct $name($type);
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let raw = <&RawValue>::deserialize(d)?;
                unsigned(raw.get(), <$type>::MAX as u64)
                    .map(|v| Self(v as $type))
                    .ok_or_else(|| de::Error::custom("invalid unsigned integer"))
            }
        }
    };
}
number!(U16, u16);
number!(U8, u8);
#[derive(Deserialize)]
struct Combination {
    #[serde(rename = "keyCode")]
    code: U16,
    modifiers: U8,
    #[serde(rename = "physicalModifiers")]
    physical: Option<U16>,
}
impl Combination {
    fn key(self) -> Key {
        Key {
            code: self.code.0,
            modifiers: self.modifiers.0 & 15,
            physical: self.physical.map_or(0, |v| v.0),
        }
    }
}
#[derive(Deserialize)]
struct Target<'a> {
    #[serde(rename = "applicationPath", borrow)]
    path: Text<'a>,
    #[serde(rename = "bundleIdentifier", borrow)]
    bundle: Option<Text<'a>>,
    #[serde(rename = "displayName", borrow)]
    name: Text<'a>,
}
#[derive(Deserialize)]
struct Application<'a> {
    #[serde(borrow)]
    target: Object<Target<'a>>,
    #[serde(borrow)]
    mode: Text<'a>,
}
#[derive(Deserialize)]
struct Finder<'a> {
    #[serde(borrow)]
    path: Text<'a>,
}
#[derive(Deserialize)]
struct Terminal<'a> {
    #[serde(rename = "fallbackPath", borrow)]
    path: Text<'a>,
    #[serde(rename = "useFrontmostFinder")]
    use_finder: bool,
}
#[derive(Deserialize)]
struct Empty {}
#[derive(Deserialize)]
struct Layout<'a> {
    #[serde(borrow)]
    _0: Text<'a>,
}
#[derive(Deserialize)]
struct Remap {
    to: Object<Combination>,
}
enum Action<'a> {
    Application(Application<'a>),
    Finder(Finder<'a>),
    Terminal(Terminal<'a>),
    Desktop,
    Layout(Layout<'a>),
    Remap(Remap),
}
impl<'de: 'a, 'a> Deserialize<'de> for Action<'a> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Map<'a>(PhantomData<&'a str>);
        impl<'de: 'a, 'a> Visitor<'de> for Map<'a> {
            type Value = Action<'a>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("one action object")
            }
            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut seen = 0_u8;
                let mut selected = None;
                while let Some(key) = map.next_key::<Text>()? {
                    let raw: &'de RawValue = map.next_value()?;
                    let kind = match key.as_ref() {
                        "application" => 0,
                        "finderFolder" => 1,
                        "terminal" => 2,
                        "showDesktop" => 3,
                        "windowLayout" => 4,
                        "remap" => 5,
                        _ => continue,
                    };
                    if seen & (1 << kind) == 0 {
                        seen |= 1 << kind;
                        selected = Some((kind, raw));
                    }
                }
                if seen.count_ones() != 1 {
                    return Err(de::Error::custom("expected one recognized action"));
                }
                let (kind, raw) = selected.unwrap();
                let parse = |e: serde_json::Error| de::Error::custom(e);
                Ok(match kind {
                    0 => Action::Application(
                        serde_json::from_str::<Object<Application>>(raw.get())
                            .map_err(parse)?
                            .0,
                    ),
                    1 => Action::Finder(
                        serde_json::from_str::<Object<Finder>>(raw.get())
                            .map_err(parse)?
                            .0,
                    ),
                    2 => Action::Terminal(
                        serde_json::from_str::<Object<Terminal>>(raw.get())
                            .map_err(parse)?
                            .0,
                    ),
                    3 => {
                        serde_json::from_str::<Object<Empty>>(raw.get()).map_err(parse)?;
                        Action::Desktop
                    }
                    4 => Action::Layout(
                        serde_json::from_str::<Object<Layout>>(raw.get())
                            .map_err(parse)?
                            .0,
                    ),
                    _ => Action::Remap(
                        serde_json::from_str::<Object<Remap>>(raw.get())
                            .map_err(parse)?
                            .0,
                    ),
                })
            }
        }
        d.deserialize_map(Map(PhantomData))
    }
}
#[derive(Deserialize)]
struct Rule<'a> {
    #[serde(borrow)]
    id: Text<'a>,
    #[serde(borrow)]
    name: Text<'a>,
    source: Object<Combination>,
    #[serde(borrow)]
    action: Action<'a>,
    #[serde(rename = "isEnabled")]
    enabled: bool,
}
fn uuid(text: &str) -> Option<Uuid> {
    if !versioned::valid_uuid(text) {
        return None;
    }
    let mut bytes = [0; 16];
    let mut position = 0;
    for (i, pair) in text
        .as_bytes()
        .iter()
        .copied()
        .filter(|b| *b != b'-')
        .enumerate()
    {
        let value = (pair as char).to_digit(16)? as u8;
        if i % 2 == 0 {
            bytes[position] = value << 4;
        } else {
            bytes[position] |= value;
            position += 1;
        }
    }
    Some(Uuid { bytes })
}
pub struct Decoded {
    rows: Vec<Row>,
    bytes: Vec<u8>,
    status: u32,
}
impl Decoded {
    fn text(&mut self, value: &str) -> Span {
        let start = self.bytes.len();
        self.bytes.extend_from_slice(value.as_bytes());
        Span {
            start,
            length: value.len(),
        }
    }
}
impl Decoded {
    fn append(&mut self, rule: Rule<'_>) -> Result<(), serde_json::Error> {
        let invalid = || <serde_json::Error as de::Error>::custom("invalid shortcut field");
        let mut row = Row {
            id: uuid(&rule.id).ok_or_else(invalid)?,
            source: rule.source.0.key(),
            target: Key::default(),
            name: self.text(&rule.name),
            display_name: Span::default(),
            bundle: Span::default(),
            path: Span::default(),
            kind: 0,
            enabled: u8::from(rule.enabled),
            bundle_present: 0,
            mode: 0,
            layout: 0,
            use_finder: 0,
        };
        match rule.action {
            Action::Application(value) => {
                row.mode = match value.mode.as_ref() {
                    "activateExisting" => 0,
                    "newWindow" => 1,
                    _ => return Err(invalid()),
                };
                row.display_name = self.text(&value.target.0.name);
                row.path = self.text(&value.target.0.path);
                if let Some(bundle) = value.target.0.bundle {
                    row.bundle_present = 1;
                    row.bundle = self.text(&bundle);
                }
            }
            Action::Finder(value) => {
                row.kind = 1;
                row.path = self.text(&value.path);
            }
            Action::Terminal(value) => {
                row.kind = 2;
                row.path = self.text(&value.path);
                row.use_finder = u8::from(value.use_finder);
            }
            Action::Desktop => row.kind = 3,
            Action::Layout(value) => {
                row.kind = 4;
                row.layout = match value._0.as_ref() {
                    "leftHalf" => 0,
                    "rightHalf" => 1,
                    "topHalf" => 2,
                    "bottomHalf" => 3,
                    "topLeft" => 4,
                    "topRight" => 5,
                    "bottomLeft" => 6,
                    "bottomRight" => 7,
                    _ => return Err(invalid()),
                };
            }
            Action::Remap(value) => {
                row.kind = 5;
                row.target = value.to.0.key();
            }
        }
        self.rows.push(row);
        Ok(())
    }
}
impl<'de> Deserialize<'de> for Decoded {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Sequence;
        impl<'de> Visitor<'de> for Sequence {
            type Value = Decoded;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a rule array")
            }
            fn visit_seq<S: de::SeqAccess<'de>>(
                self,
                mut sequence: S,
            ) -> Result<Self::Value, S::Error> {
                let mut output = Decoded {
                    rows: Vec::new(),
                    bytes: Vec::new(),
                    status: 0,
                };
                while let Some(Object(rule)) = sequence.next_element::<Object<Rule>>()? {
                    output.append(rule).map_err(de::Error::custom)?;
                }
                Ok(output)
            }
        }
        d.deserialize_seq(Sequence)
    }
}
fn decode(bytes: &[u8]) -> Result<Decoded, serde_json::Error> {
    serde_json::from_slice(bytes)
}
#[repr(C)]
pub struct View {
    pub rows: *const Row,
    pub count: usize,
    pub bytes: Bytes,
    pub status: u32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_decode(bytes: Bytes) -> *mut Decoded {
    let result = unsafe { bytes.slice() }
        .filter(|b| json::native_depth_supported(b))
        .and_then(|b| json::with_first_wins(b, decode).ok());
    Box::into_raw(Box::new(result.unwrap_or_else(|| Decoded {
        rows: Vec::new(),
        bytes: Vec::new(),
        status: 2,
    })))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_decoded_view(handle: *const Decoded) -> View {
    match unsafe { handle.as_ref() } {
        Some(value) => View {
            rows: value.rows.as_ptr(),
            count: value.rows.len(),
            bytes: Bytes {
                data: value.bytes.as_ptr(),
                length: value.bytes.len(),
            },
            status: value.status,
        },
        None => View {
            rows: std::ptr::null(),
            count: 0,
            bytes: Bytes {
                data: std::ptr::null(),
                length: 0,
            },
            status: 2,
        },
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_decoded_destroy(handle: *mut Decoded) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const BASE: &str = r#"[{"id":"01234567-89ab-cdef-0123-456789abcdef","name":"synthetic","source":{"keyCode":45,"modifiers":255},"action":{"showDesktop":{}},"isEnabled":true}]"#;
    #[test]
    fn unsigned_fields_are_exact_and_bounded() {
        for (text, value) in [
            ("45", Some(45)),
            ("45.000", Some(45)),
            ("4.5e1", Some(45)),
            ("-0", Some(0)),
            ("0e999999", Some(0)),
            ("6.5535e4", Some(65535)),
            ("65536", None),
            ("-1", None),
            ("1.0000000000000001", None),
            ("0.0000000000000001", None),
            ("1e999999", None),
            ("1e-999999", None),
            ("\"1\"", None),
        ] {
            assert_eq!(unsigned(text, 65535), value, "{text}");
        }
        assert_eq!(unsigned("256", 255), None);
    }
    #[test]
    fn owned_output_survives_input_and_checks_invalid_handles() {
        let input = BASE.as_bytes().to_vec();
        let handle = unsafe {
            aether_rule_decode(Bytes {
                data: input.as_ptr(),
                length: input.len(),
            })
        };
        drop(input);
        let view = unsafe { aether_rule_decoded_view(handle) };
        assert_eq!(view.status, 0);
        assert_eq!(view.count, 1);
        let row = unsafe { *view.rows };
        let arena = unsafe { view.bytes.slice().unwrap() };
        assert_eq!(row.name.text(arena), Some("synthetic"));
        assert_eq!(row.source.modifiers, 15);
        assert_eq!(
            row.id.bytes,
            [
                1, 35, 69, 103, 137, 171, 205, 239, 1, 35, 69, 103, 137, 171, 205, 239
            ]
        );
        unsafe { aether_rule_decoded_destroy(handle) };
        let view = unsafe { aether_rule_decoded_view(std::ptr::null()) };
        assert_eq!(view.status, 2);
        unsafe { aether_rule_decoded_destroy(std::ptr::null_mut()) };
        let handle = unsafe {
            aether_rule_decode(Bytes {
                data: std::ptr::null(),
                length: 1,
            })
        };
        assert_eq!(unsafe { aether_rule_decoded_view(handle) }.status, 2);
        unsafe { aether_rule_decoded_destroy(handle) };
    }
    #[test]
    fn duplicates_unknown_keys_and_streaming_failure() {
        let duplicate = BASE.replace("\"name\":\"synthetic\"", "\"name\":\"first\",\"name\":null");
        let decoded = json::with_first_wins(duplicate.as_bytes(), decode).unwrap();
        assert_eq!(decoded.rows[0].name.text(&decoded.bytes), Some("first"));
        let unknown = BASE.replace(
            "\"showDesktop\":{}",
            "\"unknown\":[],\"showDesktop\":{},\"showDesktop\":null",
        );
        assert!(decode(unknown.as_bytes()).is_ok());
        let invalid = BASE.replace(
            "\"source\":{\"keyCode\":45,\"modifiers\":255}",
            "\"source\":[45,255]",
        );
        assert!(decode(invalid.as_bytes()).is_err());
        let partial = format!("[{},{{}}]", &BASE[1..BASE.len() - 1]);
        assert!(decode(partial.as_bytes()).is_err());
    }
}
