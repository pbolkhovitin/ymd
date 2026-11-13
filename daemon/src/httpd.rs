//! Локальный HTTP API для плазмоида KDE: JSON + SSE.
//!
//! Авторизация — capability-файл `$XDG_RUNTIME_DIR/ymd/session.key` в заголовке
//! `X-YMD-Session`. Контракт: `docs/02-architecture.md`.

use std::convert::Infallible;
use std::io::{Read, Write};

use axum::{
    extract::{Query, State as AxumState},
    http::{HeaderMap, StatusCode},
    response::{
        sse::{Event, KeepAlive, Sse},
        Json,
    },
    routing::{get, post},
    Router,
};
use futures::{future, StreamExt};
use serde::Deserialize;
use tokio_stream::wrappers::BroadcastStream;

use crate::state::{AppState, State};

#[derive(Clone)]
struct Shared {
    app: AppState,
    key: String,
    started: std::time::Instant,
}

pub async fn serve(
    app: AppState,
    port: u16,
    key: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let shared = Shared {
        app,
        key,
        started: std::time::Instant::now(),
    };

    let router = Router::new()
        .route("/v1/health", get(health))
        .route("/v1/state", get(get_state))
        .route("/v1/search", get(search))
        .route("/v1/playlists", get(playlists))
        .route("/v1/playlist", get(playlist))
        .route("/v1/cache", get(cache_info))
        .route("/v1/cmd", post(cmd))
        .route("/v1/events", get(events))
        .with_state(shared);

    let addr = format!("127.0.0.1:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("listening on http://{addr}");
    axum::serve(listener, router).await?;
    Ok(())
}

async fn health(AxumState(shared): AxumState<Shared>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "ok": true,
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_s": shared.started.elapsed().as_secs(),
        "state_rev": shared.app.snapshot().rev,
    }))
}

async fn get_state(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<State>, StatusCode> {
    if !authorized(&headers, &shared.key) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(shared.app.snapshot()))
}

#[derive(Deserialize)]
struct CmdRequest {
    op: String,
    #[serde(default)]
    payload: Option<serde_json::Value>,
}

async fn cmd(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
    Json(request): Json<CmdRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err((
            StatusCode::UNAUTHORIZED,
            "bad or missing X-YMD-Session".to_string(),
        ));
    }

    match shared.app.command_async(&request.op, request.payload.as_ref()).await {
        Ok(rev) => Ok(Json(serde_json::json!({ "ok": true, "rev": rev }))),
        Err(err) => Err((StatusCode::BAD_REQUEST, err)),
    }
}

#[derive(Deserialize)]
struct SearchParams {
    q: String,
    #[serde(default)]
    page: Option<u32>,
}

/// `GET /v1/search?q=...` — поиск через API Яндекса, упрощённый для виджета.
async fn search(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
    Query(params): Query<SearchParams>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err((StatusCode::UNAUTHORIZED, "bad session".to_string()));
    }

    let text = params.q.trim().to_string();
    if text.is_empty() {
        return Ok(Json(serde_json::json!({ "query": "", "tracks": [] })));
    }

    let client = crate::api::Client::from_store().map_err(|err| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            format!("нет токена: {err}; выполните ymd auth import --from-official"),
        )
    })?;

    let value = client
        .search(&text, params.page.unwrap_or(0))
        .await
        .map_err(|err| (StatusCode::BAD_GATEWAY, err.to_string()))?;

    Ok(Json(serde_json::json!({
        "query": text,
        "tracks": simplify_tracks(&value),
    })))
}

