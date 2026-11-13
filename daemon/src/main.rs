//! `ymd` — демон Яндекс Музыки для плазмоида KDE Plasma 6.
//!
//! Демон владеет токеном, API, GStreamer-плеером, MPRIS и кэшем.
//! Плазмоид общается с ним по локальному HTTP API (`127.0.0.1:8765`).

mod api;
mod auth;
mod doctor;
mod httpd;
mod media;
mod mpris;
mod oauth;
mod cache;
mod config;
mod player;
mod mpris_server;
mod session;
mod state;

use clap::{Parser, Subcommand};

use crate::state::AppState;

#[derive(Parser, Debug)]
#[command(name = "ymd", version, about = "Yandex Music daemon for KDE Plasma 6")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Запустить демон (это же делает systemd --user).
    Serve {
        /// Порт локального API для плазмоида.
        #[arg(long, default_value_t = 8765)]
        port: u16,
    },
    /// Напечатать capability-ключ локального API (для плазмоида KDE).
    SessionKey,
    /// Проверить окружение и напечатать отчёт.
    Doctor,
    /// Напечатать текущее состояние плеера.
    Status {
        #[arg(long)]
        json: bool,
        #[arg(long, default_value_t = 8765)]
        port: u16,
    },
    /// Включить «Мою волну» на запущенном демоне.
    Wave {
        #[arg(long, default_value_t = 8765)]
        port: u16,
        #[arg(long)]
        json: bool,
    },
    /// Показать или изменить качество звука (применяется со следующего трека).
    Quality {
        /// lossless | hq | nq | lq
        value: Option<String>,
    },
    /// Отправить команду запущенному демону.
    Ctl {
        /// toggle | play | pause | next | prev | like | mode
        op: String,
        #[arg(long, default_value_t = 8765)]
        port: u16,
    },
    /// Авторизация: импорт токена и состояние аккаунта.
    Auth {
        #[command(subcommand)]
        cmd: AuthCommand,
    },
    /// Поиск по каталогу.
    Search {
        text: String,
        #[arg(long, default_value_t = 0)]
        page: u32,
        #[arg(long)]
        json: bool,
    },
    /// Скачать трек в офлайн-кэш.
    Download {
        id: u64,
        #[arg(long, default_value = "hq")]
        quality: String,
        #[arg(long)]
        json: bool,
    },
    /// Скачать весь альбом в офлайн-кэш.
    DownloadAlbum {
        id: u64,
        #[arg(long, default_value = "nq")]
        quality: String,
    },
    /// Офлайн-кэш: список, удаление, путь.
    Cache {
        #[command(subcommand)]
        cmd: CacheCommand,
    },
    /// Метаданные трека.
    Track {
        id: u64,
        #[arg(long)]
        json: bool,
    },
    /// Подписанный URL потока (для отладки плеера).
    Stream {
        id: u64,
        #[arg(long, default_value = "nq")]
        quality: String,
        /// Не печатать URL целиком (подпись одноразовая и длинная).
        #[arg(long)]
        quiet: bool,
    },
}

#[derive(Subcommand, Debug)]
enum CacheCommand {
    /// Список скачанных треков.
    List,
    /// Удалить трек из кэша.
    Remove { id: String },
    /// Путь к локальному файлу трека (если есть).
    Path { id: String },
    /// Каталог кэша и суммарный размер.
    Info,
}

#[derive(Subcommand, Debug)]
enum AuthCommand {
    /// Импортировать токен (из официального клиента или из ввода).
    Import {
        /// Взять токен из Local Storage официального клиента.
        #[arg(long)]
        from_official: bool,
        /// Готовый токен или URL с #access_token=…
        #[arg(long)]
        token: Option<String>,
        /// Только показать, что найдено, ничего не сохранять.
        #[arg(long)]
        dry_run: bool,
    },
    /// Войти через OAuth Device Flow (код в браузере, без копирования токена).
    Login {
        /// Не ждать подтверждения, только выдать код.
        #[arg(long)]
        no_wait: bool,
    },
    /// Показать, какой аккаунт привязан.
    Status,
    /// Удалить токен из keyring и состояния.
    Logout,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_target(false)
        .init();

