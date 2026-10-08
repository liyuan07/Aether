// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::{
    abi::Bytes,
    storage::{self, Buffer},
    versioned,
};
use serde::{Deserialize, Serialize};
use std::{ffi::c_char, path::PathBuf};
#[derive(Clone, Serialize, Deserialize)]
struct Configuration {
    #[serde(rename = "baseURL")]
    base_url: String,
    model: String,
    #[serde(rename = "systemPrompt")]
    system_prompt: String,
    #[serde(rename = "saveHistory")]
    save_history: bool,
    #[serde(rename = "historyLimit", deserialize_with = "versioned::integer")]
    history_limit: i64,
    #[serde(
        rename = "credentialFingerprint",
        skip_serializing_if = "Option::is_none"
    )]
    credential_fingerprint: Option<String>,
}
#[derive(Serialize, Deserialize)]
struct Entry {
    id: String,
    #[serde(rename = "createdAt")]
    created_at: f64,
    original: String,
    optimized: String,
    model: String,
}
impl Entry {
    fn valid(&self) -> bool {
        versioned::valid_uuid(&self.id) && self.created_at.is_finite()
    }
}
pub struct Store {
    directory: PathBuf,
    blocked: [bool; 2],
    fallback: Configuration,
}
impl Store {
    fn load_configuration(&mut self) -> Result<Configuration, u32> {
        let value = versioned::read::<Configuration>(&self.directory.join("configuration.json"));
        match value {
            Ok(Some(value)) if !(1..=1000).contains(&value.history_limit) => {
                self.blocked[0] = true;
                Err(5)
            }
            Ok(Some(value)) => {
                self.blocked[0] = false;
                Ok(value)
            }
            Ok(None) => {
                self.blocked[0] = false;
                Ok(self.fallback.clone())
            }
            Err(e) => {
                self.blocked[0] = true;
                Err(e)
            }
        }
    }
    fn load_history(&mut self) -> Result<Vec<Entry>, u32> {
        match versioned::read::<Vec<Entry>>(&self.directory.join("history.json")) {
            Ok(value) => {
                let entries = value.unwrap_or_default();
                if !entries.iter().all(Entry::valid) {
                    self.blocked[1] = true;
                    return Err(2);
                }
                self.blocked[1] = false;
                Ok(entries)
            }
            Err(e) => {
                self.blocked[1] = true;
                Err(e)
            }
        }
    }
}
/// # Safety
/// Directory and fallback are readable for their C/string spans. Calls on the handle are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_store_create(
    directory: *const c_char,
    fallback: Bytes,
) -> *mut Store {
    let (Some(directory), Some(bytes)) = (unsafe { storage::path(directory) }, unsafe {
        fallback.slice()
    }) else {
        return std::ptr::null_mut();
    };
    let Ok(fallback) = serde_json::from_slice::<Configuration>(bytes) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(Store {
        directory: directory.to_path_buf(),
        blocked: [false; 2],
        fallback,
    }))
}
/// # Safety
/// Free a live store exactly once after all calls finish; null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_store_destroy(store: *mut Store) {
    if !store.is_null() {
        drop(unsafe { Box::from_raw(store) });
    }
}
fn output<T: Serialize>(result: Result<T, u32>) -> *mut Buffer {
    match result {
        Ok(value) => match serde_json::to_vec(&value) {
            Ok(bytes) => storage::buffer(bytes, 0),
            Err(_) => storage::buffer(vec![], 2),
        },
        Err(e) => storage::buffer(vec![], e),
    }
}
/// # Safety
/// Store is live and exclusively borrowed; output owns its JSON bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_store_load(store: *mut Store, slot: u32) -> *mut Buffer {
    if store.is_null() {
        return storage::buffer(vec![], 2);
    }
    let s = unsafe { &mut *store };
    match slot {
        0 => output(s.load_configuration()),
        1 => output(s.load_history()),
        _ => storage::buffer(vec![], 2),
    }
}
/// # Safety
/// Store is live, data is readable for its span; calls on the handle are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_store_save(
    store: *mut Store,
    slot: u32,
    data: Bytes,
) -> u32 {
    if store.is_null() {
        return 3;
    }
    let Some(bytes) = (unsafe { data.slice() }) else {
        return 3;
    };
    let s = unsafe { &mut *store };
    let result = match slot {
        0 => {
            let Ok(value) = serde_json::from_slice::<Configuration>(bytes) else {
                return 3;
            };
            if !(1..=1000).contains(&value.history_limit) {
                return 5;
            }
            if s.blocked[0] {
                return 2;
            }
            s.load_configuration().and_then(|_| {
                versioned::write(&s.directory.join("configuration.json"), &value, true)
            })
        }
        1 => {
            let Ok(value) = serde_json::from_slice::<Vec<Entry>>(bytes) else {
                return 3;
            };
            if !value.iter().all(Entry::valid) {
                return 3;
            }
            if s.blocked[1] {
                return 2;
            }
            s.load_history()
                .and_then(|_| versioned::write(&s.directory.join("history.json"), &value, true))
        }
        _ => Err(3),
    };
    result.err().unwrap_or(0)
}

