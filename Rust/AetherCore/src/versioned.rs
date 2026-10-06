// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::storage;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::path::Path;
#[derive(Deserialize)]
struct Envelope<'a> {
    #[serde(rename = "schemaVersion")]
    version: serde_json::Number,
    #[serde(default, borrow)]
    payload: Option<&'a serde_json::value::RawValue>,
}
pub fn read<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, u32> {
    let Some(bytes) = storage::read(path, true).map_err(|_| 2_u32)? else {
        return Ok(None);
    };
    let envelope: Envelope = serde_json::from_slice(&bytes).map_err(|_| 2_u32)?;
    let version = envelope.version.as_f64().ok_or(2_u32)?;
    if !version.is_finite()
        || version.fract() != 0.0
        || version < i64::MIN as f64
        || version >= -(i64::MIN as f64)
    {
        return Err(2);
    }
    if version != 1.0 {
        return Err(4);
    }
    serde_json::from_str(envelope.payload.ok_or(2_u32)?.get())
        .map(Some)
        .map_err(|_| 2_u32)
}
pub fn write<T: Serialize + ?Sized>(
    path: &Path,
    payload: &T,
    synchronize: bool,
) -> Result<(), u32> {
    #[derive(Serialize)]
    struct Envelope<'a, T: ?Sized> {
        #[serde(rename = "schemaVersion")]
        version: u32,
        payload: &'a T,
    }
    let bytes = serde_json::to_vec_pretty(&Envelope {
        version: 1,
        payload,
    })
    .map_err(|_| 3_u32)?;
    storage::write(path, &bytes, true, synchronize).map_err(|_| 3_u32)
}
pub fn valid_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                *b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

// Foundation's Int decoder accepts integral JSON decimal/exponent representations.
pub fn integer<'de, D: serde::Deserializer<'de>>(decoder: D) -> Result<i64, D::Error> {
    let number = serde_json::Number::deserialize(decoder)?;
    if let Some(value) = number.as_i64() {
        return Ok(value);
    }
    let value = number
        .as_f64()
        .ok_or_else(|| serde::de::Error::custom("invalid integer"))?;
    if value.is_finite()
        && value.fract() == 0.0
        && value >= i64::MIN as f64
        && value < -(i64::MIN as f64)
    {
        Ok(value as i64)
    } else {
        Err(serde::de::Error::custom("invalid integer"))
    }
}