    match Cli::parse().command {
        Command::Serve { port } => {
            let key = session::ensure_key()?;
            let app = match player::Player::new() {
                Ok(player) => AppState::with_player(player),
                Err(err) => {
                    tracing::warn!("звук недоступен ({err}), работаем без плеера");
                    AppState::new()
                }
            };
            app.spawn_ticker();
            let mpris_app = app.clone();
            tokio::spawn(async move {
                match mpris_server::serve(mpris_app).await {
                    Ok(connection) => {
                        // Держим соединение живым: при drop шина отпускает имя.
                        let _connection = connection;
                        std::future::pending::<()>().await;
                    }
                    Err(err) => tracing::warn!("mpris недоступен: {err}"),
                }
            });
            httpd::serve(app, port, key).await
        }
        Command::SessionKey => {
            println!("{}", key()?);
            Ok(())
        }
        Command::Doctor => {
            doctor::run();
            Ok(())
        }
        Command::Status { json, port } => status(json, port),
        Command::Wave { port, json } => wave_cmd(port, json),
        Command::Quality { value } => {
            match value {
                Some(value) => {
                    config::set_quality(&value)?;
                    println!("качество: {value}");
                }
                None => {
                    let cfg = config::load();
                    let fallback = if cfg.playback.fallback_hq { "да" } else { "нет" };
                    println!("качество: {}", cfg.playback.quality);
                    println!("фоллбэк в hq: {fallback}");
                }
            }
            Ok(())
        }
        Command::Ctl { op, port } => ctl(&op, port),
        Command::Auth { cmd } => auth_cmd(cmd).await,
        Command::Search { text, page, json } => search_cmd(&text, page, json).await,
        Command::Download { id, quality, json } => download_cmd(id, &quality, json).await,
        Command::DownloadAlbum { id, quality } => download_album_cmd(id, &quality).await,
        Command::Cache { cmd } => {
            match cmd {
                CacheCommand::List => cache_list(),
                CacheCommand::Remove { id } => cache_remove(&id),
                CacheCommand::Path { id } => cache_path(&id),
                CacheCommand::Info => cache_info(),
            }
            Ok(())
        }
        Command::Track { id, json } => track_cmd(id, json).await,
        Command::Stream {
            id,
            quality,
            quiet,
        } => stream_cmd(id, &quality, quiet).await,
    }
}

async fn search_cmd(
    text: &str,
    page: u32,
    json: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api::Client::from_store()?;
    let value = client.search(text, page).await?;

    if json {
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }

    let tracks = value
        .pointer("/tracks/results")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if tracks.is_empty() {
        println!("ничего не найдено");
        return Ok(());
    }

    for item in tracks.iter().take(20) {
        let id = item.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
        let title = item.get("title").and_then(|v| v.as_str()).unwrap_or("—");
        let artists: Vec<&str> = item
            .get("artists")
            .and_then(|v| v.as_array())
            .map(|list| {
                list.iter()
                    .filter_map(|a| a.get("name").and_then(|v| v.as_str()))
                    .collect()
            })
            .unwrap_or_default();
        let duration = item
            .get("durationMs")
            .and_then(|v| v.as_u64())
            .map(|ms| format!("{}:{:02}", ms / 60000, (ms / 1000) % 60))
            .unwrap_or_else(|| "--:--".into());
        println!("{id:>12}  {title} — {} [{duration}]", artists.join(", "));
    }
    Ok(())
}

