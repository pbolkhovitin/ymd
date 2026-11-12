//! Подпись запросов к медиа-API.
//!
//! `data = ts + trackIds(csv) + quality + codecs + transport`,
//! `sign = base64(HMAC-SHA256(secretKey, data))` без `=` на конце.
//!
//! Ключи — из официального клиента (`docs/07-media.md` в `yandex-music-research`).

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// Значение заголовка `X-Yandex-Music-Client`, к которому привязан
/// [`DESKTOP_SIGN_KEY`]. Ключ и заголовок проверяются вместе: несовпадение даёт 403.
pub const DESKTOP_CLIENT: &str = "YandexMusicDesktopAppWindows/5.95.0";

/// Ключ подписи десктопного клиента (Windows 5.95.0).
pub const DESKTOP_SIGN_KEY: &str = "kzqU4XhfCaY6B6JTHODeq5";

/// Соль для подписи прямой ссылки `/get-mp3/{md5}/{ts}{path}`.
pub const SIGN_SALT: &str = "XGRlBW9FXlekgbPrRHuSiA";

/// Кодеки, которые перечисляет официальный клиент в `get-file-info`.
pub const FILE_INFO_CODECS: [&str; 7] = [
    "flac",
    "flac-mp4",
    "aac-mp4",
    "he-aac-mp4",
    "aac",
    "he-aac",
    "mp3",
];

/// Прямая ссылка на файл из XML `download-info`:
/// `https://{host}/get-mp3/{md5(SIGN_SALT + path[1:] + s)}/{ts}{path}`.
///
/// Ссылка живёт около минуты, поэтому её нельзя кэшировать.
pub fn direct_link(host: &str, path: &str, ts: &str, s: &str) -> String {
    use md5::{Digest, Md5};
    let mut hasher = Md5::new();
    hasher.update(SIGN_SALT.as_bytes());
    hasher.update(path.get(1..).unwrap_or("").as_bytes());
    hasher.update(s.as_bytes());
    let sign = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect::<String>();
    format!("https://{host}/get-mp3/{sign}/{ts}{path}")
}

#[derive(Debug, Clone, Copy)]
#[allow(dead_code)] // используется для encraw (офлайн) в M3
pub enum SecretKey {
    Web,
    Windows,
    MacOs,
    Linux,
}

#[allow(dead_code)]
impl SecretKey {
    pub fn as_str(self) -> &'static str {
        match self {
            SecretKey::Web => "7tvSmFbyf5hJnIHhCimDDD",
            SecretKey::Windows => "kzqU4XhfCaY6B6JTHODeq5",
            SecretKey::MacOs => "uz0zSpaYCLmgk6C7YLdo5F",
            SecretKey::Linux => "uVNvVMAvdrvjtwN0VlhEt2",
        }
    }

    pub fn native() -> Self {
        match std::env::consts::OS {
            "linux" => SecretKey::Linux,
            "macos" => SecretKey::MacOs,
            "windows" => SecretKey::Windows,
            _ => SecretKey::Web,
        }
    }
}

#[allow(dead_code)]
pub fn now_ts() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[allow(dead_code)]
pub fn sign_file_info(
    secret: &str,
    ts: u64,
    track_ids: &[u64],
    quality: &str,
    codecs: &str,
    transport: &str,
) -> String {
    let ids = track_ids
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let payload = format!("{ts}{ids}{quality}{codecs}{transport}");
    strip_padding(&hmac_base64(secret, payload.as_bytes()))
}

#[allow(dead_code)] // lyrics — M3
pub fn sign_lyrics(secret: &str, track_id: u64, ts: u64) -> String {
    let payload = format!("{track_id}{ts}");
    strip_padding(&hmac_base64(secret, payload.as_bytes()))
}

fn hmac_base64(secret: &str, data: &[u8]) -> String {
    let Ok(mut mac) = HmacSha256::new_from_slice(secret.as_bytes()) else {
        return String::new();
    };
    mac.update(data);
    STANDARD.encode(mac.finalize().into_bytes())
}

fn strip_padding(signature: &str) -> String {
    let trimmed = signature.trim_end_matches('=');
    if trimmed.len() == signature.len() && !signature.is_empty() {
        signature[..signature.len() - 1].to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signature_is_stable_and_unpadded() {
        let sign = sign_file_info(
            SecretKey::Linux.as_str(),
            1_700_000_000,
            &[64072310],
            "nq",
            "mp3",
            "raw",
        );
        assert!(!sign.is_empty());
        assert!(!sign.ends_with('='));
        // Детерминированность: тот же вход → та же подпись.
        let again = sign_file_info(
            SecretKey::Linux.as_str(),
            1_700_000_000,
            &[64072310],
            "nq",
            "mp3",
            "raw",
        );
        assert_eq!(sign, again);
    }
}
