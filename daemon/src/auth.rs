//! Авторизация: импорт токена и хранение в GNOME Keyring (libsecret).
//!
//! Почему импорт, а не OAuth-поток: новым приложениям в Яндекс ID больше не
//! выдают доступ к Музыкальному API (в свойствах приложения нет раздела
//! «Доступ к API», публичная документация Music API удалена). Поэтому токен
//! берётся из официального клиента или вставляется вручную — см.
//! `docs/10-oauth-registration.md`.
//!
//! Секреты не логируются и не печатаются: наружу отдаётся только маска.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const SECRET_SERVICE: &str = "ymd";
const SECRET_ATTR: &str = "account";

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("токен не найден: {0}")]
    NotFound(String),
    #[error("официальный клиент не найден: {0}")]
    OfficialClientMissing(String),
    #[error("не удалось сохранить токен: {0}")]
    Store(String),
    #[error("API отклонил токен: {0}")]
    Rejected(String),
    #[error("сеть: {0}")]
    Network(String),
    #[error("I/O: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
}

/// Метаданные аккаунта (без самого токена).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub login: String,
    pub uid: u64,
    #[serde(default)]
    pub has_plus: bool,
    #[serde(default)]
    pub backend: String,
    #[serde(default)]
    pub saved_at: u64,
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn state_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state"))
        .join("ymd")
}

pub fn meta_path() -> PathBuf {
    state_dir().join("auth.json")
}

pub fn file_token_path() -> PathBuf {
    state_dir().join("token")
}

/// Путь к Local Storage официального клиента.
pub fn official_storage_dir() -> PathBuf {
    home().join(".config/YandexMusic/Local Storage/leveldb")
}

/// Маска токена для вывода: `y0__xDv…kRgY (64 символа)`.
pub fn mask(token: &str) -> String {
    let n = token.chars().count();
    if n <= 12 {
        return "***".to_string();
    }
    let head: String = token.chars().take(6).collect();
    let tail: String = token.chars().skip(n - 4).collect();
    format!("{head}…{tail} ({n} символов)")
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------- источники

/// Ищет токен в хранилище официального клиента (LevelDB).
///
/// В `.ldb`/`.log` токен лежит открытым текстом в записи ключа `oauth`,
/// поэтому достаточно найти последовательность `y0_` + `[A-Za-z0-9_-]`.
pub fn token_from_official_client() -> Result<String, AuthError> {
    let dir = official_storage_dir();
    if !dir.is_dir() {
        return Err(AuthError::OfficialClientMissing(dir.display().to_string()));
    }

    let mut best: Option<String> = None;
    for entry in fs::read_dir(&dir)? {
        let path = entry?.path();
        if !path.is_file() {
            continue;
        }
        let Ok(bytes) = fs::read(&path) else { continue };
        if let Some(found) = find_token(&bytes) {
            if best.as_ref().map(|b| found.len() > b.len()).unwrap_or(true) {
                best = Some(found);
            }
        }
    }

    best.ok_or_else(|| AuthError::NotFound(format!("в {} нет токена", dir.display())))
}

fn find_token(bytes: &[u8]) -> Option<String> {
    const PREFIX: &[u8] = b"y0_";
    let mut best: Option<String> = None;
    let mut i = 0;
    while i + PREFIX.len() < bytes.len() {
        if &bytes[i..i + PREFIX.len()] == PREFIX {
            let mut j = i + PREFIX.len();
            while j < bytes.len() && is_token_byte(bytes[j]) {
                j += 1;
            }
            // Токен Яндекса заметно длиннее 40 символов.
            if j - i >= 40 {
                if let Ok(candidate) = std::str::from_utf8(&bytes[i..j]) {
                    let len = candidate.len();
                    if best.as_ref().map(|b| len > b.len()).unwrap_or(true) {
                        best = Some(candidate.to_string());
                    }
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    best
}

fn is_token_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// Разбирает пользовательский ввод: URL с `#access_token=…`, query-строка или
/// сам токен.
pub fn token_from_input(input: &str) -> Result<String, AuthError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(AuthError::NotFound("пустой ввод".into()));
    }

    for part in trimmed
        .split('#')
        .skip(1)
        .chain(trimmed.split_once('?').map(|(_, q)| q).into_iter())
    {
        if let Some(token) = param(part, "access_token") {
            return Ok(token);
        }
    }

    if trimmed.starts_with("y0_") && !trimmed.contains(char::is_whitespace) {
        return Ok(trimmed.to_string());
    }

    Err(AuthError::NotFound("не похоже на токен".into()))
}

fn param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        if k == key && !v.is_empty() {
            Some(v.to_string())
        } else {
            None
        }
    })
}

// --------------------------------------------------------------- проверка

#[derive(Deserialize)]
struct AboutResponse {
    result: About,
}

#[derive(Deserialize)]
struct About {
    #[serde(default)]
    login: String,
    #[serde(default)]
    uid: u64,
    #[serde(default, rename = "hasPlus")]
    has_plus: bool,
}

/// Проверяет токен запросом `/account/about` и возвращает данные аккаунта.
pub async fn validate(token: &str) -> Result<Account, AuthError> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| AuthError::Network(e.to_string()))?;

    let response = client
        .get("https://api.music.yandex.ru/account/about")
        .header("authorization", format!("OAuth {token}"))
        .header("x-yandex-music-client", "YandexMusicDesktopApp")
        .header("accept-language", "ru")
        .send()
        .await
        .map_err(|e| AuthError::Network(e.to_string()))?;

    let status = response.status();
    if !status.is_success() {
        return Err(AuthError::Rejected(format!("HTTP {status}")));
    }

    let body: AboutResponse = response
        .json()
        .await
        .map_err(|e| AuthError::Network(e.to_string()))?;

    if body.result.login.is_empty() {
        return Err(AuthError::Rejected(
            "ответ без login — токен не подходит".into(),
        ));
    }

    Ok(Account {
        login: body.result.login,
        uid: body.result.uid,
        has_plus: body.result.has_plus,
        backend: String::new(),
        saved_at: now(),
    })
}

