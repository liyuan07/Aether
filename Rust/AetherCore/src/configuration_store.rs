// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Serialized configuration persistence, recoverable paired replacement and stale-save rejection.
use crate::{abi::Bytes, storage};
use serde::{Deserialize, Serialize};
use std::{
    borrow::Cow,
    ffi::c_char,
    fs, io,
    os::unix::fs::{MetadataExt, PermissionsExt, symlink},
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};
// All handles share the filesystem lock. Aether has a single formal process; no cross-process lock.
static DISK: Mutex<()> = Mutex::new(());
static LINK_ID: AtomicU64 = AtomicU64::new(0);
#[derive(Serialize, Deserialize)]
enum Original {
    Missing,
    File { bytes: Vec<u8>, mode: u32 },
    Link(PathBuf),
}
impl Original {
    fn capture(path: &Path) -> io::Result<Self> {
        match fs::symlink_metadata(path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Self::Missing),
            Err(e) => Err(e),
            Ok(m) if m.file_type().is_symlink() => fs::read_link(path).map(Self::Link),
            Ok(m) if m.is_file() => Ok(Self::File {
                bytes: fs::read(path)?,
                mode: m.permissions().mode() & 0o777,
            }),
            _ => Err(invalid()),
        }
    }
    fn matches(&self, path: &Path) -> bool {
        match (self, Self::capture(path)) {
            (Self::Missing, Ok(Self::Missing)) => true,
            (Self::File { bytes: a, mode: am }, Ok(Self::File { bytes: b, mode: bm })) => {
                a == &b && am == &bm
            }
            (Self::Link(a), Ok(Self::Link(b))) => a == &b,
            _ => false,
        }
    }
    fn content_matches(&self, path: &Path) -> bool {
        match (self, Self::capture(path)) {
            (Self::File { bytes: a, .. }, Ok(Self::File { bytes: b, .. })) => a == &b,
            _ => self.matches(path),
        }
    }
    fn restore(&self, path: &Path) -> io::Result<()> {
        match self {
            Self::Missing => match fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            },
            Self::File { bytes, mode } => {
                storage::write(path, bytes, false, true)?;
                fs::set_permissions(path, fs::Permissions::from_mode(*mode))?;
                fs::File::open(path)?.sync_all()?;
            }
            Self::Link(target) => {
                let mut renamed = false;
                for _ in 0..32 {
                    let temporary = path.with_file_name(format!(
                        ".aether-restore-{}-{}",
                        std::process::id(),
                        LINK_ID.fetch_add(1, Ordering::Relaxed)
                    ));
                    match symlink(target, &temporary) {
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                        Err(e) => return Err(e),
                        Ok(()) => {}
                    }
                    let result = fs::rename(&temporary, path);
                    if result.is_err() {
                        let _ = fs::remove_file(&temporary);
                    }
                    result?;
                    renamed = true;
                    break;
                }
                if !renamed {
                    return Err(io::Error::from(io::ErrorKind::AlreadyExists));
                }
            }
        }
        sync_parent(path)
    }
}
#[derive(Serialize, Deserialize)]
struct Journal<'a> {
    version: u8,
    paths: [PathBuf; 2],
    original: [Original; 2],
    replacement: [Cow<'a, [u8]>; 2],
    committed: bool,
}
struct Pair {
    paths: [PathBuf; 2],
    journal: PathBuf,
}
fn invalid() -> io::Error {
    io::Error::from(io::ErrorKind::InvalidData)
}
fn sync_parent(path: &Path) -> io::Result<()> {
    fs::File::open(path.parent().ok_or_else(invalid)?)?.sync_all()
}
fn new_matches(path: &Path, bytes: &[u8]) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
        && fs::read(path).is_ok_and(|b| b == bytes)
}
#[derive(Clone, Copy)]
enum Stage {
    Prepared,
    First,
    Second,
    Committed,
}
impl Pair {
    fn new(paths: [PathBuf; 2]) -> Option<Self> {
        if paths
            .iter()
            .any(|p| !p.is_absolute() || p.file_name().is_none())
            || paths[0] == paths[1]
        {
            return None;
        }
        let mut name = paths[0].file_name()?.to_os_string();
        name.push(".aether-pair-journal");
        let journal = paths[0].with_file_name(name);
        if journal == paths[1] {
            return None;
        }
        Some(Self { paths, journal })
    }
    fn write_journal(&self, journal: &Journal<'_>) -> io::Result<()> {
        if fs::symlink_metadata(&self.journal)
            .is_ok_and(|m| !m.is_file() || m.file_type().is_symlink())
        {
            return Err(invalid());
        }
        let bytes = serde_json::to_vec(journal).map_err(|_| invalid())?;
        storage::write_mode(&self.journal, &bytes, 0o600, true)?;
        // The journal contains original local configuration and is always private.
        fs::set_permissions(&self.journal, fs::Permissions::from_mode(0o600))?;
        fs::File::open(&self.journal)?.sync_all()?;
        sync_parent(&self.journal)
    }
    fn read_journal(&self) -> io::Result<Option<Journal<'static>>> {
        let Some(bytes) = storage::read(&self.journal, true)? else {
            return Ok(None);
        };
        let j: Journal<'static> = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if j.version != 1 || j.paths != self.paths {
            return Err(invalid());
        }
        Ok(Some(j))
    }
    fn remove_journal(&self) -> io::Result<()> {
        fs::remove_file(&self.journal)?;
        sync_parent(&self.journal)
    }
    fn recover(&self) -> io::Result<()> {
        let Some(j) = self.read_journal()? else {
            return Ok(());
        };
        if !j.committed {
            // Refuse recovery if an external change would be destroyed. Validate BOTH before writes.
            for i in 0..2 {
                if !j.original[i].content_matches(&self.paths[i])
                    && !new_matches(&self.paths[i], &j.replacement[i])
                {
                    return Err(invalid());
                }
            }
            for i in 0..2 {
                if !j.original[i].matches(&self.paths[i]) {
                    j.original[i].restore(&self.paths[i])?;
                }
            }
        }
        self.remove_journal()
    }
    fn replace(
        &self,
        replacement: [&[u8]; 2],
        mut stage: impl FnMut(Stage) -> io::Result<()>,
    ) -> io::Result<()> {
        self.recover()?;
        for path in &self.paths {
            fs::create_dir_all(path.parent().ok_or_else(invalid)?)?;
        }
        // Distinct strings may still identify the same destination (directory aliases/hard links).
        let resolved: Vec<_> = self
            .paths
            .iter()
            .map(|p| {
                Ok(fs::canonicalize(p.parent().ok_or_else(invalid)?)?
                    .join(p.file_name().ok_or_else(invalid)?))
            })
            .collect::<io::Result<_>>()?;
        let journal_resolved = fs::canonicalize(self.journal.parent().ok_or_else(invalid)?)?
            .join(self.journal.file_name().ok_or_else(invalid)?);
        if resolved[0] == resolved[1] || resolved[1] == journal_resolved {
            return Err(invalid());
        }
        if let (Ok(a), Ok(b)) = (fs::metadata(&self.paths[0]), fs::metadata(&self.paths[1])) {
            if (a.dev(), a.ino()) == (b.dev(), b.ino()) {
                return Err(invalid());
            }
        }
        let mut j = Journal {
            version: 1,
            paths: self.paths.clone(),
            original: [
                Original::capture(&self.paths[0])?,
                Original::capture(&self.paths[1])?,
            ],
            replacement: replacement.map(Cow::Borrowed),
            committed: false,
        };
        // A flush of already-saved bytes only invalidates delayed snapshots, without extra writes.
        if (0..2).all(|i| matches!(&j.original[i], Original::File { bytes, .. } if bytes.as_slice() == j.replacement[i].as_ref())) { return Ok(()); }
        // No destination has changed until the prepared journal is durable.
        self.write_journal(&j)?;
        let result = (|| {
            stage(Stage::Prepared)?;
            for i in 0..2 {
                storage::write(&self.paths[i], &j.replacement[i], false, true)?;
                sync_parent(&self.paths[i])?;
                stage(if i == 0 { Stage::First } else { Stage::Second })?;
            }
            j.committed = true;
            self.write_journal(&j)
        })();
        if result.is_err() {
            // A commit marker may already be visible when directory synchronization fails.
            if !self.read_journal()?.is_some_and(|v| v.committed) {
                self.recover()?;
                return result;
            }
        }
        stage(Stage::Committed)?;
        // Once marked committed, cleanup failure does not turn a successful import into a failure.
        let _ = self.remove_journal();
        Ok(())
    }
}
pub struct Store {
    pair: Pair,
    tokens: [AtomicU64; 2],
}
impl Store {
    fn save(&self, slot: usize, bytes: &[u8], generation: u64) -> u32 {
        let _disk = DISK.lock().unwrap_or_else(|e| e.into_inner());
        if generation != self.tokens[slot].load(Ordering::Acquire) {
            return 1;
        }
        if self.pair.recover().is_err() {
            return 2;
        }
        if storage::write(&self.pair.paths[slot], bytes, false, false).is_err() {
            return 3;
        }
        0
    }
    fn replace(&self, bytes: [&[u8]; 2]) -> u32 {
        let _disk = DISK.lock().unwrap_or_else(|e| e.into_inner());
        if self.pair.replace(bytes, |_| Ok(())).is_err() {
            return 3;
        }
        for token in &self.tokens {
            token.fetch_add(1, Ordering::AcqRel);
        }
        0
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_create(
    first: *const c_char,
    second: *const c_char,
) -> *mut Store {
    let (Some(a), Some(b)) = (unsafe { storage::path(first) }, unsafe {
        storage::path(second)
    }) else {
        return std::ptr::null_mut();
    };
    Pair::new([a.to_path_buf(), b.to_path_buf()]).map_or(std::ptr::null_mut(), |pair| {
        Box::into_raw(Box::new(Store {
            pair,
            tokens: [AtomicU64::new(0), AtomicU64::new(0)],
        }))
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_recover(store: *const Store) -> u32 {
    let Some(s) = (unsafe { store.as_ref() }) else {
        return 2;
    };
    let _disk = DISK.lock().unwrap_or_else(|e| e.into_inner());
    if s.pair.recover().is_ok() { 0 } else { 2 }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_reserve(store: *const Store, slot: u8) -> u64 {
    unsafe { store.as_ref() }
        .and_then(|s| s.tokens.get(slot as usize))
        .map_or(0, |token| {
            token.fetch_add(1, Ordering::AcqRel).wrapping_add(1)
        })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_current(
    store: *const Store,
    slot: u8,
    generation: u64,
) -> u8 {
    u8::from(
        unsafe { store.as_ref() }
            .and_then(|s| s.tokens.get(slot as usize))
            .is_some_and(|token| token.load(Ordering::Acquire) == generation),
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_save(
    store: *const Store,
    slot: u8,
    bytes: Bytes,
    generation: u64,
) -> u32 {
    let (Some(s), Some(bytes)) = (unsafe { store.as_ref() }, unsafe { bytes.slice() }) else {
        return 3;
    };
    if slot > 1 {
        return 3;
    }
    s.save(slot as usize, bytes, generation)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_replace(
    store: *const Store,
    first: Bytes,
    second: Bytes,
) -> u32 {
    let (Some(s), Some(a), Some(b)) = (
        unsafe { store.as_ref() },
        unsafe { first.slice() },
        unsafe { second.slice() },
    ) else {
        return 3;
    };
    s.replace([a, b])
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_configuration_store_destroy(store: *mut Store) {
    if !store.is_null() {
        drop(unsafe { Box::from_raw(store) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        panic::{AssertUnwindSafe, catch_unwind},
        sync::Arc,
    };
    static TEST_ID: AtomicU64 = AtomicU64::new(0);
    struct Fixture {
        directory: PathBuf,
        pair: Pair,
    }
    impl Fixture {
        fn new() -> Self {
            let directory = std::env::temp_dir().join(format!(
                "aether-pair-{}-{}",
                std::process::id(),
                TEST_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&directory).unwrap();
            let pair = Pair::new([
                directory.join("规则.json"),
                directory.join("other/偏好.json"),
            ])
            .unwrap();
            fs::write(&pair.paths[0], b"old rules\0\xff").unwrap();
            fs::set_permissions(&pair.paths[0], fs::Permissions::from_mode(0o640)).unwrap();
            Self { directory, pair }
        }
        fn new_bytes() -> [Vec<u8>; 2] {
            [b"new rules".to_vec(), b"new prefs".to_vec()]
        }
        fn assert_old(&self) {
            assert_eq!(fs::read(&self.pair.paths[0]).unwrap(), b"old rules\0\xff");
            assert_eq!(
                fs::metadata(&self.pair.paths[0])
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o640
            );
            assert!(!self.pair.paths[1].exists());
            assert!(!self.pair.journal.exists());
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
    #[test]
    fn paired_commit_and_failed_boundaries_restore_binary_originals() {
        for boundary in 0..3 {
            let f = Fixture::new();
            let result = f
                .pair
                .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |s| {
                    if s as usize == boundary {
                        Err(io::Error::from(io::ErrorKind::Other))
                    } else {
                        Ok(())
                    }
                });
            assert!(result.is_err());
            f.assert_old();
        }
        let f = Fixture::new();
        f.pair
            .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |_| {
                Ok(())
            })
            .unwrap();
        for i in 0..2 {
            assert_eq!(fs::read(&f.pair.paths[i]).unwrap(), Fixture::new_bytes()[i]);
        }
        assert!(!f.pair.journal.exists());
        let inodes: Vec<_> = f
            .pair
            .paths
            .iter()
            .map(|p| fs::metadata(p).unwrap().ino())
            .collect();
        f.pair
            .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |_| {
                panic!("unchanged flush must not journal or rewrite")
            })
            .unwrap();
        assert_eq!(
            inodes,
            f.pair
                .paths
                .iter()
                .map(|p| fs::metadata(p).unwrap().ino())
                .collect::<Vec<_>>()
        );
    }
    #[test]
    fn interrupted_boundaries_reopen_and_recover_idempotently() {
        for boundary in 0..4 {
            let f = Fixture::new();
            let result = catch_unwind(AssertUnwindSafe(|| {
                f.pair
                    .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |s| {
                        if s as usize == boundary {
                            panic!("synthetic process interruption")
                        }
                        Ok(())
                    })
            }));
            assert!(result.is_err());
            assert_eq!(
                fs::metadata(&f.pair.journal).unwrap().permissions().mode() & 0o777,
                0o600
            );
            let reopened = Pair::new(f.pair.paths.clone()).unwrap();
            reopened.recover().unwrap();
            reopened.recover().unwrap();
            if boundary < 3 {
                f.assert_old();
            } else {
                for i in 0..2 {
                    assert_eq!(fs::read(&f.pair.paths[i]).unwrap(), Fixture::new_bytes()[i]);
                }
            }
        }
    }
    #[test]
    fn recovery_preserves_external_changes_and_unknown_journals() {
        let f = Fixture::new();
        let _ = catch_unwind(AssertUnwindSafe(|| {
            f.pair
                .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |s| {
                    if matches!(s, Stage::Second) {
                        panic!("synthetic interruption")
                    }
                    Ok(())
                })
        }));
        fs::write(&f.pair.paths[1], b"external edited preferences").unwrap();
        assert!(f.pair.recover().is_err());
        assert_eq!(fs::read(&f.pair.paths[0]).unwrap(), b"new rules");
        assert_eq!(
            fs::read(&f.pair.paths[1]).unwrap(),
            b"external edited preferences"
        );
        // Repair the external conflict, then recovery can safely retry.
        fs::write(&f.pair.paths[1], b"new prefs").unwrap();
        // Model a partial rollback after the original bytes were restored, before original mode.
        fs::write(&f.pair.paths[0], b"old rules\0\xff").unwrap();
        fs::set_permissions(&f.pair.paths[0], fs::Permissions::from_mode(0o600)).unwrap();
        f.pair.recover().unwrap();
        f.assert_old();
        for text in [b"invalid".as_slice(), br#"{"version":99}"#] {
            fs::write(&f.pair.journal, text).unwrap();
            assert!(
                f.pair
                    .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |_| Ok(
                        ()
                    ))
                    .is_err()
            );
            assert_eq!(fs::read(&f.pair.journal).unwrap(), text);
            assert_eq!(fs::read(&f.pair.paths[0]).unwrap(), b"old rules\0\xff");
        }
    }
    #[test]
    fn symlinks_modes_and_aliases_are_preserved_or_rejected_before_writing() {
        let f = Fixture::new();
        let target = f.directory.join("outside");
        fs::write(&target, b"target unchanged").unwrap();
        fs::remove_file(&f.pair.paths[0]).unwrap();
        symlink(&target, &f.pair.paths[0]).unwrap();
        assert!(
            f.pair
                .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |s| {
                    if matches!(s, Stage::First) {
                        Err(invalid())
                    } else {
                        Ok(())
                    }
                })
                .is_err()
        );
        assert_eq!(fs::read_link(&f.pair.paths[0]).unwrap(), target);
        assert_eq!(fs::read(&target).unwrap(), b"target unchanged");
        let alias = f.directory.join("alias");
        symlink(&f.directory, &alias).unwrap();
        let p = Pair::new([f.pair.paths[0].clone(), alias.join("规则.json")]).unwrap();
        assert!(
            p.replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |_| Ok(
                ()
            ))
            .is_err()
        );
        let p = Pair::new([
            f.pair.paths[0].clone(),
            alias.join(f.pair.journal.file_name().unwrap()),
        ])
        .unwrap();
        assert!(
            p.replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |_| Ok(
                ()
            ))
            .is_err()
        );
        // A directory destination fails preflight, without modifying the other file.
        fs::create_dir_all(&f.pair.paths[1]).unwrap();
        assert!(
            f.pair
                .replace(Fixture::new_bytes().each_ref().map(Vec::as_slice), |_| Ok(
                    ()
                ))
                .is_err()
        );
        assert_eq!(fs::read_link(&f.pair.paths[0]).unwrap(), target);
    }
    #[test]
    fn delayed_generations_and_concurrent_saves_cannot_overwrite_replacements() {
        let f = Fixture::new();
        let store = Arc::new(Store {
            pair: Pair::new(f.pair.paths.clone()).unwrap(),
            tokens: [AtomicU64::new(0), AtomicU64::new(0)],
        });
        assert_eq!(store.save(0, b"before import", 0), 0);
        assert_eq!(
            store.replace(Fixture::new_bytes().each_ref().map(Vec::as_slice)),
            0
        );
        let mut threads = Vec::new();
        for _ in 0..64 {
            let s = store.clone();
            threads.push(std::thread::spawn(move || {
                assert_eq!(s.save(0, b"stale snapshot", 0), 1)
            }));
        }
        for t in threads {
            t.join().unwrap();
        }
        assert_eq!(fs::read(&f.pair.paths[0]).unwrap(), b"new rules");
        let old_rule_ticket = unsafe { aether_configuration_store_reserve(&*store, 0) };
        let new_rule_ticket = unsafe { aether_configuration_store_reserve(&*store, 0) };
        let preference_ticket = unsafe { aether_configuration_store_reserve(&*store, 1) };
        assert_eq!(
            unsafe { aether_configuration_store_current(&*store, 0, old_rule_ticket) },
            0
        );
        assert_eq!(
            store.save(0, b"latest ordinary rule edit", new_rule_ticket),
            0
        );
        assert_eq!(
            store.save(0, b"older ordinary rule edit", old_rule_ticket),
            1
        );
        assert_eq!(
            store.save(1, b"new valid preference edit", preference_ticket),
            0
        );
        assert_eq!(
            fs::read(&f.pair.paths[1]).unwrap(),
            b"new valid preference edit"
        );
        assert_eq!(store.tokens[0].load(Ordering::Acquire), new_rule_ticket);
        fs::write(&store.pair.journal, b"corrupt journal").unwrap();
        assert_eq!(
            store.replace(Fixture::new_bytes().each_ref().map(Vec::as_slice)),
            3
        );
        assert_eq!(store.tokens[0].load(Ordering::Acquire), new_rule_ticket);
        assert_eq!(store.save(0, b"must not overwrite", new_rule_ticket), 2);
        assert_eq!(
            unsafe { aether_configuration_store_current(std::ptr::null(), 0, 0) },
            0
        );
        assert_eq!(unsafe { aether_configuration_store_reserve(&*store, 2) }, 0);
    }
}

#[cfg(test)]
mod process_recovery_tests {
    use super::*;
    use std::{
        process::Command,
        sync::atomic::{AtomicU64, Ordering},
    };
    static ID: AtomicU64 = AtomicU64::new(0);
    #[test]
    fn crash_child() {
        let Some(directory) = std::env::var_os("AETHER_TEST_PAIR_CRASH_DIRECTORY") else {
            return;
        };
        let directory = PathBuf::from(directory);
        let boundary: usize = std::env::var("AETHER_TEST_PAIR_CRASH_STAGE")
            .unwrap()
            .parse()
            .unwrap();
        let pair = Pair::new([
            directory.join("rules.json"),
            directory.join("preferences.json"),
        ])
        .unwrap();
        pair.replace([b"new rules", b"new prefs"], |s| {
            if s as usize == boundary {
                std::process::exit(86);
            }
            Ok(())
        })
        .unwrap();
        panic!("expected a child process interruption");
    }
    #[test]
    fn actual_process_exit_recovers_before_or_after_commit_marker() {
        for boundary in 0..4 {
            let directory = std::env::temp_dir().join(format!(
                "aether-pair-process-{}-{}",
                std::process::id(),
                ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&directory).unwrap();
            let pair = Pair::new([
                directory.join("rules.json"),
                directory.join("preferences.json"),
            ])
            .unwrap();
            fs::write(&pair.paths[0], b"old rules").unwrap();
            fs::write(&pair.paths[1], b"old prefs").unwrap();
            let output = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "configuration_store::process_recovery_tests::crash_child",
                ])
                .env("AETHER_TEST_PAIR_CRASH_DIRECTORY", &directory)
                .env("AETHER_TEST_PAIR_CRASH_STAGE", boundary.to_string())
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(86));
            assert!(pair.journal.exists());
            let reopened = Pair::new(pair.paths.clone()).unwrap();
            reopened.recover().unwrap();
            let expected = if boundary == 3 {
                [b"new rules".as_slice(), b"new prefs"]
            } else {
                [b"old rules".as_slice(), b"old prefs"]
            };
            for (path, expected) in pair.paths.iter().zip(expected) {
                assert_eq!(fs::read(path).unwrap(), expected);
            }
            assert!(!pair.journal.exists());
            fs::remove_dir_all(directory).unwrap();
        }
    }
}
