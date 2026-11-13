//! Локальный HTTP API для плазмоида KDE: JSON + SSE.
//!
//! Авторизация — capability-файл `$XDG_RUNTIME_DIR/ymd/session.key` в заголовке
//! `X-YMD-Session`. Контракт: `docs/02-architecture.md`.

use std::convert::Infallible;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

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
    /// Текущий Device Flow. Один на демон: второй вход отклоняется.
    auth: Arc<Mutex<AuthFlow>>,
}

/// Состояние входа через OAuth Device Flow.
#[derive(Debug, Clone, Default)]
struct AuthFlow {
    /// `idle` | `pending` | `authorized` | `expired` | `error` | `cancelled`.
    state: String,
    user_code: String,
    url: String,
    expires_in: u64,
    login: Option<String>,
    error: Option<String>,
}

impl AuthFlow {
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "state": if self.state.is_empty() { "idle" } else { &self.state },
            "userCode": self.user_code,
            "url": self.url,
            "expiresIn": self.expires_in,
            "login": self.login,
            "error": self.error,
        })
    }
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
        auth: Arc::new(Mutex::new(AuthFlow::default())),
    };

    let router = Router::new()
        .route("/v1/health", get(health))
        .route("/v1/state", get(get_state))
        .route("/v1/search", get(search))
        .route("/v1/playlists", get(playlists))
        .route("/v1/playlist", get(playlist))
        .route("/v1/favorites", get(favorites))
        .route("/v1/home", get(home))
        .route("/v1/discovery/metatags", get(metatags))
        .route("/v1/discovery/genres", get(genres))
        .route("/v1/discovery/tag", get(tag_page))
        .route("/v1/radio", post(radio))
        .route("/v1/cache", get(cache_info))
        .route("/v1/config", get(config_get).patch(config_patch))
        .route("/v1/account", get(account))
        .route(
            "/v1/auth/device",
            post(auth_device_start)
                .get(auth_device_status)
                .delete(auth_device_cancel),
        )
        .route("/v1/auth/logout", post(auth_logout))
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

    match shared
        .app
        .command_async(&request.op, request.payload.as_ref())
        .await
    {
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
                .filter(|item| {
                    item.get("available").and_then(serde_json::Value::as_bool) != Some(false)
                })
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

/// `GET /v1/favorites` — «Мне нравится» (плейлист `kind = 3`).
async fn favorites(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let account = crate::auth::load_account().ok_or_else(no_account)?;
    let client = crate::api::Client::from_store().map_err(|err| bad_gateway(err.to_string()))?;
    let value = client
        .playlist(account.uid, 3)
        .await
        .map_err(|err| bad_gateway(err.to_string()))?;

    let tracks: Vec<serde_json::Value> = value
        .get("tracks")
        .and_then(serde_json::Value::as_array)
        .map(|items| items.iter().filter_map(simplify_track).collect())
        .unwrap_or_default();

    Ok(Json(serde_json::json!({
        "playlist": simplify_playlist(&value, account.uid),
        "tracks": tracks,
    })))
}

/// `GET /v1/home` — блоки главной, нормализованные для клиентов.
async fn home(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let client = crate::api::Client::from_store().map_err(|err| bad_gateway(err.to_string()))?;
    let value = client
        .landing()
        .await
        .map_err(|err| bad_gateway(err.to_string()))?;
    Ok(Json(serde_json::json!({ "blocks": home_blocks(&value) })))
}

/// `GET /v1/discovery/metatags` — деревья настроений, занятий, жанров, эпох.
async fn metatags(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let client = crate::api::Client::from_store().map_err(|err| bad_gateway(err.to_string()))?;
    let value = client
        .metatags()
        .await
        .map_err(|err| bad_gateway(err.to_string()))?;

    let trees = value
        .pointer("/result/trees")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();
    let groups: Vec<serde_json::Value> = trees
        .iter()
        .map(|tree| {
            let leaves = tree
                .get("leaves")
                .and_then(serde_json::Value::as_array)
                .map(|leaves| tag_nodes(leaves))
                .unwrap_or_default();
            serde_json::json!({
                "id": tree.get("navigationId").and_then(serde_json::Value::as_str).unwrap_or(""),
                "title": tree.get("title").and_then(serde_json::Value::as_str).unwrap_or(""),
                "tags": leaves,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "groups": groups })))
}

/// `GET /v1/discovery/genres` — жанры с поджанрами.
async fn genres(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let client = crate::api::Client::from_store().map_err(|err| bad_gateway(err.to_string()))?;
    let value = client
        .genres()
        .await
        .map_err(|err| bad_gateway(err.to_string()))?;

    let items = value
        .get("result")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();
    let genres: Vec<serde_json::Value> = items
        .iter()
        .filter_map(|item| {
            let id = item.get("id").and_then(serde_json::Value::as_str)?;
            let sub: Vec<serde_json::Value> = item
                .get("subGenres")
                .and_then(serde_json::Value::as_array)
                .map(|subs| {
                    subs.iter()
                        .filter_map(|sub| {
                            Some(serde_json::json!({
                                "id": sub.get("id").and_then(serde_json::Value::as_str)?,
                                "title": sub.get("title").and_then(serde_json::Value::as_str).unwrap_or(""),
                            }))
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(serde_json::json!({
                "id": id,
                "title": item.get("title").and_then(serde_json::Value::as_str).unwrap_or(id),
                "subGenres": sub,
                "station": format!("genre:{id}"),
            }))
        })
        .collect();

    Ok(Json(serde_json::json!({ "genres": genres })))
}

#[derive(Deserialize)]
struct TagParams {
    tag: String,
}

/// `GET /v1/discovery/tag?tag=...` — плейлисты тега и станция для радио.
async fn tag_page(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
    Query(params): Query<TagParams>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let tag = params.tag.trim();
    if tag.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "нужен tag".to_string()));
    }
    let client = crate::api::Client::from_store().map_err(|err| bad_gateway(err.to_string()))?;
    let value = client
        .metatag_playlists(tag)
        .await
        .map_err(|err| bad_gateway(err.to_string()))?;
    let result = value.get("result").unwrap_or(&value);

    let playlists: Vec<serde_json::Value> = result
        .get("playlists")
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| simplify_playlist(item, 0))
                .collect()
        })
        .unwrap_or_default();

    Ok(Json(serde_json::json!({
        "tag": tag,
        "title": text_of(result.get("title")).unwrap_or_else(|| tag.to_string()),
        "station": result.get("stationId").and_then(serde_json::Value::as_str),
        "playlists": playlists,
    })))
}

