//! Логирование демона: stderr + файл с ротацией.
//!
//! Демон запускается из `systemd --user`, поэтому stderr уходит в journald.
//! Для разбора «что происходило ночью» этого мало: файл переживает рестарт
//! сервиса и доступен без `journalctl`. Пишем одно и то же в оба места.
//!
//! Уровень задаётся `YMD_LOG` (по умолчанию `info`), понимает и `RUST_LOG`.
//! Каталог можно переопределить `YMD_LOG_DIR`, размер файла — `YMD_LOG_MAX_MB`.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tracing::Level;
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::prelude::*;

/// Предел размера файла до ротации (5 МиБ — примерно 3–4 дня обычной работы).
pub const MAX_BYTES: u64 = 5 * 1024 * 1024;

/// Каталог логов: `$YMD_LOG_DIR` → `$XDG_STATE_HOME/ymd` → `~/.local/state/ymd`.
pub fn dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("YMD_LOG_DIR") {
        return PathBuf::from(dir);
    }
    let base = dirs::state_dir()
        .or_else(|| dirs::home_dir().map(|home| home.join(".local/state")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("ymd")
}

pub fn path() -> PathBuf {
    dir().join("ymd.log")
}

/// Инициализирует подписчика. `file = false` — только stderr (короткие CLI-команды).
pub fn init(file: bool) {
    let level = level_from_env();

    if !file {
        // CLI: stderr без таргетов, как раньше — вывод читает человек.
        tracing_subscriber::fmt()
            .with_max_level(level)
            .with_target(false)
            .init();
        return;
    }

    let handle = match prepare_file() {
        Ok(handle) => handle,
        Err(err) => {
            eprintln!("ymd: файл логов недоступен ({err}), пишу в stderr");
            tracing_subscriber::fmt()
                .with_max_level(level)
                .with_target(true)
                .init();
            return;
        }
    };

    let sink = SharedFile {
        inner: Arc::new(Mutex::new(handle)),
    };
    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(sink)
        .with_ansi(false)
        .with_target(true);
    let stderr_layer = tracing_subscriber::fmt::layer()
        .with_writer(io::stderr)
        .with_target(true);

    let _ = tracing_subscriber::registry()
        .with(level)
        .with(file_layer)
        .with(stderr_layer)
        .try_init();
}

/// Открывает файл, предварительно сдвинув переросший лог в `ymd.log.1`.
fn prepare_file() -> io::Result<File> {
    let dir = dir();
    fs::create_dir_all(&dir)?;
    let path = dir.join("ymd.log");
    rotate_if_needed(&path)?;
    OpenOptions::new().create(true).append(true).open(&path)
}

fn rotate_if_needed(path: &std::path::Path) -> io::Result<()> {
    let limit = max_bytes();
    let size = fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
    if size < limit {
        return Ok(());
    }
    let rotated = path.with_extension("log.1");
    let _ = fs::remove_file(&rotated);
    fs::rename(path, rotated)
}

fn max_bytes() -> u64 {
    std::env::var("YMD_LOG_MAX_MB")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .map(|value| value * 1024 * 1024)
        .unwrap_or(MAX_BYTES)
}

fn level_from_env() -> LevelFilter {
    let raw = std::env::var("YMD_LOG")
        .or_else(|_| std::env::var("RUST_LOG"))
        .unwrap_or_else(|_| "info".to_string());
    parse_level(&raw)
}

fn parse_level(raw: &str) -> LevelFilter {
    // Понимаем и `ymd=debug`: берём уровень после последнего `=`.
    let token = raw.rsplit('=').next().unwrap_or("info").trim();
    match token.to_ascii_lowercase().as_str() {
        "trace" => LevelFilter::TRACE,
        "debug" => LevelFilter::DEBUG,
        "warn" => LevelFilter::WARN,
        "error" => LevelFilter::ERROR,
        "off" | "none" => LevelFilter::OFF,
        "info" | "" => LevelFilter::INFO,
        other => other
            .parse::<Level>()
            .map(LevelFilter::from_level)
            .unwrap_or(LevelFilter::INFO),
    }
}

/// Файл, общий для всех потоков: `tracing` пишет из нескольких.
#[derive(Clone)]
struct SharedFile {
    inner: Arc<Mutex<File>>,
}

impl Write for SharedFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self.inner.lock() {
            Ok(mut file) => file.write(buf),
            Err(_) => Err(io::Error::other("лог-файл заблокирован")),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self.inner.lock() {
            Ok(mut file) => file.flush(),
            Err(_) => Err(io::Error::other("лог-файл заблокирован")),
        }
    }
}

impl<'a> MakeWriter<'a> for SharedFile {
    type Writer = SharedFile;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

/// Последние `lines` строк лога (без хвостового перевода строки).
pub fn tail(lines: usize) -> io::Result<String> {
    let path = path();
    let mut text = String::new();
    File::open(&path)?.read_to_string(&mut text)?;
    let all: Vec<&str> = text.lines().collect();
    let start = all.len().saturating_sub(lines);
    Ok(all[start..].join("\n"))
}

/// Печатает хвост и ждёт новых строк, как `tail -f`.
pub fn follow(lines: usize) -> io::Result<()> {
    let path = path();
    let mut file = OpenOptions::new().read(true).open(&path)?;
    let mut pending = String::new();

    if let Ok(text) = tail(lines) {
        for line in text.lines() {
            println!("{line}");
        }
    }
    let mut offset = file.metadata()?.len();

    loop {
        std::thread::sleep(Duration::from_millis(500));
        let size = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        if size < offset {
            // Файл ротировали — начинаем с нового.
            file = OpenOptions::new().read(true).open(&path)?;
            offset = 0;
            pending.clear();
        }
        if size == offset {
            continue;
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut chunk = String::new();
        file.read_to_string(&mut chunk)?;
        offset += chunk.len() as u64;
        pending.push_str(&chunk);
        while let Some(pos) = pending.find('\n') {
            let line: String = pending.drain(..=pos).collect();
            print!("{line}");
        }
        let _ = io::stdout().flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_parsing_accepts_plain_and_targeted() {
        assert_eq!(parse_level("debug"), LevelFilter::DEBUG);
        assert_eq!(parse_level("ymd=warn"), LevelFilter::WARN);
        assert_eq!(parse_level("мусор"), LevelFilter::INFO);
        assert_eq!(parse_level(""), LevelFilter::INFO);
    }

    #[test]
    fn log_path_lives_under_ymd() {
        assert!(path().ends_with("ymd/ymd.log"));
    }
}
