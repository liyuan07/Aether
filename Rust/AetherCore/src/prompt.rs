// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::abi::{Bytes, Uuid};
use crate::storage::{self, Buffer};
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
struct Message<'a> {
    role: &'a str,
    content: &'a str,
}
#[derive(Serialize)]
struct Request<'a> {
    model: &'a str,
    messages: [Message<'a>; 2],
    stream: bool,
}
/// # Safety
/// All UTF-8 spans remain readable during this call; the returned buffer owns JSON.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_request(
    model: Bytes,
    rules: Bytes,
    input: Bytes,
) -> *mut Buffer {
    let (Some(model), Some(rules), Some(input)) =
        (unsafe { model.text() }, unsafe { rules.text() }, unsafe {
            input.text()
        })
    else {
        return storage::buffer(vec![], 107);
    };
    if model.is_empty() {
        return storage::buffer(vec![], 111);
    }
    if rules.is_empty() {
        return storage::buffer(vec![], 112);
    }
    let request = Request {
        model,
        messages: [
            Message {
                role: "system",
                content: rules,
            },
            Message {
                role: "user",
                content: input,
            },
        ],
        stream: false,
    };
    match serde_json::to_vec(&request) {
        Ok(bytes) => storage::buffer(bytes, 0),
        Err(_) => storage::buffer(vec![], 107),
    }
}
#[derive(Deserialize)]
struct Response {
    choices: Vec<Choice>,
}
#[derive(Deserialize)]
struct Choice {
    message: ResponseMessage,
    finish_reason: Option<String>,
}
#[derive(Deserialize)]
struct ResponseMessage {
    content: Option<Content>,
    refusal: Option<String>,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum Content {
    String(String),
    Parts(Vec<Part>),
}
#[derive(Deserialize)]
struct Part {
    r#type: String,
    text: Option<String>,
}
/// # Safety
/// Response bytes are readable for the span length; no diagnostic body is returned on failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_response(status: i32, body: Bytes) -> *mut Buffer {
    let error = match status {
        200..=299 => 0,
        300..=399 => 100,
        401 | 403 => 101,
        404 => 102,
        408 | 504 => 103,
        429 => 104,
        500..=599 => 105,
        _ => 106,
    };
    if error != 0 {
        return storage::buffer(vec![], error);
    }
    let Some(bytes) = (unsafe { body.slice() }) else {
        return storage::buffer(vec![], 107);
    };
    let Ok(response) = serde_json::from_slice::<Response>(bytes) else {
        return storage::buffer(vec![], 107);
    };
    let Some(choice) = response.choices.into_iter().next() else {
        return storage::buffer(vec![], 107);
    };
    if let Some(reason) = choice.finish_reason {
        match reason.as_str() {
            "stop" => {}
            "content_filter" => return storage::buffer(vec![], 109),
            _ => return storage::buffer(vec![], 108),
        }
    }
    if choice.message.refusal.is_some_and(|s| !s.is_empty()) {
        return storage::buffer(vec![], 109);
    }
    let text = match choice.message.content {
        None => String::new(),
        Some(Content::String(s)) => s,
        Some(Content::Parts(parts)) => parts
            .into_iter()
            .filter(|p| p.r#type == "text" || p.r#type == "output_text")
            .filter_map(|p| p.text)
            .collect::<Vec<_>>()
            .join("\n"),
    };
    storage::buffer(text.into_bytes(), 0)
}
/// URLComponents remains the native URL parser; policy and API path mapping live here.
/// # Safety
/// Both spans are valid UTF-8 and readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_endpoint(
    scheme: u8,
    host: Bytes,
    path: Bytes,
) -> *mut Buffer {
    let (Some(host), Some(path)) = (unsafe { host.text() }, unsafe { path.text() }) else {
        return storage::buffer(vec![], 114);
    };
    if scheme != 1 && scheme != 2 {
        return storage::buffer(vec![], 114);
    }
    let loopback = host == "localhost" || host == "::1" || host == "[::1]" || {
        let parts: Vec<_> = host.split('.').collect();
        parts.len() == 4
            && parts[0] == "127"
            && parts.iter().all(|p| {
                !p.is_empty()
                    && p.bytes().all(|b| b.is_ascii_digit())
                    && p.parse::<u16>().is_ok_and(|n| n <= 255)
            })
    };
    if scheme == 1 && !loopback {
        return storage::buffer(vec![], 115);
    }
    let path = path.trim_end_matches('/');
    let path = if path.is_empty() {
        "/v1/chat/completions".to_owned()
    } else if path.ends_with("/chat/completions") {
        path.to_owned()
    } else {
        format!("{path}/chat/completions")
    };
    storage::buffer(path.into_bytes(), 0)
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Gate {
    pub generation: u64,
    pub active: u8,
    pub writable: u8,
    pub changed: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_begin(mut s: Gate) -> Gate {
    s.generation = s.generation.wrapping_add(1).max(1);
    s.active = 1;
    s.changed = 1;
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_cancel(mut s: Gate) -> Gate {
    s.active = 0;
    s.changed = 1;
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_finish(mut s: Gate, token: u64, acceptable: u8) -> Gate {
    s.changed = 0;
    if s.active != 0 && s.generation == token && acceptable != 0 {
        s.active = 0;
        s.changed = 1;
    }
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_history_writable(mut s: Gate, writable: u8) -> Gate {
    s.writable = u8::from(writable != 0);
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_limit(limit: isize) -> isize {
    limit.clamp(1, 1000)
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_prompt_credential_consistent(
    fingerprint_present: u8,
    key_empty: u8,
    matches: u8,
) -> u8 {
    u8::from(if fingerprint_present == 0 {
        key_empty != 0
    } else {
        matches != 0
    })
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HistoryRow {
    pub id: Uuid,
    pub timestamp: f64,
    pub matched: u8,
}
/// # Safety
/// Rows are readable for count elements; output is writable for capacity indices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_prompt_history_plan(
    rows: *const HistoryRow,
    count: usize,
    action: u32,
    id: Uuid,
    limit: usize,
    output: *mut usize,
    capacity: usize,
) -> usize {
    if count == 0 || rows.is_null() {
        return 0;
    }
    let rows = unsafe { std::slice::from_raw_parts(rows, count) };
    let mut indices: Vec<usize> = (0..count)
        .filter(|&i| match action {
            1 => rows[i].id != id,
            3 => rows[i].matched != 0,
            _ => true,
        })
        .collect();
    if action == 0 {
        indices.sort_by(|&a, &b| {
            rows[b]
                .timestamp
                .partial_cmp(&rows[a].timestamp)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }
    if action == 2 {
        indices.truncate(limit);
    }
    if capacity >= indices.len() && !output.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(indices.as_ptr(), output, indices.len());
        }
    }
    indices.len()
}