async fn download_cmd(
    id: u64,
    quality: &str,
    json: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let quality = api::Quality::parse(quality).ok_or("качество: lossless | hq | nq")?;
    let client = api::Client::from_store()?;
    let value = client.track(&id.to_string()).await?;
    // `/tracks/{id}` отдаёт `{"track": {...}}` (иногда — массив из одного).
    let item = value
        .get("track")
        .cloned()
        .or_else(|| value.as_array().and_then(|items| items.first()).cloned())
        .unwrap_or(value);
    let track = state::track_from_value(&item)?;

    eprintln!(
        "скачиваем: {} — {}",
        track.title,
        track.artist_line()
    );

    let mut last_decile = 0u64;
    let entry = cache::download(&client, &track, quality, |done, total| {
        if total == 0 {
            return;
        }
        let decile = done * 10 / total;
        if decile != last_decile || done == total {
            last_decile = decile;
            eprint!("\r  {:>3}% {:>6.1} / {:.1} МиБ", done * 100 / total, done as f64 / 1048576.0, total as f64 / 1048576.0);
            let _ = std::io::Write::flush(&mut std::io::stderr());
        }
    })
    .await?;
    eprintln!();

    if json {
        println!("{}", serde_json::to_string_pretty(&entry)?);
    } else {
        println!(
            "ok {} — {} ({}, {}, {:.1} МиБ)",
            entry.id,
            entry.title,
            entry.codec,
            entry.quality,
            entry.bytes as f64 / 1048576.0
        );
    }
    Ok(())
}

async fn download_album_cmd(id: u64, quality: &str) -> Result<(), Box<dyn std::error::Error>> {
    let quality = api::Quality::parse(quality).ok_or("качество: lossless | hq | nq")?;
    let client = api::Client::from_store()?;
    let value = client.album(&id.to_string()).await?;

    let title = value
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("<без названия>");
    let mut tracks: Vec<state::Track> = Vec::new();

    if let Some(volumes) = value.get("volumes").and_then(|v| v.as_array()) {
        for volume in volumes {
            if let Some(items) = volume.as_array() {
                for item in items {
                    if let Ok(track) = state::track_from_value(item) {
                        tracks.push(track);
                    }
                }
            }
        }
    }

    if tracks.is_empty() {
        return Err("в альбоме не нашлось треков".into());
    }

    println!("альбом: {title} — {} треков", tracks.len());
    let mut failed = 0usize;

    for (index, track) in tracks.iter().enumerate() {
        if cache::path_for(&track.id).is_some() {
            println!("[{}/{}] уже скачан: {} — {}", index + 1, tracks.len(), track.title, track.artist_line());
            continue;
        }
        match cache::download(&client, track, quality, |_, _| {}).await {
            Ok(entry) => println!(
                "[{}/{}] ok {} — {} ({:.1} МиБ)",
                index + 1,
                tracks.len(),
                entry.title,
                entry.artists.join(", "),
                entry.bytes as f64 / 1048576.0
            ),
            Err(err) => {
                failed += 1;
                eprintln!("[{}/{}] ошибка {}: {err}", index + 1, tracks.len(), track.title);
            }
        }
    }

    println!(
        "итого: готово {}, ошибок {}, занято {:.1} МиБ",
        tracks.len() - failed,
        failed,
        cache::total_bytes() as f64 / 1048576.0
    );
    Ok(())
}

fn cache_list() {
    let items = cache::list();
    if items.is_empty() {
        println!("кэш пуст: {}", cache::dir().display());
        return;
    }
    for entry in items {
        println!(
            "{:>10}  {:>6.1} МиБ  {}  {} — {}",
            entry.id,
            entry.bytes as f64 / 1048576.0,
            entry.quality,
            entry.title,
            entry.artists.join(", ")
        );
    }
    println!(
        "всего: {} треков, {:.1} МиБ",
        cache::list().len(),
        cache::total_bytes() as f64 / 1048576.0
    );
}

fn cache_remove(id: &str) {
    match cache::remove(id) {
        Ok(true) => println!("удалён {id}"),
        Ok(false) => println!("нет в кэше: {id}"),
        Err(err) => eprintln!("ошибка: {err}"),
    }
}

fn cache_path(id: &str) {
    match cache::path_for(id) {
        Some(path) => println!("{}", path.display()),
        None => println!("нет в кэше: {id}"),
    }
}