// Typed read snapshots own decoded records; no serialized intermediate JSON is needed by native DTOs.
enum Records {
    Configuration(Configuration),
    History(Vec<Entry>),
    Error,
}
pub struct Decoded {
    records: Records,
    status: u32,
}
#[repr(C)]
pub struct ConfigurationView {
    base_url: Bytes,
    model: Bytes,
    system_prompt: Bytes,
    credential_fingerprint: Bytes,
    history_limit: i64,
    save_history: u8,
    has_fingerprint: u8,
}
#[repr(C)]
pub struct EntryView {
    id: Bytes,
    original: Bytes,
    optimized: Bytes,
    model: Bytes,
    created_at: f64,
}
fn text_view(value: &str) -> Bytes {
    Bytes {
        data: value.as_ptr(),
        length: value.len(),
    }
}
fn empty_text() -> Bytes {
    Bytes {
        data: std::ptr::null(),
        length: 0,
    }
}
/// # Safety
/// Store is live and exclusively borrowed. Returned snapshot is independent of the store.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_store_load_decoded(
    store: *mut Store,
    slot: u32,
) -> *mut Decoded {
    let result = if let Some(store) = unsafe { store.as_mut() } {
        match slot {
            0 => store.load_configuration().map(Records::Configuration),
            1 => store.load_history().map(Records::History),
            _ => Err(2),
        }
    } else {
        Err(2)
    };
    let decoded = match result {
        Ok(records) => Decoded { records, status: 0 },
        Err(status) => Decoded {
            records: Records::Error,
            status,
        },
    };
    Box::into_raw(Box::new(decoded))
}
/// # Safety
/// Snapshot is live or null; all views borrow only until it is destroyed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_decoded_status(decoded: *const Decoded) -> u32 {
    unsafe { decoded.as_ref() }.map_or(2, |value| value.status)
}
/// # Safety
/// Snapshot is live or null. Wrong slot returns an empty view.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_decoded_configuration(
    decoded: *const Decoded,
) -> ConfigurationView {
    if let Some(Decoded {
        records: Records::Configuration(value),
        ..
    }) = unsafe { decoded.as_ref() }
    {
        ConfigurationView {
            base_url: text_view(&value.base_url),
            model: text_view(&value.model),
            system_prompt: text_view(&value.system_prompt),
            credential_fingerprint: value
                .credential_fingerprint
                .as_deref()
                .map(text_view)
                .unwrap_or_else(empty_text),
            history_limit: value.history_limit,
            save_history: u8::from(value.save_history),
            has_fingerprint: u8::from(value.credential_fingerprint.is_some()),
        }
    } else {
        ConfigurationView {
            base_url: empty_text(),
            model: empty_text(),
            system_prompt: empty_text(),
            credential_fingerprint: empty_text(),
            history_limit: 0,
            save_history: 0,
            has_fingerprint: 0,
        }
    }
}
/// # Safety
/// Snapshot is live or null; configuration/error snapshots have zero history entries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_decoded_count(decoded: *const Decoded) -> usize {
    if let Some(Decoded {
        records: Records::History(value),
        ..
    }) = unsafe { decoded.as_ref() }
    {
        value.len()
    } else {
        0
    }
}
/// # Safety
/// Snapshot is live or null. Out-of-range and wrong-slot calls return an empty view.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_decoded_entry(
    decoded: *const Decoded,
    index: usize,
) -> EntryView {
    if let Some(Decoded {
        records: Records::History(value),
        ..
    }) = unsafe { decoded.as_ref() }
    {
        if let Some(value) = value.get(index) {
            return EntryView {
                id: text_view(&value.id),
                original: text_view(&value.original),
                optimized: text_view(&value.optimized),
                model: text_view(&value.model),
                created_at: value.created_at,
            };
        }
    }
    EntryView {
        id: empty_text(),
        original: empty_text(),
        optimized: empty_text(),
        model: empty_text(),
        created_at: 0.,
    }
}
/// # Safety
/// Destroy a live snapshot once after all borrowed views are consumed. Null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_decoded_destroy(decoded: *mut Decoded) {
    if !decoded.is_null() {
        drop(unsafe { Box::from_raw(decoded) });
    }
}

