//! Офлайн-кэш: загрузка `encraw`-потоков и индекс файлов.
//!
//! Файлы лежат в `~/.local/share/ymd/media/`, метаданные — в `index.json`.
//! Поток приходит зашифрованным (AES-128-CTR), расшифровывается почанково
//! по абсолютному смещению (см. [`crate::media::decrypt_chunk`]).

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::api::{Client, Quality, Stream};
use crate::state::Track;

/// Размер чанка при докачке. 1 МиБ — компромисс между оверхедом Range и памятью.
const CHUNK: u64 = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
    pub file: String,
    pub bytes: u64,
    #[serde(default)]
    pub codec: String,
    #[serde(default)]
    pub quality: String,
    #[serde(default)]
    pub at: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Index {
    #[serde(default)]
    items: BTreeMap<String, Entry>,
}

pub fn dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("ymd").join("media")
}

pub fn index_path() -> PathBuf {
    dir().join("index.json")
}

fn load_index() -> Index {
    fs::read(index_path())
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default()
}

fn save_index(index: &Index) -> Result<(), String> {
    let path = index_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("создать {}: {e}", parent.display()))?;
    }
    let data = serde_json::to_vec_pretty(index).map_err(|e| e.to_string())?;
    fs::write(&path, data).map_err(|e| format!("записать {}: {e}", path.display()))
}

pub fn list() -> Vec<Entry> {
    load_index().items.into_values().collect()
}

/// Локальный файл трека, если он есть в кэше.
pub fn path_for(track_id: &str) -> Option<PathBuf> {
    let entry = load_index().items.get(track_id).cloned()?;
    let path = dir().join(entry.file);
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

pub fn remove(track_id: &str) -> Result<bool, String> {
    let mut index = load_index();
    let Some(entry) = index.items.remove(track_id) else {
        return Ok(false);
    };
    let _ = fs::remove_file(dir().join(&entry.file));
    save_index(&index)?;
    Ok(true)
}

pub fn total_bytes() -> u64 {
    load_index().items.values().map(|e| e.bytes).sum()
}

/// Расширение по кодеку — влияет на выбор демуксера GStreamer.
fn extension(codec: &str) -> &'static str {
    match codec {
        "flac" | "flac-mp4" => "flac",
        "mp3" => "mp3",
        _ => "m4a",
    }
}

fn sniff(bytes: &[u8]) -> &'static str {
    if bytes.len() < 8 {
        return "unknown";
    }
    if &bytes[4..8] == b"ftyp" {
        "mp4"
    } else if &bytes[0..4] == b"fLaC" {
        "flac"
    } else if bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0 {
        "mp3"
    } else {
        "unknown"
    }
}

/// Скачивает трек в кэш и возвращает запись индекса.
///
/// Поток запрашивается в `encraw`, поэтому на диск попадает уже расшифрованный
/// файл — плеер играет его как обычный локальный.
pub async fn download(
    client: &Client,
    track: &Track,
    quality: Quality,
    mut progress: impl FnMut(u64, u64),
) -> Result<Entry, String> {
    let stream: Stream = client
        .encraw(track.id.parse().map_err(|_| "id должен быть числом".to_string())?, quality)
        .await
        .map_err(|e| format!("file-info: {e}"))?;

    let key = stream
        .key
        .as_deref()
        .ok_or_else(|| "в ответе нет ключа расшифровки".to_string())?;
    let key = hex::decode(key).map_err(|e| format!("ключ не hex: {e}"))?;
    if key.len() != 16 {
        return Err(format!("ключ {} байт вместо 16", key.len()));
    }

    let dir = dir();
    fs::create_dir_all(&dir).map_err(|e| format!("создать {}: {e}", dir.display()))?;

    let ext = extension(&stream.codec);
    let final_name = format!("{}.{}", track.id, ext);
    let part_path = dir.join(format!("{}.part", track.id));

    // Узнаём размер: одиночный байт по Range.
    let (_, total) = client
        .fetch_range(&stream.url, 0, Some(0))
        .await
        .map_err(|e| format!("размер: {e}"))?;
    let total = total.ok_or_else(|| "сервер не отдал Content-Range".to_string())?;

    let mut file = fs::File::create(&part_path).map_err(|e| format!("создать файл: {e}"))?;
    let mut written = 0u64;
    let mut first = Vec::new();

    while written < total {
        let end = (written + CHUNK - 1).min(total - 1);
        let (mut chunk, _) = client
            .fetch_range(&stream.url, written, Some(end))
            .await
            .map_err(|e| format!("чанк {written}: {e}"))?;

        if chunk.is_empty() {
            return Err(format!("пустой чанк на смещении {written}"));
        }
        crate::media::decrypt_chunk(&key, written, &mut chunk).map_err(str::to_string)?;

        if first.is_empty() {
            first = chunk.iter().take(16).copied().collect();
        }

        file.write_all(&chunk).map_err(|e| format!("запись: {e}"))?;
        written += chunk.len() as u64;
        progress(written, total);
    }

    file.sync_all().map_err(|e| format!("sync: {e}"))?;
    drop(file);

    let kind = sniff(&first);
    if kind == "unknown" {
        tracing::warn!(track = %track.id, "неизвестная сигнатура после расшифровки");
    }

    let final_path = dir.join(&final_name);
    fs::rename(&part_path, &final_path).map_err(|e| format!("rename: {e}"))?;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let entry = Entry {
        id: track.id.clone(),
        title: track.title.clone(),
        artists: track.artists.clone(),
        album: track.album.clone(),
        duration_ms: track.duration_ms,
        file: final_name,
        bytes: written,
        codec: stream.codec.clone(),
        quality: quality.as_str().to_string(),
        at: now,
    };

    let mut index = load_index();
    index.items.insert(entry.id.clone(), entry.clone());
    save_index(&index)?;

    tracing::info!(track = %entry.id, bytes = written, kind, "cached");
    Ok(entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_follows_codec() {
        assert_eq!(extension("mp3"), "mp3");
        assert_eq!(extension("flac-mp4"), "flac");
        assert_eq!(extension("aac-mp4"), "m4a");
    }

    #[test]
    fn sniff_detects_containers() {
        let mut mp4 = vec![0u8; 16];
        mp4[4..8].copy_from_slice(b"ftyp");
        assert_eq!(sniff(&mp4), "mp4");

        assert_eq!(sniff(b"fLaC\x00\x00\x00\x22"), "flac");

        let mp3 = [0xff, 0xfb, 0x90, 0x00, 0, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(sniff(&mp3), "mp3");
    }
}
