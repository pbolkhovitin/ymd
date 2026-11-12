//! `ymd` — демон Яндекс Музыки (скелет P0).
//!
//! P0-цель: проверить связку «плагин Noctalia → локальный HTTP/SSE → состояние».
//! GStreamer, MPRIS и API Яндекса появятся в M1 (см. `docs/07-roadmap.md`).

mod api;
mod auth;
mod doctor;
mod httpd;
mod media;
mod mpris;
mod oauth;
mod session;
mod state;

use clap::{Parser, Subcommand};

use crate::state::AppState;

#[derive(Parser, Debug)]
#[command(name = "ymd", version, about = "Yandex Music daemon (P0 skeleton)")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Запустить демон (это же делает systemd --user).
    Serve {
        /// Порт локального API для плагина.
        #[arg(long, default_value_t = 8765)]
        port: u16,
    },
    /// Проверить окружение и напечатать отчёт.
    Doctor,
    /// Напечатать текущее состояние плеера.
    Status {
        #[arg(long)]
        json: bool,
        #[arg(long, default_value_t = 8765)]
        port: u16,
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
            let app = AppState::new();
            app.spawn_ticker();
            httpd::serve(app, port, key).await
        }
        Command::Doctor => {
            doctor::run();
            Ok(())
        }
        Command::Status { json, port } => status(json, port),
        Command::Ctl { op, port } => ctl(&op, port),
        Command::Auth { cmd } => auth_cmd(cmd).await,
        Command::Search { text, page, json } => search_cmd(&text, page, json).await,
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
