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
}

impl Default for Playback {
    fn default() -> Self {
        Self {
            quality: default_quality(),
            fallback_hq: true,
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