/// `GET /v1/playlists` — плейлисты текущего пользователя.
async fn playlists(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err((StatusCode::UNAUTHORIZED, "bad session".to_string()));
    }

    let account = crate::auth::load_account()
        .ok_or_else(|| (StatusCode::UNAUTHORIZED, "нет аккаунта".to_string()))?;
    let client = crate::api::Client::from_store()
        .map_err(|err| (StatusCode::SERVICE_UNAVAILABLE, err.to_string()))?;
    let value = client
        .playlists(account.uid)
        .await
        .map_err(|err| (StatusCode::BAD_GATEWAY, err.to_string()))?;

    let playlists: Vec<serde_json::Value> = value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter(|item| item.get("available").and_then(serde_json::Value::as_bool) != Some(false))
                .map(|item| simplify_playlist(item, account.uid))
                .collect()
        })
        .unwrap_or_default();

    Ok(Json(serde_json::json!({ "playlists": playlists })))
}

#[derive(Deserialize)]
struct PlaylistParams {
    uid: u64,
    kind: u64,
}

/// `GET /v1/playlist?uid=...&kind=...` — метаданные и треки плейлиста.
async fn playlist(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
    Query(params): Query<PlaylistParams>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err((StatusCode::UNAUTHORIZED, "bad session".to_string()));
    }

    let client = crate::api::Client::from_store()
        .map_err(|err| (StatusCode::SERVICE_UNAVAILABLE, err.to_string()))?;
    let value = client
        .playlist(params.uid, params.kind)
        .await
        .map_err(|err| (StatusCode::BAD_GATEWAY, err.to_string()))?;

    let tracks: Vec<serde_json::Value> = value
        .get("tracks")
        .and_then(serde_json::Value::as_array)
        .map(|items| items.iter().filter_map(simplify_track).collect())
        .unwrap_or_default();
    let meta = simplify_playlist(&value, params.uid);

    Ok(Json(serde_json::json!({
        "playlist": meta,
        "tracks": tracks,
    })))
}

/// `GET /v1/cache` — содержимое офлайн-кэша и лимит.
async fn cache_info(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !authorized(&headers, &shared.key) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(serde_json::json!({
        "items": crate::cache::list(),
        "totalBytes": crate::cache::total_bytes(),
        "limitBytes": crate::cache::limit_bytes(),
        "dir": crate::cache::dir().display().to_string(),
    })))
}

/// Приводит ответ `/search` к плоскому списку треков для плагина.
fn simplify_tracks(value: &serde_json::Value) -> Vec<serde_json::Value> {
    value
        .pointer("/tracks/results")
        .or_else(|| value.pointer("/result/tracks/results"))
        .and_then(serde_json::Value::as_array)
        .map(|items| items.iter().filter_map(simplify_track).collect())
        .unwrap_or_default()
}

