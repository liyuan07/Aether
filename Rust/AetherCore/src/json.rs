// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use serde::Deserialize;
use std::{borrow::Cow, collections::HashSet};
// Unescaped JSON strings borrow the file buffer; only escaped strings require an owned decode.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Text<'a>(pub Cow<'a, str>);
impl serde::Serialize for Text<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_ref())
    }
}
impl std::ops::Deref for Text<'_> {
    type Target = str;
    fn deref(&self) -> &str {
        &self.0
    }
}
impl AsRef<str> for Text<'_> {
    fn as_ref(&self) -> &str {
        &self.0
    }
}
impl<'de: 'a, 'a> Deserialize<'de> for Text<'a> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Visitor<'a>(std::marker::PhantomData<&'a str>);
        impl<'de: 'a, 'a> serde::de::Visitor<'de> for Visitor<'a> {
            type Value = Text<'a>;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a string")
            }
            fn visit_borrowed_str<E: serde::de::Error>(
                self,
                v: &'de str,
            ) -> Result<Self::Value, E> {
                Ok(Text(Cow::Borrowed(v)))
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(Text(Cow::Owned(v.to_owned())))
            }
            fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Self::Value, E> {
                Ok(Text(Cow::Owned(v)))
            }
        }
        d.deserialize_str(Visitor(std::marker::PhantomData))
    }
}

struct Object<'a> {
    fields: Vec<(Text<'a>, &'a serde_json::value::RawValue)>,
    duplicate: bool,
}
impl<'de: 'a, 'a> Deserialize<'de> for Object<'a> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Visitor<'a>(std::marker::PhantomData<&'a str>);
        impl<'de: 'a, 'a> serde::de::Visitor<'de> for Visitor<'a> {
            type Value = Object<'a>;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> Result<Self::Value, M::Error> {
                let mut fields = Vec::new();
                let mut seen = HashSet::new();
                let mut duplicate = false;
                while let Some(key) = map.next_key::<Text<'a>>()? {
                    let value = map.next_value::<&'de serde_json::value::RawValue>()?;
                    if seen.insert(key.clone()) {
                        fields.push((key, value));
                    } else {
                        duplicate = true;
                    }
                }
                Ok(Object { fields, duplicate })
            }
        }
        d.deserialize_map(Visitor(std::marker::PhantomData))
    }
}
// JSONDecoder uses the first occurrence of a key. Normalize only the exceptional duplicate-key path.
fn normalize(raw: &serde_json::value::RawValue) -> Result<Cow<'_, str>, serde_json::Error> {
    let value = raw.get();
    if value.starts_with('{') {
        let object: Object = serde_json::from_str(value)?;
        let mut changed = object.duplicate;
        let mut fields = Vec::with_capacity(object.fields.len());
        for (key, value) in object.fields {
            let value = normalize(value)?;
            changed |= matches!(value, Cow::Owned(_));
            fields.push((key, value));
        }
        if !changed {
            return Ok(Cow::Borrowed(value));
        }
        let mut out = String::from("{");
        for (i, (key, value)) in fields.into_iter().enumerate() {
            if i != 0 {
                out.push(',');
            }
            out.push_str(&serde_json::to_string(key.as_ref())?);
            out.push(':');
            out.push_str(&value);
        }
        out.push('}');
        Ok(Cow::Owned(out))
    } else if value.starts_with('[') {
        let rows: Vec<&serde_json::value::RawValue> = serde_json::from_str(value)?;
        let mut changed = false;
        let mut values = Vec::with_capacity(rows.len());
        for value in rows {
            let value = normalize(value)?;
            changed |= matches!(value, Cow::Owned(_));
            values.push(value);
        }
        if !changed {
            return Ok(Cow::Borrowed(value));
        }
        let mut out = String::from("[");
        for (i, value) in values.into_iter().enumerate() {
            if i != 0 {
                out.push(',');
            }
            out.push_str(&value);
        }
        out.push(']');
        Ok(Cow::Owned(out))
    } else {
        Ok(Cow::Borrowed(value))
    }
}
// Foundation rejects JSON deeper than 512 containers, including ignored fields.
// Count structural bytes outside strings without decoding or copying their contents.
pub fn native_depth_supported(bytes: &[u8]) -> bool {
    let mut depth = 0_usize;
    let mut quoted = false;
    let mut escaped = false;
    for &byte in bytes {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else {
            match byte {
                b'"' => quoted = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth > 512 {
                        return false;
                    }
                }
                b'}' | b']' => depth = depth.saturating_sub(1),
                _ => (),
            }
        }
    }
    true
}
pub fn with_first_wins<T>(
    bytes: &[u8],
    decode: impl Fn(&[u8]) -> Result<T, serde_json::Error>,
) -> Result<T, serde_json::Error> {
    match decode(bytes) {
        Err(e) if e.to_string().starts_with("duplicate field ") => {
            let raw: &serde_json::value::RawValue = serde_json::from_slice(bytes)?;
            let normalized = normalize(raw)?;
            decode(normalized.as_bytes())
        }
        result => result,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unescaped_strings_borrow_and_escaped_strings_decode() {
        let text: Text = serde_json::from_slice(br#""synthetic plain""#).unwrap();
        assert!(matches!(text.0, Cow::Borrowed("synthetic plain")));
        let text: Text = serde_json::from_slice(br#""synthetic\nline""#).unwrap();
        assert!(matches!(text.0, Cow::Owned(_)));
        assert_eq!(text.as_ref(), "synthetic\nline");
    }
}