// ---------------------------------------------------------------- хранение

fn on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(name).is_file()))
        .unwrap_or(false)
}

/// Linux — `secret-tool` (libsecret), macOS — `security` (связка ключей).
fn keyring_available() -> bool {
    #[cfg(target_os = "linux")]
    {
        // `secret-tool` не поддерживает `--version` (печатает usage и выходит
        // с ошибкой), поэтому проверяем наличие в PATH.
        on_path("secret-tool")
    }
    #[cfg(target_os = "macos")]
    {
        on_path("security")
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        false
    }
}

#[cfg(target_os = "linux")]
fn keyring_store(login: &str, token: &str) -> Result<(), AuthError> {
    let mut child = Command::new("secret-tool")
        .args(["store", "--label", "ymd OAuth token"])
        .args(["service", SECRET_SERVICE])
        .args([SECRET_ATTR, login])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| AuthError::Store(format!("secret-tool: {e}")))?;

    child
        .stdin
        .as_mut()
        .ok_or_else(|| AuthError::Store("stdin недоступен".into()))?
        .write_all(token.as_bytes())?;

    let out = child.wait_with_output()?;
    if !out.status.success() {
        return Err(AuthError::Store(
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn keyring_store(login: &str, token: &str) -> Result<(), AuthError> {
    // -U обновляет существующую запись. Токен передаётся аргументом: он виден
    // в `ps` доли секунды. Keychain всё равно надёжнее файла `0600`.
    let out = Command::new("security")
        .args(["add-generic-password", "-U"])
        .args(["-s", SECRET_SERVICE, "-a", login, "-w", token])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| AuthError::Store(format!("security: {e}")))?;
    if !out.status.success() {
        return Err(AuthError::Store(
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn keyring_load(login: &str) -> Option<String> {
    let out = Command::new("secret-tool")
        .args(["lookup", "service", SECRET_SERVICE])
        .args([SECRET_ATTR, login])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8(out.stdout).ok()?;
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(target_os = "macos")]
fn keyring_load(login: &str) -> Option<String> {
    let out = Command::new("security")
        .args(["find-generic-password", "-s", SECRET_SERVICE, "-a", login, "-w"])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8(out.stdout).ok()?;
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(target_os = "linux")]
fn keyring_clear(login: &str) {
    let _ = Command::new("secret-tool")
        .args(["clear", "service", SECRET_SERVICE])
        .args([SECRET_ATTR, login])
        .stderr(Stdio::null())
        .status();
}

#[cfg(target_os = "macos")]
fn keyring_clear(login: &str) {
    let _ = Command::new("security")
        .args(["delete-generic-password", "-s", SECRET_SERVICE, "-a", login])
        .stderr(Stdio::null())
        .status();
}

fn file_store(token: &str) -> Result<(), AuthError> {
    let path = file_token_path();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path)?;
    file.write_all(token.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

fn file_load() -> Option<String> {
    let text = fs::read_to_string(file_token_path()).ok()?;
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// Сохраняет токен и метаданные. Keyring предпочтителен, файл `0600` — фоллбэк.
pub fn save(account: &Account, token: &str) -> Result<Account, AuthError> {
    let mut account = account.clone();

    if keyring_available() && keyring_store(&account.login, token).is_ok() {
        account.backend = "keyring".into();
        let _ = fs::remove_file(file_token_path());
    } else {
        file_store(token)?;
        account.backend = "file".into();
    }

    account.saved_at = now();
    let path = meta_path();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(&path, serde_json::to_vec_pretty(&account)?)?;

    Ok(account)
}

/// Загружает токен: сначала keyring, затем файл.
pub fn load_token() -> Option<String> {
    if let Some(account) = load_account() {
        if let Some(token) = keyring_load(&account.login) {
            return Some(token);
        }
    }
    file_load()
}

pub fn load_account() -> Option<Account> {
    let data = fs::read(meta_path()).ok()?;
    serde_json::from_slice(&data).ok()
}

/// Удаляет токен и метаданные.
pub fn logout() -> Result<bool, AuthError> {
    let mut removed = false;
    if let Some(account) = load_account() {
        keyring_clear(&account.login);
        removed = true;
    }
    for path in [meta_path(), file_token_path()] {
        if fs::remove_file(path).is_ok() {
            removed = true;
        }
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_token_in_bytes() {
        let mut blob = b"garbage".to_vec();
        let token = "y0_AgAAAAB1234567890abcdefghijklmnopqrstuvwxyz_ABCD";
        blob.extend_from_slice(b"\x01oauth\x02");
        blob.extend_from_slice(token.as_bytes());
        blob.extend_from_slice(b"\x00tail");
        assert_eq!(find_token(&blob).as_deref(), Some(token));
    }

    #[test]
    fn parses_fragment_and_raw_token() {
        let url = "https://music.yandex.ru/#access_token=y0_AgAAAxyz&expires_in=31536000";
        assert_eq!(token_from_input(url).unwrap(), "y0_AgAAAxyz");
        let raw = "y0_AgAAAxyz";
        assert_eq!(token_from_input(raw).unwrap(), raw);
        assert!(token_from_input("").is_err());
    }

    #[test]
    fn masks_token() {
        let masked = mask("y0_AgAAAAB1234567890abcdef");
        assert!(masked.contains('…'));
        assert!(!masked.contains("B1234567890"));
    }
}