/// Плоский трек для UI. Понимает и полный объект трека, и обёртку
/// `{ "track": {...} }` из плейлиста.
fn simplify_track(item: &serde_json::Value) -> Option<serde_json::Value> {
    let item = item.get("track").unwrap_or(item);
    let id = item
        .get("id")
        .and_then(|v| {
            v.as_u64()
                .map(|n| n.to_string())
                .or_else(|| v.as_str().map(str::to_string))
        })?;
    let title = item
        .get("title")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("Без названия")
        .to_string();
    let artists: Vec<String> = item
        .get("artists")
        .and_then(serde_json::Value::as_array)
        .map(|artists| {
            artists
                .iter()
                .filter_map(|a| {
                    a.as_str().map(str::to_string).or_else(|| {
                        a.get("name")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string)
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let duration_ms = item
        .get("durationMs")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    let album = item
        .get("album")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            item.pointer("/albums/0/title")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        });
    // coverUri приходит как "avatars.yandex.net/get-music-content/.../%%".
    let cover = item
        .get("coverUri")
        .or_else(|| item.pointer("/albums/0/coverUri"))
        .and_then(serde_json::Value::as_str)
        .and_then(crate::state::cover_url);

    Some(serde_json::json!({
        "id": id,
        "title": title,
        "artists": artists,
        "album": album,
        "durationMs": duration_ms,
        "liked": false,
        "cover": cover,
        "cached": crate::cache::is_cached(&id),
    }))
}

/// Метаданные плейлиста для списка и шапки. Обложка-мозаика берётся из
/// `cover.itemsUri[0]`, кастомная — из `cover.uri`.
fn simplify_playlist(item: &serde_json::Value, fallback_uid: u64) -> serde_json::Value {
    let uid = item
        .get("uid")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(fallback_uid);
    let kind = item
        .get("kind")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    let title = item
        .get("title")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("Плейлист")
        .to_string();
    let track_count = item
        .get("trackCount")
        .and_then(serde_json::Value::as_u64)
        .or_else(|| {
            item.get("tracks")
                .and_then(serde_json::Value::as_array)
                .map(|tracks| tracks.len() as u64)
        })
        .unwrap_or(0);
    let duration_ms = item
        .get("durationMs")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    let cover = item
        .pointer("/cover/uri")
        .or_else(|| item.pointer("/cover/itemsUri/0"))
        .and_then(serde_json::Value::as_str)
        .and_then(crate::state::cover_url);

    serde_json::json!({
        "id": format!("{uid}:{kind}"),
        "uid": uid,
        "kind": kind,
        "title": title,
        "trackCount": track_count,
        "cover": cover,
        "durationMs": duration_ms,
    })
}

async fn events(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Sse<impl futures::Stream<Item = Result<Event, Infallible>>>, StatusCode> {
    if !authorized(&headers, &shared.key) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let receiver = shared.app.subscribe();
    let stream = BroadcastStream::new(receiver).filter_map(|item| {
        future::ready(
            item.ok()
                .map(|text| Ok(Event::default().event("state").data(text))),
        )
    });

    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(std::time::Duration::from_secs(15))))
}

fn authorized(headers: &HeaderMap, key: &str) -> bool {
    headers
        .get("x-ymd-session")
        .and_then(|value| value.to_str().ok())
        .map(|value| value == key)
        .unwrap_or(false)
}

// ─── Мини-клиент для CLI (ymd status / ymd ctl) ───────────────────────────────
// Намеренно без reqwest: нужен только loopback.

pub fn request(
    port: u16,
    method: &str,
    path: &str,
    key: Option<&str>,
    body: Option<&str>,
) -> std::io::Result<String> {
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port))?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;

    let payload = body.unwrap_or("");
    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n",
        payload.len()
    );
    if let Some(key) = key {
        request.push_str(&format!("X-YMD-Session: {key}\r\n"));
    }
    request.push_str("\r\n");
    request.push_str(payload);

    stream.write_all(request.as_bytes())?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw)?;
    Ok(String::from_utf8_lossy(&raw).into_owned())
}

pub fn status_line(response: &str) -> &str {
    response.lines().next().unwrap_or("")
}

pub fn body_of(response: &str) -> &str {
    response.split("\r\n\r\n").nth(1).unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn playlist_cover_and_id_are_normalized() {
        let value = serde_json::json!({
            "uid": 42,
            "kind": 1036,
            "title": "Мой плейлист",
            "trackCount": 12,
            "cover": {
                "type": "mosaic",
                "itemsUri": ["avatars.yandex.net/get-music-content/1/2/%%"]
            }
        });
        let playlist = simplify_playlist(&value, 42);
        assert_eq!(playlist["id"], "42:1036");
        assert_eq!(playlist["trackCount"], 12);
        assert_eq!(
            playlist["cover"],
            "https://avatars.yandex.net/get-music-content/1/2/400x400"
        );
    }

    #[test]
    fn playlist_track_unwraps_wrapper() {
        let value = serde_json::json!({
            "id": 123,
            "track": {
                "id": 7,
                "title": "Трек",
                "artists": [{ "name": "Артист" }],
                "albums": [{ "title": "Альбом", "coverUri": "avatars/%%" }],
                "durationMs": 180000
            }
        });
        let track = simplify_track(&value).unwrap();
        assert_eq!(track["id"], "7");
        assert_eq!(track["artists"][0], "Артист");
        assert_eq!(track["album"], "Альбом");
        assert_eq!(track["durationMs"], 180000);
        assert_eq!(track["cover"], "https://avatars/400x400");
    }
}
