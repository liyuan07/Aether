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