fn cache_info() {
    println!("каталог: {}", cache::dir().display());
    println!("индекс:  {}", cache::index_path().display());
    println!(
        "занято:  {:.1} МиБ в {} треках (лимит {:.0} МиБ)",
        cache::total_bytes() as f64 / 1048576.0,
        cache::list().len(),
        cache::limit_bytes() as f64 / 1048576.0
    );
}

async fn track_cmd(id: u64, json: bool) -> Result<(), Box<dyn std::error::Error>> {
    let client = api::Client::from_store()?;
    let value = client.track(&id.to_string()).await?;

    if json {
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }

    let title = value
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("—");
    let artists: Vec<&str> = value
        .get("artists")
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|a| a.get("name").and_then(|v| v.as_str()))
                .collect()
        })
        .unwrap_or_default();
    let duration = value
        .get("durationMs")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    println!("{title} — {}", artists.join(", "));
    println!("duration {}:{:02}", duration / 60000, (duration / 1000) % 60);
    println!(
        "available {}",
        value.get("available").and_then(|v| v.as_bool()).unwrap_or(false)
    );
    Ok(())
}

async fn stream_cmd(
    id: u64,
    quality: &str,
    quiet: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let quality = api::Quality::parse(quality).unwrap_or(api::Quality::Nq);
    let client = api::Client::from_store()?;
    let stream = client.stream(id, quality).await?;

    if quiet {
        let host = stream
            .url
            .split_once("://")
            .map(|(_, rest)| rest.split('/').next().unwrap_or("").to_string())
            .unwrap_or_default();
        println!(
            "ok transport={} host={} key={}",
            stream.transport,
            host,
            stream.key.is_some()
        );
    } else {
        println!("{}", stream.url);
    }
    Ok(())
}

async fn auth_cmd(cmd: AuthCommand) -> Result<(), Box<dyn std::error::Error>> {
    match cmd {
        AuthCommand::Login { no_wait } => {
            let code = oauth::request_device_code().await?;
            println!("Откройте {} и введите код: {}", code.verification_url, code.user_code);
            println!("(код действует {} мин)", code.expires_in / 60);

            if no_wait {
                println!("device_code: {}", code.device_code);
                return Ok(());
            }

            println!("жду подтверждения…");
            let token = match oauth::poll_token(&code).await? {
                Some(token) => token,
                None => {
                    eprintln!("код истёк — запустите заново");
                    std::process::exit(1);
                }
            };

            println!("токен получен: {}", auth::mask(&token.access_token));
            let account = auth::validate(&token.access_token).await?;
            let saved = auth::save(&account, &token.access_token)?;
            println!(
                "вход выполнен: login={} uid={} plus={}",
                saved.login, saved.uid, saved.has_plus
            );
            if let Some(expires_in) = token.expires_in {
                println!("срок действия: ~{} дней", expires_in / 86_400);
            }
            if token.refresh_token.is_some() {
                println!("refresh_token получен (не сохраняется)");
            }
            Ok(())
        }
        AuthCommand::Import {
            from_official,
            token,
            dry_run,
        } => {
            // Приоритет: явный токен/URL, затем официальный клиент.
            let found = match token {
                Some(input) => auth::token_from_input(&input)?,
                None => {
                    if !from_official {
                        eprintln!("укажи --token <токен|URL> или --from-official");
                        std::process::exit(2);
                    }
                    auth::token_from_official_client()?
                }
            };

            println!("найден токен: {}", auth::mask(&found));

            if dry_run {
                println!("dry-run: токен не сохранён");
                return Ok(());
            }

            let account = auth::validate(&found).await?;
            let saved = auth::save(&account, &found)?;
            println!(
                "сохранено: login={} uid={} plus={} backend={}",
                saved.login, saved.uid, saved.has_plus, saved.backend
            );
            if saved.backend == "file" {
                println!("внимание: keyring недоступен, токен лежит в {} (0600)", auth::file_token_path().display());
            }
            Ok(())
        }
        AuthCommand::Status => {
            match auth::load_account() {
                None => {
                    println!("не авторизован");
                    println!("вход: ymd auth login   (или import --from-official)");
                }
                Some(account) => {
                    println!("login   {}", account.login);
                    println!("uid     {}", account.uid);
                    println!("plus    {}", account.has_plus);
                    println!("backend {}", account.backend);
                    match auth::load_token() {
                        Some(token) => println!("token   {}", auth::mask(&token)),
                        None => println!("token   ОТСУТСТВУЕТ (keyring/файл пуст)"),
                    }
                }
            }
            Ok(())
        }
        AuthCommand::Logout => {
            let removed = auth::logout()?;
            println!("{}", if removed { "токен удалён" } else { "нечего удалять" });
            Ok(())
        }
    }
}