#[derive(Deserialize)]
struct RadioBody {
    station: String,
}

/// `POST /v1/radio` — запустить радио по станции.
async fn radio(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
    Json(body): Json<RadioBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let station = body.station.trim().to_string();
    if station.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "нужна station".to_string()));
    }
    shared
        .app
        .radio_start(&station)
        .await
        .map_err(|err| bad_gateway(err))?;
    Ok(Json(serde_json::json!({ "ok": true, "station": station })))
}

/// `GET /v1/config` — эффективные настройки демона.
async fn config_get(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !authorized(&headers, &shared.key) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(crate::config::as_json()))
}

/// `PATCH /v1/config` — точечно меняет качество, фоллбэк и лимит кэша.
async fn config_patch(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let quality = body.get("quality").and_then(serde_json::Value::as_str);
    let fallback = body.get("fallbackHq").and_then(serde_json::Value::as_bool);
    let limit = body.get("cacheLimitMb").and_then(serde_json::Value::as_u64);

    crate::config::patch(quality, fallback, limit)
        .map_err(|err| (StatusCode::BAD_REQUEST, format!("config: {err}")))?;
    // Качество отражается в состоянии сразу: клиенты читают его из /v1/state.
    if let Some(value) = quality {
        let _ = shared
            .app
            .command("quality", Some(&serde_json::json!({ "value": value })));
    } else {
        shared.app.refresh();
    }
    Ok(Json(crate::config::as_json()))
}

