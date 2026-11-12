//! OAuth Device Flow — вход без ручного копирования токена.
//!
//! Используются публичные креды официального Android-приложения Яндекс Музыки:
//! свой OAuth-клиент для этого не нужен (и не может запросить `music:*`).
//!
//! Поток:
//! 1. `POST https://oauth.yandex.ru/device/code` → `device_code`, `user_code`,
//!    `verification_url`, `interval`, `expires_in`;
//! 2. пользователь открывает URL и вводит код;
//! 3. `POST https://oauth.yandex.ru/token` с `grant_type=device_code` — пока не
//!    подтверждено, приходит `error=authorization_pending`.

use std::time::Duration;

use serde::Deserialize;

pub const CLIENT_ID: &str = "23cabbbdc6cd418abb4b39c32c41195d";
pub const CLIENT_SECRET: &str = "53bc75238f0c4d08a118e51fe9203300";
pub const DEVICE_NAME: &str = "ymd";

const OAUTH_BASE: &str = "https://oauth.yandex.ru";
const HTTP_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, thiserror::Error)]
pub enum OAuthError {
    #[error("HTTP: {0}")]
    Http(#[from] reqwest::Error),
    #[error("OAuth: {0}")]
    OAuth(String),
    #[error("код истёк или отклонён: {0}")]
    Denied(String),
}

#[derive(Debug, Clone)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub interval: u64,
    pub expires_in: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub expires_in: Option<u64>,
    #[serde(default)]
    #[allow(dead_code)]
    pub token_type: Option<String>,
}

#[derive(Deserialize)]
struct DeviceCodeWire {
    device_code: String,
    user_code: String,
    verification_url: String,
    #[serde(default = "default_interval")]
    interval: u64,
    #[serde(default)]
    expires_in: u64,
}

fn default_interval() -> u64 {
    5
}

/// Шаг 1: получить код устройства.
pub async fn request_device_code() -> Result<DeviceCode, OAuthError> {
    let http = reqwest::Client::builder().timeout(HTTP_TIMEOUT).build()?;
    let device_id = random_id(10);

    let response = http
        .post(format!("{OAUTH_BASE}/device/code"))
        .form(&[
            ("client_id", CLIENT_ID),
            ("device_id", device_id.as_str()),
            ("device_name", DEVICE_NAME),
        ])
        .send()
        .await?;

    let status = response.status();
    let body = response.text().await?;
    if !status.is_success() {
        return Err(OAuthError::OAuth(format!("{status}: {body}")));
    }

    let wire: DeviceCodeWire = serde_json::from_str(&body)
        .map_err(|err| OAuthError::OAuth(format!("разбор ответа: {err}: {body}")))?;

    Ok(DeviceCode {
        device_code: wire.device_code,
        user_code: wire.user_code,
        verification_url: wire.verification_url,
        interval: wire.interval.max(1),
        expires_in: wire.expires_in,
    })
}

/// Шаг 3: ждать подтверждения и получить токен.
///
/// Возвращает `Ok(None)`, если код истёк по времени.
pub async fn poll_token(code: &DeviceCode) -> Result<Option<TokenResponse>, OAuthError> {
    let http = reqwest::Client::builder().timeout(HTTP_TIMEOUT).build()?;
    let deadline = std::time::Instant::now() + Duration::from_secs(code.expires_in.max(60));
    let mut interval = Duration::from_secs(code.interval);

    while std::time::Instant::now() < deadline {
        tokio::time::sleep(interval).await;

        let response = http
            .post(format!("{OAUTH_BASE}/token"))
            .form(&[
                ("grant_type", "device_code"),
                ("code", code.device_code.as_str()),
                ("client_id", CLIENT_ID),
                ("client_secret", CLIENT_SECRET),
            ])
            .send()
            .await?;

        let status = response.status();
        let body = response.text().await?;
        if status.is_success() {
            let token: TokenResponse = serde_json::from_str(&body)
                .map_err(|err| OAuthError::OAuth(format!("разбор токена: {err}")))?;
            return Ok(Some(token));
        }

        // 400 с authorization_pending — это норма, ждём дальше.
        if body.contains("authorization_pending") {
            continue;
        }
        if body.contains("slow_down") {
            interval += Duration::from_secs(5);
            continue;
        }
        return Err(OAuthError::Denied(body));
    }

    Ok(None)
}

fn random_id(len: usize) -> String {
    use std::io::Read;
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut buf = vec![0u8; len];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        let _ = file.read_exact(&mut buf);
    }
    buf.iter()
        .map(|byte| ALPHABET[*byte as usize % ALPHABET.len()] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_id_has_requested_length() {
        let id = random_id(10);
        assert_eq!(id.len(), 10);
        assert!(id.chars().all(|c| c.is_ascii_alphanumeric()));
    }

    #[test]
    fn parses_token_response() {
        let token: TokenResponse = serde_json::from_str(
            r#"{"access_token":"y0_x","refresh_token":"r","expires_in":31536000,"token_type":"bearer"}"#,
        )
        .expect("parsed");
        assert_eq!(token.access_token, "y0_x");
        assert_eq!(token.expires_in, Some(31_536_000));
    }
}
