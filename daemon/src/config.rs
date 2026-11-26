//! Конфигурация демона: `~/.config/ymd/config.toml`.
//!
//! Файл необязателен — при отсутствии берутся значения по умолчанию.

use std::path::PathBuf;

use serde::Deserialize;

use crate::api::Quality;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub playback: Playback,
    #[serde(default)]
    pub cache: Cache,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Playback {
    /// `lossless` | `hq` | `nq` | `lq`.
    #[serde(default = "default_quality")]
    pub quality: String,
    /// Если запрошенное качество недоступно для трека — пробовать `hq`.
    #[serde(default = "default_true")]
    pub fallback_hq: bool,
    /// Качать поток в файл перед воспроизведением.
    #[serde(default = "default_true")]
    pub prefetch: bool,
}

impl Default for Playback {
    fn default() -> Self {
        Self {
            quality: default_quality(),
            fallback_hq: true,
            prefetch: true,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Cache {
    #[serde(default = "default_limit_mb")]
    pub limit_mb: u64,
}

impl Default for Cache {
    fn default() -> Self {
        Self {
            limit_mb: default_limit_mb(),
        }
    }
}

fn default_quality() -> String {
    "lossless".to_string()
}

fn default_limit_mb() -> u64 {
    2048
}

fn default_true() -> bool {
    true
}

pub fn path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("ymd")
        .join("config.toml")
}

/// Читает конфиг; при ошибке парсинга возвращает значения по умолчанию.
pub fn load() -> Config {
    let path = path();
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Config::default();
    };
    match toml::from_str(&text) {
        Ok(config) => config,
        Err(err) => {
            tracing::warn!(path = %path.display(), error = %err, "config parse error, using defaults");
            Config::default()
        }
    }
}

/// Качество воспроизведения из конфига.
pub fn quality() -> Quality {
    let config = load();
    Quality::parse(&config.playback.quality).unwrap_or(Quality::Lossless)
}

/// Пробовать ли `hq`, если запрошенное качество недоступно.
pub fn fallback_hq() -> bool {
    load().playback.fallback_hq
}

/// Записывает качество в конфиг, сохраняя остальные ключи.
pub fn set_quality(value: &str) -> Result<(), String> {
    if Quality::parse(value).is_none() {
        return Err(format!("неизвестное качество: {value} (lossless|hq|nq|lq)"));
    }

    let path = path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|err| err.to_string())?;
    }

    let mut root: toml::Value = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| toml::from_str(&text).ok())
        .unwrap_or_else(|| toml::Value::Table(Default::default()));

    let table = root
        .as_table_mut()
        .ok_or_else(|| "config.toml: ожидалась таблица".to_string())?;
    let playback = table
        .entry("playback")
        .or_insert_with(|| toml::Value::Table(Default::default()));
    let playback = playback
        .as_table_mut()
        .ok_or_else(|| "config.toml: [playback] должна быть таблицей".to_string())?;
    playback.insert(
        "quality".to_string(),
        toml::Value::String(value.to_string()),
    );

    let text = toml::to_string_pretty(&root).map_err(|err| err.to_string())?;
    std::fs::write(&path, text).map_err(|err| err.to_string())?;
    Ok(())
}

/// Записывает лимит кэша в мегабайтах, сохраняя остальные ключи.
pub fn set_cache_limit(limit_mb: u64) -> Result<(), String> {
    let limit = i64::try_from(limit_mb).map_err(|_| "слишком большой лимит".to_string())?;

    let path = path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|err| err.to_string())?;
    }

    let mut root: toml::Value = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| toml::from_str(&text).ok())
        .unwrap_or_else(|| toml::Value::Table(Default::default()));

    let table = root
        .as_table_mut()
        .ok_or_else(|| "config.toml: ожидалась таблица".to_string())?;
    let cache = table
        .entry("cache")
        .or_insert_with(|| toml::Value::Table(Default::default()));
    let cache = cache
        .as_table_mut()
        .ok_or_else(|| "config.toml: [cache] должна быть таблицей".to_string())?;
    cache.insert("limit_mb".to_string(), toml::Value::Integer(limit));

    let text = toml::to_string_pretty(&root).map_err(|err| err.to_string())?;
    std::fs::write(&path, text).map_err(|err| err.to_string())?;
    Ok(())
}

/// Эффективные настройки для `GET /v1/config`.
pub fn as_json() -> serde_json::Value {
    let config = load();
    serde_json::json!({
        "playback": {
            "quality": config.playback.quality,
            "fallbackHq": config.playback.fallback_hq,
        },
        "cache": { "limitMb": config.cache.limit_mb },
        "path": path().display().to_string(),
    })
}

/// Точечно меняет настройки, сохраняя остальные ключи файла.
///
/// `None` — поле не трогаем. Неизвестное качество отклоняется до записи.
pub fn patch(
    quality: Option<&str>,
    fallback_hq: Option<bool>,
    limit_mb: Option<u64>,
) -> Result<(), String> {
    if let Some(value) = quality {
        if Quality::parse(value).is_none() {
            return Err(format!("неизвестное качество: {value} (lossless|hq|nq|lq)"));
        }
    }
    let limit = match limit_mb {
        Some(value) => Some(i64::try_from(value).map_err(|_| "слишком большой лимит".to_string())?),
        None => None,
    };

    let path = path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|err| err.to_string())?;
    }

    let mut root: toml::Value = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| toml::from_str(&text).ok())
        .unwrap_or_else(|| toml::Value::Table(Default::default()));

    let table = root
        .as_table_mut()
        .ok_or_else(|| "config.toml: ожидалась таблица".to_string())?;

    let playback = table
        .entry("playback")
        .or_insert_with(|| toml::Value::Table(Default::default()))
        .as_table_mut()
        .ok_or_else(|| "config.toml: [playback] должна быть таблицей".to_string())?;
    if let Some(value) = quality {
        playback.insert(
            "quality".to_string(),
            toml::Value::String(value.to_string()),
        );
    }
    if let Some(value) = fallback_hq {
        playback.insert("fallback_hq".to_string(), toml::Value::Boolean(value));
    }

    if let Some(value) = limit {
        let cache = table
            .entry("cache")
            .or_insert_with(|| toml::Value::Table(Default::default()))
            .as_table_mut()
            .ok_or_else(|| "config.toml: [cache] должна быть таблицей".to_string())?;
        cache.insert("limit_mb".to_string(), toml::Value::Integer(value));
    }

    let text = toml::to_string_pretty(&root).map_err(|err| err.to_string())?;
    std::fs::write(&path, text).map_err(|err| err.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_lossless_with_limit() {
        let config = Config::default();
        assert_eq!(config.playback.quality, "lossless");
        assert!(config.playback.fallback_hq);
        assert_eq!(config.cache.limit_mb, 2048);
    }

    #[test]
    fn parses_partial_config() {
        let config: Config = toml::from_str("[playback]\nquality = \"hq\"\n").unwrap();
        assert_eq!(config.playback.quality, "hq");
        assert_eq!(config.cache.limit_mb, 2048);
        assert!(config.playback.fallback_hq);
    }
}

/// Качать ли поток в файл перед воспроизведением.
pub fn prefetch() -> bool {
    load().playback.prefetch
}