fn key() -> Result<String, Box<dyn std::error::Error>> {
    session::read_key()?.ok_or_else(|| "session.key не найден — запущен ли «ymd serve»?".into())
}

fn status(json: bool, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let key = key()?;
    let response = httpd::request(port, "GET", "/v1/state", Some(&key), None)?;
    let body = httpd::body_of(&response);

    if body.trim().is_empty() {
        return Err(format!("пустой ответ: {}", httpd::status_line(&response)).into());
    }

    if json {
        println!("{}", body.trim());
        return Ok(());
    }

    let state: state::State = serde_json::from_str(body)?;
    let track = state
        .track
        .as_ref()
        .map(|track| format!("{} — {}", track.title, track.artist_line()))
        .unwrap_or_else(|| "—".to_string());
    let duration = state
        .track
        .as_ref()
        .map(|track| track.duration_ms)
        .unwrap_or(0);

    println!("status   {}", state.status);
    println!("track    {track}");
    println!("position {} / {duration} ms", state.position_ms);
    println!("mode     {}", state.ui.mode);
    println!("rev      {}", state.rev);
    Ok(())
}

fn wave_cmd(port: u16, json: bool) -> Result<(), Box<dyn std::error::Error>> {
    let key = key()?;
    let payload = serde_json::json!({ "op": "wave_start" }).to_string();
    let response = httpd::request(port, "POST", "/v1/cmd", Some(&key), Some(&payload))?;
    let line = httpd::status_line(&response);

    if !line.contains(" 200 ") {
        return Err(format!("{line} {}", httpd::body_of(&response)).into());
    }

    let state = httpd::request(port, "GET", "/v1/state", Some(&key), None)?;
    let body = httpd::body_of(&state);

    if json {
        println!("{}", body.trim());
        return Ok(());
    }

    let value: serde_json::Value = serde_json::from_str(body)?;
    let items = value
        .pointer("/queue/items")
        .and_then(|value| value.as_array())
        .cloned()
        .unwrap_or_default();

    println!("Моя волна: {} треков в очереди", items.len());
    for (index, item) in items.iter().take(10).enumerate() {
        let title = item.get("title").and_then(|v| v.as_str()).unwrap_or("?");
        let artists = item
            .get("artists")
            .and_then(|v| v.as_array())
            .map(|list| {
                list.iter()
                    .filter_map(|a| a.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default();
        let mark = if index == 0 { "▶" } else { " " };
        println!("{mark} {:2}. {title} — {artists}", index + 1);
    }
    Ok(())
}

fn ctl(op: &str, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let key = key()?;
    let payload = serde_json::json!({ "op": op }).to_string();
    let response = httpd::request(port, "POST", "/v1/cmd", Some(&key), Some(&payload))?;
    let line = httpd::status_line(&response);

    if !line.contains(" 200 ") {
        return Err(format!("{line} {}", httpd::body_of(&response)).into());
    }

    println!("{}", httpd::body_of(&response).trim());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_key_subcommand_parses() {
        let cli = Cli::try_parse_from(["ymd", "session-key"]).expect("parse");
        assert!(matches!(cli.command, Command::SessionKey));
    }
}
