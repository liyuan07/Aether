// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::{
    ffi::{CStr, OsStr, c_char},
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};
static TEMP_ID: AtomicU64 = AtomicU64::new(0);
pub struct Buffer {
    bytes: Vec<u8>,
    status: u32,
}
#[repr(C)]
pub struct BufferView {
    pub bytes: *mut u8,
    pub length: usize,
    pub status: u32,
}
pub fn buffer(bytes: Vec<u8>, status: u32) -> *mut Buffer {
    Box::into_raw(Box::new(Buffer { bytes, status }))
}
pub unsafe fn path<'a>(raw: *const c_char) -> Option<&'a Path> {
    if raw.is_null() {
        return None;
    }
    Some(Path::new(OsStr::from_bytes(
        unsafe { CStr::from_ptr(raw) }.to_bytes(),
    )))
}
pub fn read(path: &Path, reject_links: bool) -> io::Result<Option<Vec<u8>>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if reject_links && metadata.file_type().is_symlink() => {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
        _ => {}
    }
    fs::read(path).map(Some)
}
struct Temporary(PathBuf);
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
pub fn write(path: &Path, bytes: &[u8], private: bool, synchronize: bool) -> io::Result<()> {
    let directory = path
        .parent()
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    fs::create_dir_all(directory)?;
    if private {
        if !fs::symlink_metadata(directory)?.file_type().is_dir() {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
    }
    let mode = if private {
        0o600
    } else {
        fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o777)
            .unwrap_or(0o666)
    };
    for _ in 0..32 {
        let temporary = directory.join(format!(
            ".aether.{}.{}.tmp",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temporary)
        {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        };
        let temporary = Temporary(temporary);
        file.write_all(bytes)?;
        if synchronize {
            file.sync_all()?;
        }
        drop(file);
        fs::rename(&temporary.0, path)?;
        return Ok(());
    }
    Err(io::Error::from(io::ErrorKind::AlreadyExists))
}
/// # Safety
/// Path is a readable NUL-terminated OS path. Output owns bytes until buffer_destroy.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_file_read(raw: *const c_char, reject_links: u8) -> *mut Buffer {
    let Some(path) = (unsafe { path(raw) }) else {
        return buffer(vec![], 2);
    };
    match read(path, reject_links != 0) {
        Ok(Some(bytes)) => buffer(bytes, 0),
        Ok(None) => buffer(vec![], 1),
        Err(_) => buffer(vec![], 2),
    }
}
/// # Safety
/// Path is NUL-terminated; bytes are readable for length bytes during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_file_write(
    raw: *const c_char,
    bytes: *const u8,
    length: usize,
    private: u8,
    synchronize: u8,
) -> u32 {
    let Some(path) = (unsafe { path(raw) }) else {
        return 3;
    };
    if length != 0 && bytes.is_null() {
        return 3;
    }
    let bytes = if length == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, length) }
    };
    if write(path, bytes, private != 0, synchronize != 0).is_ok() {
        0
    } else {
        3
    }
}
/// # Safety
/// Handle is live; returned bytes are borrowed until buffer_destroy and never mutated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_buffer_view(handle: *mut Buffer) -> BufferView {
    if handle.is_null() {
        return BufferView {
            bytes: std::ptr::null_mut(),
            length: 0,
            status: 2,
        };
    }
    let buffer = unsafe { &mut *handle };
    BufferView {
        bytes: buffer.bytes.as_mut_ptr(),
        length: buffer.bytes.len(),
        status: buffer.status,
    }
}
/// # Safety
/// Destroy a live buffer exactly once; null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_buffer_destroy(handle: *mut Buffer) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
