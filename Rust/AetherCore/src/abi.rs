// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
// Feature-independent borrowing and identity types for the C ABI.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Bytes {
    pub data: *const u8,
    pub length: usize,
}
impl Bytes {
    /// Caller guarantees readable memory for length bytes during the borrow.
    pub unsafe fn slice<'a>(self) -> Option<&'a [u8]> {
        if self.length == 0 {
            Some(&[])
        } else if self.data.is_null() {
            None
        } else {
            Some(unsafe { std::slice::from_raw_parts(self.data, self.length) })
        }
    }
    pub unsafe fn text<'a>(self) -> Option<&'a str> {
        std::str::from_utf8(unsafe { self.slice()? }).ok()
    }
}
#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Uuid {
    pub bytes: [u8; 16],
}