#[cfg(test)]
mod decoded_tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static ID: AtomicU64 = AtomicU64::new(0);
    fn directory() -> PathBuf {
        std::env::temp_dir().join(format!(
            "aether-prompt-records-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::Relaxed)
        ))
    }
    fn fallback() -> Configuration {
        Configuration {
            base_url: "synthetic://local".into(),
            model: "".into(),
            system_prompt: "合成\0e\u{301}👩‍💻".into(),
            save_history: true,
            history_limit: 200,
            credential_fingerprint: None,
        }
    }
    #[test]
    fn decoded_snapshots_outlive_store_and_file_changes_with_exact_strings_and_bits() {
        let directory = directory();
        let entry = Entry {
            id: "12345678-1234-5678-90ab-1234567890ab".into(),
            created_at: -0.0,
            original: "合成\0e\u{301}".into(),
            optimized: "".into(),
            model: "👩‍💻".into(),
        };
        versioned::write(&directory.join("history.json"), &[entry], true).unwrap();
        let mut store = Store {
            directory: directory.clone(),
            blocked: [false; 2],
            fallback: fallback(),
        };
        let configuration = unsafe { aether_prompt_store_load_decoded(&mut store, 0) };
        let history = unsafe { aether_prompt_store_load_decoded(&mut store, 1) };
        store.fallback.system_prompt.clear();
        drop(store);
        std::fs::write(
            directory.join("history.json"),
            b"invalid synthetic replacement",
        )
        .unwrap();
        unsafe {
            assert_eq!(aether_prompt_decoded_status(configuration), 0);
            let value = aether_prompt_decoded_configuration(configuration);
            assert_eq!(value.system_prompt.text().unwrap(), "合成\0e\u{301}👩‍💻");
            assert_eq!(value.has_fingerprint, 0);
            assert_eq!(aether_prompt_decoded_count(configuration), 0);
            assert_eq!(aether_prompt_decoded_count(history), 1);
            let row = aether_prompt_decoded_entry(history, 0);
            assert_eq!(row.created_at.to_bits(), (-0.0_f64).to_bits());
            assert_eq!(row.original.text().unwrap(), "合成\0e\u{301}");
            assert_eq!(row.optimized.text().unwrap(), "");
            assert_eq!(aether_prompt_decoded_entry(history, 1).id.length, 0);
            assert_eq!(
                aether_prompt_decoded_configuration(history).history_limit,
                0
            );
            aether_prompt_decoded_destroy(configuration);
            aether_prompt_decoded_destroy(history);
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn typed_load_retains_errors_blocking_and_nil_empty_fingerprint_distinction() {
        let directory = directory();
        let mut store = Store {
            directory: directory.clone(),
            blocked: [false; 2],
            fallback: fallback(),
        };
        store.fallback.credential_fingerprint = Some(String::new());
        unsafe {
            let value = aether_prompt_store_load_decoded(&mut store, 0);
            let view = aether_prompt_decoded_configuration(value);
            assert_eq!(view.has_fingerprint, 1);
            assert_eq!(view.credential_fingerprint.length, 0);
            aether_prompt_decoded_destroy(value);
            let empty = aether_prompt_store_load_decoded(&mut store, 1);
            assert_eq!(aether_prompt_decoded_status(empty), 0);
            assert_eq!(aether_prompt_decoded_count(empty), 0);
            aether_prompt_decoded_destroy(empty);
            let invalid = aether_prompt_store_load_decoded(&mut store, 99);
            assert_eq!(aether_prompt_decoded_status(invalid), 2);
            aether_prompt_decoded_destroy(invalid);
            assert_eq!(aether_prompt_decoded_status(std::ptr::null()), 2);
            assert_eq!(aether_prompt_decoded_count(std::ptr::null()), 0);
            aether_prompt_decoded_destroy(std::ptr::null_mut());
        }
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(
            directory.join("history.json"),
            br#"{"schemaVersion":99,"payload":[]}"#,
        )
        .unwrap();
        unsafe {
            let failed = aether_prompt_store_load_decoded(&mut store, 1);
            assert_eq!(aether_prompt_decoded_status(failed), 4);
            assert_eq!(store.blocked, [false, true]);
            aether_prompt_decoded_destroy(failed);
        }
        versioned::write(&directory.join("history.json"), &Vec::<Entry>::new(), true).unwrap();
        unsafe {
            let repaired = aether_prompt_store_load_decoded(&mut store, 1);
            assert_eq!(aether_prompt_decoded_status(repaired), 0);
            aether_prompt_decoded_destroy(repaired);
        }
        assert_eq!(store.blocked, [false, false]);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
