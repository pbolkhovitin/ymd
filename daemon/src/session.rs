//! Capability-ключ локального HTTP API.
//!
//! Файл `$XDG_RUNTIME_DIR/ymd/session.key`, права `0600`. Плазмоид получает ключ
//! командой `ymd session-key` и передаёт его в заголовке `X-YMD-Session` — так
//! управлять плеером может только процесс с доступом к runtime-каталогу.

use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

pub fn runtime_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir).join("ymd");
        }
    }
    // macOS: XDG_RUNTIME_DIR не задаётся, а /tmp общий. Держим ключ в
    // пользовательском Application Support — путь стабилен между рестартами.
    #[cfg(target_os = "macos")]
    if let Some(base) = dirs::data_dir() {
        return base.join("ymd/run");
    }
    PathBuf::from("/tmp").join(format!("ymd-{}", std::process::id()))
}

pub fn key_path() -> PathBuf {
    runtime_dir().join("session.key")
}

pub fn read_key() -> std::io::Result<Option<String>> {
    match fs::read_to_string(key_path()) {
        Ok(raw) => {
            let key = raw.trim().to_string();
            if key.len() >= 16 {
                Ok(Some(key))
            } else {
                Ok(None)
            }
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err),
    }
}

/// Читает существующий ключ или создаёт новый (32 hex-символа).
pub fn ensure_key() -> std::io::Result<String> {
    if let Some(key) = read_key()? {
        return Ok(key);
    }

    let dir = runtime_dir();
    fs::create_dir_all(&dir)?;

    let mut raw = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
    let key: String = raw.iter().map(|b| format!("{b:02x}")).collect();

    let path = key_path();
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }

    let mut file = opts.open(&path)?;
    file.write_all(key.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;

    Ok(key)
}