/// `GET /v1/account` — кто вошёл и есть ли Plus.
async fn account(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let account = crate::auth::load_account().ok_or_else(no_account)?;
    Ok(Json(serde_json::json!({
        "login": account.login,
        "uid": account.uid,
        "plus": account.has_plus,
        "backend": account.backend,
        "savedAt": account.saved_at,
    })))
}

/// `POST /v1/auth/device` — начать вход через Device Flow.
async fn auth_device_start(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    {
        let flow = shared.auth.lock().map_err(|_| poisoned())?;
        if flow.state == "pending" {
            return Err((StatusCode::CONFLICT, "вход уже идёт".to_string()));
        }
    }

    let code = crate::oauth::request_device_code()
        .await
        .map_err(|err| bad_gateway(err.to_string()))?;

    {
        let mut flow = shared.auth.lock().map_err(|_| poisoned())?;
        flow.state = "pending".to_string();
        flow.user_code = code.user_code.clone();
        flow.url = code.verification_url.clone();
        flow.expires_in = code.expires_in;
        flow.login = None;
        flow.error = None;
    }

    let flow_ref = shared.auth.clone();
    let app = shared.app.clone();
    tokio::spawn(async move {
        let mut state = "error".to_string();
        let mut login = None;
        let mut error = None;

        match crate::oauth::poll_token(&code).await {
            Ok(Some(token)) => match crate::auth::validate(&token.access_token).await {
                Ok(account) => match crate::auth::save(&account, &token.access_token) {
                    Ok(saved) => {
                        state = "authorized".to_string();
                        login = Some(saved.login);
                    }
                    Err(err) => error = Some(err.to_string()),
                },
                Err(err) => error = Some(err.to_string()),
            },
            Ok(None) => state = "expired".to_string(),
            Err(err) => error = Some(err.to_string()),
        }

        let mut published = false;
        if let Ok(mut flow) = flow_ref.lock() {
            // Отмена: поздний ответ OAuth не должен никого авторизовать.
            if flow.state == "pending" {
                flow.state = state.clone();
                flow.login = login;
                flow.error = error;
                published = state == "authorized";
            }
        }
        if published {
            app.refresh();
        }
    });

    let flow = shared.auth.lock().map_err(|_| poisoned())?;
    Ok(Json(flow.json()))
}

/// `GET /v1/auth/device` — состояние текущего входа.
async fn auth_device_status(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let flow = shared.auth.lock().map_err(|_| poisoned())?;
    Ok(Json(flow.json()))
}

/// `DELETE /v1/auth/device` — отменить ожидание.
async fn auth_device_cancel(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let mut flow = shared.auth.lock().map_err(|_| poisoned())?;
    if flow.state == "pending" {
        flow.state = "cancelled".to_string();
        flow.user_code.clear();
    }
    Ok(Json(flow.json()))
}

/// `POST /v1/auth/logout` — удалить токен и метаданные аккаунта.
async fn auth_logout(
    AxumState(shared): AxumState<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !authorized(&headers, &shared.key) {
        return Err(unauthorized());
    }
    let removed = crate::auth::logout()
        .map_err(|err| (StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;
    shared.app.refresh();
    Ok(Json(
        serde_json::json!({ "loggedOut": true, "removed": removed }),
    ))
}

fn unauthorized() -> (StatusCode, String) {
    (StatusCode::UNAUTHORIZED, "bad session".to_string())
}

fn no_account() -> (StatusCode, String) {
    (StatusCode::UNAUTHORIZED, "нет аккаунта".to_string())
}

fn bad_gateway(message: String) -> (StatusCode, String) {
    (StatusCode::BAD_GATEWAY, message)
}

fn poisoned() -> (StatusCode, String) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "auth flow poisoned".to_string(),
    )
}

/// Текст из строки или `{title}`.
fn text_of(value: Option<&serde_json::Value>) -> Option<String> {
    let value = value?;
    value.as_str().map(str::to_string).or_else(|| {
        value
            .get("title")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string)
    })
}

fn id_of(value: &serde_json::Value) -> Option<String> {
    value
        .as_u64()
        .map(|num| num.to_string())
        .or_else(|| value.as_str().map(str::to_string))
}

/// Рекурсивно превращает листья метатегов в `{tag, title, children}`.
fn tag_nodes(leaves: &[serde_json::Value]) -> Vec<serde_json::Value> {
    leaves
        .iter()
        .filter_map(|leaf| {
            let tag = leaf.get("tag").and_then(serde_json::Value::as_str)?;
            let children = leaf
                .get("leaves")
                .and_then(serde_json::Value::as_array)
                .map(|leaves| tag_nodes(leaves))
                .unwrap_or_default();
            Some(serde_json::json!({
                "tag": tag,
                "title": leaf.get("title").and_then(serde_json::Value::as_str).unwrap_or(tag),
                "children": children,
            }))
        })
        .collect()
}

/// Нормализует блоки `/landing3`. Неизвестные типы пропускаются: лучше меньше
/// блоков, чем сломанный экран.
fn home_blocks(value: &serde_json::Value) -> Vec<serde_json::Value> {
    let blocks = value
        .pointer("/result/blocks")
        .or_else(|| value.get("blocks"))
        .and_then(serde_json::Value::as_array);

    let mut out = Vec::new();
    for block in blocks.cloned().unwrap_or_default() {
        let mut items = Vec::new();
        if let Some(entities) = block.get("entities").and_then(serde_json::Value::as_array) {
            for entity in entities {
                let entity_type = entity
                    .get("type")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let data = entity
                    .get("data")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                let (kind, object) = match entity_type {
                    "album" => ("album", data),
                    "playlist" => ("playlist", data),
                    "personal-playlist" => (
                        "playlist",
                        data.get("data").cloned().unwrap_or(serde_json::Value::Null),
                    ),
                    "chart-item" => (
                        "track",
                        data.get("track")
                            .cloned()
                            .unwrap_or(serde_json::Value::Null),
                    ),
                    _ => continue,
                };
                if let Some(item) = home_item(kind, &object) {
                    items.push(item);
                }
            }
        }
        if items.is_empty() {
            continue;
        }
        out.push(serde_json::json!({
            "id": block.get("id").and_then(serde_json::Value::as_str).unwrap_or(""),
            "title": block.get("title").and_then(serde_json::Value::as_str).unwrap_or(""),
            "type": block.get("type").and_then(serde_json::Value::as_str).unwrap_or(""),
            "items": items,
        }));
    }
    out
}

fn home_item(kind: &str, object: &serde_json::Value) -> Option<serde_json::Value> {
    match kind {
        "track" => simplify_track(object),
        "playlist" => {
            let uid = object.get("uid").and_then(serde_json::Value::as_u64)?;
            let playlist_kind = object.get("kind").and_then(serde_json::Value::as_u64)?;
            Some(serde_json::json!({
                "id": format!("{uid}:{playlist_kind}"),
                "kind": "playlist",
                "uid": uid,
                "playlistKind": playlist_kind,
                "title": object.get("title").and_then(serde_json::Value::as_str).unwrap_or("Плейлист"),
                "subtitle": object.pointer("/owner/name").and_then(serde_json::Value::as_str).unwrap_or(""),
                "cover": object
                    .pointer("/cover/uri")
                    .or_else(|| object.pointer("/cover/itemsUri/0"))
                    .and_then(serde_json::Value::as_str)
                    .and_then(crate::state::cover_url),
                "trackCount": object.get("trackCount").and_then(serde_json::Value::as_u64).unwrap_or(0),
            }))
        }
        "album" => {
            let id = object.get("id").and_then(id_of)?;
            let artists: Vec<String> = object
                .get("artists")
                .and_then(serde_json::Value::as_array)
                .map(|artists| {
                    artists
                        .iter()
                        .filter_map(|artist| {
                            artist
                                .get("name")
                                .and_then(serde_json::Value::as_str)
                                .map(str::to_string)
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(serde_json::json!({
                "id": id,
                "kind": "album",
                "title": object.get("title").and_then(serde_json::Value::as_str).unwrap_or("Альбом"),
                "subtitle": artists.join(", "),
                "cover": object
                    .get("coverUri")
                    .and_then(serde_json::Value::as_str)
                    .and_then(crate::state::cover_url),
                "year": object.get("year").and_then(serde_json::Value::as_u64),
            }))
        }
        _ => None,
    }
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
    let playlist_index = item
        .get("originalIndex")
        .and_then(serde_json::Value::as_u64);
    let item = item.get("track").unwrap_or(item);
    let id = item.get("id").and_then(|v| {
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
    let album_id = item
        .get("albumId")
        .or_else(|| item.pointer("/albums/0/id"))
        .and_then(|v| {
            v.as_u64()
                .map(|n| n.to_string())
                .or_else(|| v.as_str().map(str::to_string))
        });
    let liked = item
        .get("liked")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);

    Some(serde_json::json!({
        "id": id,
        "title": title,
        "artists": artists,
        "album": album,
        "albumId": album_id,
        "durationMs": duration_ms,
        "liked": liked,
        "cover": cover,
        "cached": crate::cache::is_cached(&id),
        "playlistIndex": playlist_index,
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
    let revision = item
        .get("revision")
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
        "revision": revision,
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
    fn home_block_unwraps_personal_playlist_and_skips_unknown() {
        let value = serde_json::json!({
            "result": { "blocks": [{
                "id": "b1", "title": "Собираем для вас", "type": "personal-playlists",
                "entities": [
                    { "type": "personal-playlist", "data": { "data": {
                        "uid": 42, "kind": 1036, "title": "Мой микс", "trackCount": 7,
                        "owner": { "name": "Я" },
                        "cover": { "itemsUri": ["avatars.yandex.net/get/1/%%"] }
                    }}},
                    { "type": "promotion", "data": { "title": "Реклама" } }
                ]
            }]}
        });
        let blocks = home_blocks(&value);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0]["items"].as_array().unwrap().len(), 1);
        assert_eq!(blocks[0]["items"][0]["id"], "42:1036");
        assert_eq!(blocks[0]["items"][0]["title"], "Мой микс");
    }

    #[test]
    fn tag_nodes_keep_nested_children() {
        let leaves = serde_json::json!([
            { "tag": "Рок", "title": "Рок", "leaves": [{ "tag": "Панк", "title": "Панк" }] }
        ]);
        let nodes = tag_nodes(leaves.as_array().unwrap());
        assert_eq!(nodes[0]["title"], "Рок");
        assert_eq!(nodes[0]["children"][0]["tag"], "Панк");
    }

    #[test]
    fn playlist_cover_and_id_are_normalized() {
        let value = serde_json::json!({
            "uid": 42,
            "kind": 1036,
            "title": "Мой плейлист",
            "trackCount": 12,
            "revision": 3,
            "cover": {
                "type": "mosaic",
                "itemsUri": ["avatars.yandex.net/get-music-content/1/2/%%"]
            }
        });
        let playlist = simplify_playlist(&value, 42);
        assert_eq!(playlist["id"], "42:1036");
        assert_eq!(playlist["trackCount"], 12);
        assert_eq!(playlist["revision"], 3);
        assert_eq!(
            playlist["cover"],
            "https://avatars.yandex.net/get-music-content/1/2/400x400"
        );
    }

    #[test]
    fn playlist_track_unwraps_wrapper() {
        let value = serde_json::json!({
            "id": 123,
            "originalIndex": 4,
            "track": {
                "id": 7,
                "title": "Трек",
                "artists": [{ "name": "Артист" }],
                "albums": [{ "id": 55, "title": "Альбом", "coverUri": "avatars/%%" }],
                "durationMs": 180000,
                "liked": true
            }
        });
        let track = simplify_track(&value).unwrap();
        assert_eq!(track["id"], "7");
        assert_eq!(track["artists"][0], "Артист");
        assert_eq!(track["album"], "Альбом");
        assert_eq!(track["albumId"], "55");
        assert_eq!(track["durationMs"], 180000);
        assert_eq!(track["cover"], "https://avatars/400x400");
        assert_eq!(track["playlistIndex"], 4);
        assert_eq!(track["liked"], true);
    }
}
