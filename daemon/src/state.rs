//! Состояние плеера и команды.
//!
//! Контракт `/v1/state` — camelCase (его читает плазмоид KDE). Источник
//! состояния — собственный GStreamer-плеер; внешний MPRIS используется как
//! резервный, пока локальный плеер не взял управление.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::broadcast;

pub const CHANNEL_CAPACITY: usize = 64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub liked: bool,
    #[serde(default)]
    pub cover: Option<String>,
}

impl Track {
    pub fn artist_line(&self) -> String {
        self.artists.join(", ")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueItem {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub cover: Option<String>,
}

impl From<&Track> for QueueItem {
    fn from(track: &Track) -> Self {
        Self {
            id: track.id.clone(),
            title: track.title.clone(),
            artists: track.artists.clone(),
            duration_ms: track.duration_ms,
            cover: track.cover.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Queue {
    #[serde(default)]
    pub items: Vec<QueueItem>,
    pub length: usize,
    pub index: usize,
    pub shuffle: bool,
    pub repeat: String,
}

impl Default for Queue {
    fn default() -> Self {
        Self {
            items: Vec::new(),
            length: 0,
            index: 0,
            shuffle: false,
            repeat: "all".to_string(),
        }
    }
}

impl Queue {
    fn sync_length(&mut self) {
        self.length = self.items.len();
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvState {
    pub fullscreen: bool,
    pub overview: bool,
    pub idle: bool,
    pub on_battery: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    pub mode: String,
}

impl Default for UiState {
    fn default() -> Self {
        Self {
            mode: "full".to_string(),
        }
    }
}

/// Состояние сессии «Моей волны».
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaveInfo {
    pub session_id: String,
    pub batch_id: Option<String>,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub rev: u64,
    pub status: String,
    pub track: Option<Track>,
    pub position_ms: u64,
    pub volume: f64,
    pub queue: Queue,
    pub env: EnvState,
    pub ui: UiState,
    /// Сессия радио, если включена «Моя волна».
    #[serde(default)]
    pub wave: Option<WaveInfo>,
    /// Фактическое качество текущего потока (`lossless`, `hq`, …).
    #[serde(default = "default_quality_label")]
    pub quality: String,
    /// Кодек текущего потока (`flac-mp4`, `aac256-mp4`, …).
    #[serde(default)]
    pub codec: Option<String>,
}

fn default_quality_label() -> String {
    "lossless".to_string()
}

impl Default for State {
    fn default() -> Self {
        Self {
            rev: 0,
            status: "paused".to_string(),
            track: None,
            position_ms: 0,
            volume: 0.8,
            queue: Queue::default(),
            env: EnvState::default(),
            ui: UiState::default(),
            wave: None,
            quality: default_quality_label(),
            codec: None,
        }
    }
}

/// Результат резолва потока: URL плюс фактические качество и кодек.
struct ResolvedStream {
    url: String,
    quality: String,
    codec: String,
}

/// Общий стейт демона. Дешёвый клон: внутри `Arc`.
#[derive(Clone)]
pub struct AppState {
    inner: Arc<RwLock<State>>,
    tx: broadcast::Sender<String>,
    /// true, когда состоянием управляет внешний MPRIS-плеер.
    external: Arc<AtomicBool>,
    /// Локальный плеер. Если в него загружен поток, он главнее внешнего MPRIS.
    player: Option<Arc<crate::player::Player>>,
    /// true, когда звук идёт из локального плеера.
    local: Arc<AtomicBool>,
    /// true, после первого успешного запуска локального плеера: с этого момента
    /// внешний MPRIS больше не подменяет состояние.
    owned: Arc<AtomicBool>,
    /// Защита от параллельных догрузок «Моей волны».
    wave_pending: Arc<AtomicBool>,
}

impl AppState {
    pub fn new() -> Self {
        let (tx, _rx) = broadcast::channel(CHANNEL_CAPACITY);
        let mut state = State::default();
        // Панель должна показывать качество из конфига ещё до первого трека.
        state.quality = crate::config::load().playback.quality;
        Self {
            inner: Arc::new(RwLock::new(state)),
            tx,
            external: Arc::new(AtomicBool::new(false)),
            player: None,
            local: Arc::new(AtomicBool::new(false)),
            owned: Arc::new(AtomicBool::new(false)),
            wave_pending: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Демон со звуком: локальный плеер становится основным источником.
    pub fn with_player(player: crate::player::Player) -> Self {
        let mut app = Self::new();
        app.player = Some(Arc::new(player));
        app
    }

    pub fn is_local(&self) -> bool {
        self.local.load(Ordering::Relaxed)
    }

    /// Плеер демона уже использовался — внешний MPRIS не должен перехватывать.
    pub fn owns_output(&self) -> bool {
        self.owned.load(Ordering::Relaxed)
    }

    pub fn snapshot(&self) -> State {
        self.inner
            .read()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }

    pub fn is_external(&self) -> bool {
        self.external.load(Ordering::Relaxed)
    }

    /// Выполняет команду и рассылает новое состояние подписчикам SSE.
    pub fn command(&self, op: &str, payload: Option<&Value>) -> Result<u64, String> {
        // Внешний плеер умеет только транспортные команды; остальное — локально.
        let transport = matches!(op, "toggle" | "play" | "pause" | "next" | "prev");
        if transport && self.is_local() {
            if let Some(player) = &self.player {
                let result = match op {
                    "toggle" => player.toggle(),
                    "play" => player.play(),
                    "pause" => player.pause(),
                    _ => Ok(()),
                };
                if let Err(err) = result {
                    tracing::warn!("player {op}: {err}");
                }
            }
        } else if transport && self.is_external() && crate::mpris::send(op) {
            if let Some(snapshot) = crate::mpris::poll() {
                return Ok(self.apply_mpris(snapshot));
            }
        }

        let snapshot = {
            let mut st = self
                .inner
                .write()
                .map_err(|_| "state lock poisoned".to_string())?;

            match op {
                "toggle" => {
                    st.status = if st.status == "playing" {
                        "paused".to_string()
                    } else {
                        "playing".to_string()
                    };
                }
                "play" => st.status = "playing".to_string(),
                "pause" => st.status = "paused".to_string(),
                "stop" => {
                    st.status = "stopped".to_string();
                    st.position_ms = 0;
                    if let Some(player) = &self.player {
                        player.stop();
                    }
                    self.local.store(false, Ordering::Relaxed);
                }
                "next" => advance(&mut st, 1),
                "prev" => advance(&mut st, -1),
                "like" => {
                    let liked = st.track.as_ref().map(|t| !t.liked).unwrap_or(false);
                    if let Some(track) = st.track.as_mut() {
                        track.liked = liked;
                    }
                }
                "wave_stop" => {
                    st.wave = None;
                }
                "wave" => {}
                "quality" => {
                    let value = payload
                        .and_then(|p| p.get("value"))
                        .and_then(Value::as_str)
                        .ok_or_else(|| "quality: нужен value".to_string())?;
                    crate::config::set_quality(value)?;
                    st.quality = value.to_string();
                }
                "mode" => {
                    st.ui.mode = if st.ui.mode == "full" {
                        "compact".to_string()
                    } else {
                        "full".to_string()
                    };
                }
                "play_track" => {
                    let track = track_from_payload(payload)?;
                    // Уже в очереди — переключаемся, иначе ставим сразу после текущего.
                    let index = match st.queue.items.iter().position(|item| item.id == track.id) {
                        Some(index) => index,
                        None => {
                            let at = if st.queue.items.is_empty() {
                                0
                            } else {
                                st.queue.index + 1
                            };
                            st.queue.items.insert(at, QueueItem::from(&track));
                            at
                        }
                    };
                    st.queue.index = index;
                    st.queue.sync_length();
                    st.track = Some(track);
                    st.position_ms = 0;
                    st.status = "playing".to_string();
                }
                "enqueue" => {
                    let track = track_from_payload(payload)?;
                    st.queue.items.push(QueueItem::from(&track));
                    if st.track.is_none() {
                        st.track = Some(track);
                        st.status = "paused".to_string();
                    }
                    st.queue.sync_length();
                }
                "queue_play" => {
                    let index = payload
                        .and_then(|v| v.get("index"))
                        .and_then(Value::as_u64)
                        .ok_or_else(|| "queue_play: нужен index".to_string())?
                        as usize;
                    if index >= st.queue.items.len() {
                        return Err(format!("queue_play: нет индекса {index}"));
                    }
                    st.queue.index = index;
                    st.track = Some(track_from_queue_item(&st.queue.items[index]));
                    st.position_ms = 0;
                    st.status = "playing".to_string();
                }
                "queue_clear" => {
                    st.queue.items.clear();
                    st.queue.index = 0;
                    st.queue.sync_length();
                }
                "volume" => {
                    let value = payload
                        .and_then(|v| v.get("value"))
                        .and_then(Value::as_f64)
                        .ok_or_else(|| "volume: нужно value".to_string())?;
                    st.volume = value.clamp(0.0, 1.0);
                    if let Some(player) = &self.player {
                        player.set_volume(st.volume);
                    }
                }
                "seek" => {
                    let position = payload
                        .and_then(|v| v.get("positionMs"))
                        .or_else(|| payload.and_then(|v| v.get("position_ms")))
                        .and_then(Value::as_u64)
                        .ok_or_else(|| "seek: нужен positionMs".to_string())?;
                    let duration = st.track.as_ref().map(|t| t.duration_ms).unwrap_or(0);
                    st.position_ms = if duration > 0 {
                        position.min(duration)
                    } else {
                        position
                    };
                    if let Some(player) = &self.player {
                        player.seek_ms(st.position_ms);
                    }
                }
                "repeat" => {
                    let value = payload
                        .and_then(|v| v.get("value"))
                        .and_then(Value::as_str)
                        .ok_or_else(|| "repeat: нужно value".to_string())?;
                    if !matches!(value, "off" | "all" | "one") {
                        return Err(format!("repeat: неизвестный режим {value}"));
                    }
                    st.queue.repeat = value.to_string();
                }
                "shuffle" => {
                    let value = payload
                        .and_then(|v| v.get("value"))
                        .and_then(Value::as_bool)
                        .ok_or_else(|| "shuffle: нужно value".to_string())?;
                    st.queue.shuffle = value;
                }
                "queue_remove" => {
                    let index = payload
                        .and_then(|v| v.get("index"))
                        .and_then(Value::as_u64)
                        .ok_or_else(|| "queue_remove: нужен index".to_string())?
                        as usize;
                    if index >= st.queue.items.len() {
                        return Err(format!("queue_remove: нет индекса {index}"));
                    }
                    st.queue.items.remove(index);
                    if st.queue.index > index {
                        st.queue.index -= 1;
                    }
                    if st.queue.index >= st.queue.items.len() {
                        st.queue.index = st.queue.items.len().saturating_sub(1);
                    }
                    st.queue.sync_length();
                }
                other => return Err(format!("unknown op: {other}")),
            }

            // Появился URL потока — отдаём его локальному плееру.
            // Если очередь закончилась (repeat=off), не запускаем звук заново.
            if st.status != "stopped" && matches!(op, "play_track" | "queue_play" | "next" | "prev") {
                if let Some(url) = payload.and_then(|v| v.get("url")).and_then(Value::as_str) {
                    if let Some(player) = &self.player {
                        match player.load(url) {
                            Ok(()) => {
                                self.local.store(true, Ordering::Relaxed);
                                self.owned.store(true, Ordering::Relaxed);
                                st.status = "playing".to_string();
                            }
                            Err(err) => tracing::warn!("player load: {err}"),
                        }
                    }
                }
            }

            // Конец очереди без повтора: гасим звук и выходим из локального режима.
            if st.status == "stopped" && self.is_local() {
                if let Some(player) = &self.player {
                    player.stop();
                }
                self.local.store(false, Ordering::Relaxed);
            }

            // Локальный плеер — источник истины по статусу, но во время
            // буферизации не сбрасываем в paused.
            if self.is_local() {
                if let Some(player) = &self.player {
                    if player.is_playing() || player.is_buffering() {
                        st.status = "playing".to_string();
                    }
                }
            }

            st.rev += 1;
            st.clone()
        };

        self.publish(&snapshot);
        Ok(snapshot.rev)
    }

    /// Как `command`, но для операций, которым нужен URL потока, сначала
    /// резолвит его через API — это сетевой вызов, поэтому async.
    pub async fn command_async(&self, op: &str, payload: Option<&Value>) -> Result<u64, String> {
        match op {
            "wave_start" => return self.wave_start().await,
            "wave_more" => return self.wave_more().await,
            "wave_feedback" => return self.wave_feedback(payload).await,
            _ => {}
        }

        let needs_url = matches!(op, "play_track" | "queue_play" | "next" | "prev");
        if !needs_url || self.player.is_none() {
            return self.command(op, payload);
        }

        let track_id = match op {
            "play_track" => payload.and_then(|v| v.get("id")).and_then(value_to_id),
            "queue_play" => payload
                .and_then(|v| v.get("index"))
                .and_then(Value::as_u64)
                .and_then(|index| {
                    self.snapshot()
                        .queue
                        .items
                        .get(index as usize)
                        .map(|item| item.id.clone())
                }),
            _ => {
                let state = self.snapshot();
                let len = state.queue.items.len();
                if len == 0 {
                    None
                } else {
                    let delta = if op == "next" { 1 } else { -1 };
                    let index = (state.queue.index as isize + delta).rem_euclid(len as isize);
                    state
                        .queue
                        .items
                        .get(index as usize)
                        .map(|item| item.id.clone())
                }
            }
        };

        let Some(track_id) = track_id else {
            return self.command(op, payload);
        };

        let resolved = match self.resolve_url(&track_id).await {
            Ok(resolved) => Some(resolved),
            Err(err) => {
                tracing::warn!("stream resolve ({track_id}): {err}");
                None
            }
        };

        // Качество и кодек показываем в состоянии (панель, отладка).
        if let Some(resolved) = &resolved {
            if let Ok(mut st) = self.inner.write() {
                let changed = st.quality != resolved.quality
                    || st.codec.as_deref() != Some(resolved.codec.as_str());
                if changed {
                    st.quality = resolved.quality.clone();
                    st.codec = Some(resolved.codec.clone());
                    st.rev += 1;
                }
            }
        }
        let url = resolved.map(|resolved| resolved.url);

        let mut owned = payload
            .cloned()
            .unwrap_or_else(|| Value::Object(Default::default()));
        if let (Some(url), Some(object)) = (url, owned.as_object_mut()) {
            object.insert("url".to_string(), Value::String(url));
        }

        self.command(op, Some(&owned))
    }

    async fn resolve_url(&self, track_id: &str) -> Result<ResolvedStream, String> {
        // Офлайн-кэш приоритетнее сети: локальный файл играет без токена и сети.
        if let Some(path) = crate::cache::path_for(track_id) {
            tracing::debug!(track = %track_id, file = %path.display(), "play from cache");
            let (quality, codec) = crate::cache::entry_for(track_id)
                .map(|entry| (entry.quality, entry.codec))
                .unwrap_or_else(|| ("cache".to_string(), String::new()));
            return Ok(ResolvedStream {
                url: format!("file://{}", path.display()),
                quality,
                codec,
            });
        }

        let id: u64 = track_id
            .parse()
            .map_err(|_| format!("нечисловой id: {track_id}"))?;
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let wanted = crate::config::quality();
        let (stream, used) = match client.stream(id, wanted).await {
            Ok(stream) => (stream, wanted),
            Err(err) if wanted != crate::api::Quality::Hq && crate::config::fallback_hq() => {
                tracing::warn!(track = %track_id, error = %err, "quality unavailable, falling back to hq");
                let stream = client
                    .stream(id, crate::api::Quality::Hq)
                    .await
                    .map_err(|err| err.to_string())?;
                (stream, crate::api::Quality::Hq)
            }
            Err(err) => return Err(err.to_string()),
        };
        tracing::info!(track = %track_id, codec = %stream.codec, bitrate = stream.bitrate, "stream resolved");
        Ok(ResolvedStream {
            url: stream.url,
            quality: used.as_str().to_string(),
            codec: stream.codec,
        })
    }

    /// Включена ли «Моя волна».
    pub fn wave_active(&self) -> bool {
        self.snapshot().wave.map(|wave| wave.active).unwrap_or(false)
    }

    /// Новая сессия «Моей волны»: очередь заменяется партией радио.
    pub async fn wave_start(&self) -> Result<u64, String> {
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let batch = client.wave_start().await.map_err(|err| err.to_string())?;

        if batch.session_id.is_empty() || batch.tracks.is_empty() {
            return Err("волна: пустой ответ".to_string());
        }

        let items: Vec<QueueItem> = batch
            .tracks
            .iter()
            .filter_map(|value| track_from_value(value).ok())
            .map(|track| QueueItem::from(&track))
            .collect();

        if items.is_empty() {
            return Err("волна: не удалось разобрать треки".to_string());
        }

        {
            let mut st = self.inner.write().map_err(|err| err.to_string())?;
            st.queue.items = items;
            st.queue.sync_length();
            st.queue.index = 0;
            st.queue.shuffle = false;
            st.wave = Some(WaveInfo {
                session_id: batch.session_id.clone(),
                batch_id: batch.batch_id.clone(),
                active: true,
            });
            st.rev += 1;
            let _ = self.tx.send(serde_json::to_string(&*st).unwrap_or_default());
        }

        // `Box::pin` разрывает рекурсию async-функций (`command_async` ↔ `wave_start`).
        Box::pin(self.command_async("queue_play", Some(&serde_json::json!({ "index": 0 })))).await
    }

    /// Догрузка следующей партии треков (вызывается тикером и вручную).
    pub async fn wave_more(&self) -> Result<u64, String> {
        if self.wave_pending.swap(true, Ordering::Relaxed) {
            return Ok(0);
        }
        let result = self.wave_more_inner().await;
        self.wave_pending.store(false, Ordering::Relaxed);
        result
    }

    async fn wave_more_inner(&self) -> Result<u64, String> {
        let wave = self
            .snapshot()
            .wave
            .ok_or_else(|| "волна не запущена".to_string())?;

        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let batch = client
            .wave_more(&wave.session_id)
            .await
            .map_err(|err| err.to_string())?;

        let items: Vec<QueueItem> = batch
            .tracks
            .iter()
            .filter_map(|value| track_from_value(value).ok())
            .map(|track| QueueItem::from(&track))
            .collect();

        if items.is_empty() {
            return Err("волна: пустая партия".to_string());
        }

        let mut st = self.inner.write().map_err(|err| err.to_string())?;
        st.queue.items.extend(items);
        st.queue.sync_length();
        if let Some(wave) = st.wave.as_mut() {
            if batch.batch_id.is_some() {
                wave.batch_id = batch.batch_id;
            }
        }
        st.rev += 1;
        let rev = st.rev;
        let _ = self.tx.send(serde_json::to_string(&*st).unwrap_or_default());
        Ok(rev)
    }

    /// Обратная связь: `like`, `dislike`, `skip`, `trackStarted`.
    async fn wave_feedback(&self, payload: Option<&Value>) -> Result<u64, String> {
        let kind = payload
            .and_then(|value| value.get("value"))
            .and_then(Value::as_str)
            .unwrap_or("trackStarted")
            .to_string();

        let state = self.snapshot();
        let wave = state.wave.ok_or_else(|| "волна не запущена".to_string())?;
        let track_id = state
            .track
            .as_ref()
            .map(|track| track.id.clone())
            .ok_or_else(|| "нет текущего трека".to_string())?;

        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        client
            .wave_feedback(&wave.session_id, &track_id, wave.batch_id.as_deref(), &kind)
            .await
            .map_err(|err| err.to_string())?;

        Ok(state.rev)
    }

    /// Сколько треков осталось до конца очереди.
    pub fn queue_remaining(&self) -> usize {
        let state = self.snapshot();
        state.queue.items.len().saturating_sub(state.queue.index + 1)
    }

    /// Синхронизирует состояние с локальным плеером. Возвращает ревизию.
    fn sync_local(&self, position_ms: u64) -> u64 {
        let (next, changed) = {
            let mut st = match self.inner.write() {
                Ok(guard) => guard,
                Err(_) => return 0,
            };
            let player = self.player.as_ref();
            let active = player
                .map(|p| p.is_playing() || p.is_buffering())
                .unwrap_or(false);
            // «stopped» ставится командой (конец очереди, stop) — не воскрешаем его.
            let status = if active {
                "playing"
            } else if st.status == "stopped" {
                "stopped"
            } else {
                "paused"
            };
            let changed =
                st.status != status || st.position_ms.abs_diff(position_ms) > 1500;
            st.status = status.to_string();
            st.position_ms = position_ms;
            if changed {
                st.rev += 1;
            }
            (st.clone(), changed)
        };
        if changed {
            self.publish(&next);
        }
        next.rev
    }

    /// Один тик «плеера» (P0: позиция без звука).
    pub fn tick(&self) {
        let snapshot = {
            let mut st = match self.inner.write() {
                Ok(guard) => guard,
                Err(_) => return,
            };

            if st.status != "playing" {
                return;
            }

            let duration = st.track.as_ref().map(|t| t.duration_ms).unwrap_or(0);
            st.position_ms = st.position_ms.saturating_add(1000);

            if duration > 0 && st.position_ms >= duration {
                advance(&mut st, 1);
            }

            st.rev += 1;
            st.clone()
        };

        self.publish(&snapshot);
    }

    /// Применяет снимок внешнего MPRIS-плеера. Возвращает новую ревизию.
    pub fn apply_mpris(&self, snapshot: crate::mpris::Snapshot) -> u64 {
        let next = {
            let mut st = match self.inner.write() {
                Ok(guard) => guard,
                Err(_) => return 0,
            };

            let status = match snapshot.status.as_str() {
                "playing" => "playing",
                "paused" => "paused",
                _ => "stopped",
            };
            let changed = st.status != status
                || st.position_ms.abs_diff(snapshot.position_ms) > 1500
                || st
                    .track
                    .as_ref()
                    .map(|t| t.title != snapshot.title)
                    .unwrap_or(true);

            st.status = status.to_string();
            st.position_ms = snapshot.position_ms;
            // Очередью внешнего плеера не управляем.
            st.queue.items.clear();
            st.queue.index = 0;
            st.queue.sync_length();
            st.track = Some(Track {
                id: snapshot.player.clone(),
                title: snapshot.title,
                artists: snapshot.artists,
                album: snapshot.album,
                duration_ms: snapshot.duration_ms,
                liked: false,
                cover: None,
            });

            if changed {
                st.rev += 1;
            }
            st.clone()
        };

        self.publish(&next);
        next.rev
    }

    fn publish(&self, state: &State) {
        if let Ok(text) = serde_json::to_string(state) {
            // Ошибка отправки = нет подписчиков, это нормально.
            let _ = self.tx.send(text);
        }
    }

    pub fn spawn_ticker(&self) {
        let app = self.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(1));
            loop {
                ticker.tick().await;

                // Локальный плеер главнее: он и звук, и позиция.
                // После первого запуска внешний MPRIS не подхватывает эстафету.
                if app.is_local() || app.owns_output() {
                    if !app.is_local() {
                        app.sync_local(0);
                        continue;
                    }
                    let eos = app
                        .player
                        .as_ref()
                        .map(|player| player.poll_eos())
                        .unwrap_or(false);
                    if eos {
                        if let Err(err) = app.command_async("next", None).await {
                            tracing::warn!("next after eos: {err}");
                        }
                        continue;
                    }
                    let position = app
                        .player
                        .as_ref()
                        .map(|player| player.position_ms())
                        .unwrap_or(0);
                    app.sync_local(position);

                    // «Моя волна»: догружаем партию заранее, чтобы не было паузы.
                    if app.wave_active() && app.queue_remaining() <= 1 {
                        let app = app.clone();
                        tokio::spawn(async move {
                            if let Err(err) = app.wave_more().await {
                                tracing::warn!("wave_more: {err}");
                            }
                        });
                    }
                    continue;
                }

                match crate::mpris::poll() {
                    Some(snapshot) => {
                        app.external.store(true, Ordering::Relaxed);
                        app.apply_mpris(snapshot);
                    }
                    None => {
                        app.external.store(false, Ordering::Relaxed);
                        app.tick();
                    }
                }
            }
        });
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

/// Приводит id из JSON (строка или число) к строке.
fn value_to_id(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(str::to_string)
        .or_else(|| value.as_u64().map(|number| number.to_string()))
}

/// Шаг по очереди: +1 — следующий, -1 — предыдущий.
fn advance(state: &mut State, delta: isize) {
    let len = state.queue.items.len();
    if len == 0 {
        state.position_ms = 0;
        return;
    }

    // repeat=one: повтор текущего трека (только вперёд).
    if delta > 0 && state.queue.repeat == "one" {
        state.position_ms = 0;
        return;
    }

    let index = if delta > 0 && state.queue.shuffle && len > 1 {
        let mut next = state.queue.index;
        while next == state.queue.index {
            next = pseudo_random() % len;
        }
        next
    } else {
        let raw = state.queue.index as isize + delta;
        if state.queue.repeat == "all" {
            raw.rem_euclid(len as isize) as usize
        } else if raw < 0 {
            0
        } else if raw as usize >= len {
            // Конец очереди без повтора.
            state.position_ms = 0;
            state.status = "stopped".to_string();
            return;
        } else {
            raw as usize
        }
    };

    state.queue.index = index;
    state.track = Some(track_from_queue_item(&state.queue.items[index]));
    state.position_ms = 0;
}

fn pseudo_random() -> usize {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as usize)
        .unwrap_or(0)
}

fn track_from_queue_item(item: &QueueItem) -> Track {
    Track {
        id: item.id.clone(),
        title: item.title.clone(),
        artists: item.artists.clone(),
        album: None,
        duration_ms: item.duration_ms,
        liked: false,
        cover: item.cover.clone(),
    }
}

/// Разбирает трек из payload команды. Принимает и camelCase, и snake_case.
/// Публичная обёртка для CLI: трек из произвольного JSON-объекта.
pub fn track_from_value(value: &Value) -> Result<Track, String> {
    track_from_payload(Some(value))
}

/// Приводит обложку к полному URL. API отдаёт `coverUri` без схемы и с
/// подстановкой `%%` под нужный размер; UI может прислать готовый URL.
pub(crate) fn cover_url(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let url = if raw.starts_with("https://") || raw.starts_with("http://") {
        raw.to_string()
    } else {
        format!("https://{}", raw.trim_start_matches("//"))
    };
    Some(url.replace("%%", "400x400"))
}

fn track_from_payload(payload: Option<&Value>) -> Result<Track, String> {
    let value = payload.ok_or_else(|| "нужен payload с треком".to_string())?;
    let field = |name: &str| -> Option<&Value> {
        value.get(name).or_else(|| match name {
            "durationMs" => value.get("duration_ms"),
            "duration_ms" => value.get("durationMs"),
            _ => None,
        })
    };

    let id = field("id")
        .and_then(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| v.as_u64().map(|n| n.to_string()))
        })
        .ok_or_else(|| "track: нет id".to_string())?;

    let title = field("title")
        .and_then(Value::as_str)
        .unwrap_or("Без названия")
        .to_string();

    // artists: строки (из UI) или объекты API (`{"name": ...}`).
    let artists = field("artists")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .or_else(|| v.get("name").and_then(Value::as_str).map(str::to_string))
                })
                .collect()
        })
        .unwrap_or_default();

    let duration_ms = field("durationMs").and_then(Value::as_u64).unwrap_or(0);
    let album = field("album")
        .and_then(|v| {
            v.as_str().map(str::to_string).or_else(|| {
                v.get("title").and_then(Value::as_str).map(str::to_string)
            })
        });
    let cover = field("cover")
        .and_then(Value::as_str)
        .and_then(cover_url)
        .or_else(|| {
            field("coverUri")
                .and_then(Value::as_str)
                .and_then(cover_url)
        })
        .or_else(|| {
            value
                .pointer("/albums/0/coverUri")
                .and_then(Value::as_str)
                .and_then(cover_url)
        });

    Ok(Track {
        id,
        title,
        artists,
        album,
        duration_ms,
        liked: false,
        cover,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track_json() -> Value {
        serde_json::json!({
            "id": "123",
            "title": "Кино",
            "artists": ["MACAN"],
            "durationMs": 184000
        })
    }

    #[test]
    fn track_cover_uri_is_normalized() {
        let value = serde_json::json!({
            "id": "1",
            "title": "T",
            "coverUri": "avatars.yandex.net/get-music-content/1/2/%%"
        });
        let track = track_from_value(&value).unwrap();
        assert_eq!(
            track.cover.as_deref(),
            Some("https://avatars.yandex.net/get-music-content/1/2/400x400")
        );
    }

    #[test]
    fn track_cover_falls_back_to_album_uri() {
        let value = serde_json::json!({
            "id": "1",
            "title": "T",
            "albums": [{ "coverUri": "//avatars.yandex.net/album/%%" }]
        });
        let track = track_from_value(&value).unwrap();
        assert_eq!(
            track.cover.as_deref(),
            Some("https://avatars.yandex.net/album/400x400")
        );
    }

    #[test]
    fn track_cover_keeps_ready_url() {
        let value = serde_json::json!({
            "id": "1",
            "title": "T",
            "cover": "https://avatars.yandex.net/ready/400x400"
        });
        let track = track_from_value(&value).unwrap();
        assert_eq!(
            track.cover.as_deref(),
            Some("https://avatars.yandex.net/ready/400x400")
        );
    }

    #[test]
    fn state_serializes_camel_case() {
        let mut state = State::default();
        state.track = Some(Track {
            id: "1".into(),
            title: "T".into(),
            artists: vec!["A".into()],
            album: None,
            duration_ms: 1000,
            liked: false,
            cover: None,
        });
        let json = serde_json::to_string(&state).unwrap();
        assert!(json.contains("\"positionMs\""));
        assert!(json.contains("\"durationMs\""));
        assert!(!json.contains("position_ms"));
    }

    #[test]
    fn play_track_sets_current_and_queue() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        let state = app.snapshot();
        assert_eq!(state.track.as_ref().unwrap().title, "Кино");
        assert_eq!(state.queue.length, 1);
        assert_eq!(state.status, "playing");
    }

    #[test]
    fn enqueue_then_advance_wraps() {
        let app = AppState::new();
        app.command("enqueue", Some(&track_json())).unwrap();
        app.command("enqueue", Some(&track_json())).unwrap();
        app.command("play", None).unwrap();
        assert_eq!(app.snapshot().queue.length, 2);
        app.command("next", None).unwrap();
        assert_eq!(app.snapshot().queue.index, 1);
        app.command("next", None).unwrap();
        assert_eq!(app.snapshot().queue.index, 0);
    }

    #[test]
    fn seek_is_clamped() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        app.command("seek", Some(&serde_json::json!({ "positionMs": 999_999 })))
            .unwrap();
        assert_eq!(app.snapshot().position_ms, 184_000);
    }

    #[test]
    fn play_track_reuses_existing_queue_entry() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        app.command("play_track", Some(&track_json())).unwrap();

        let state = app.snapshot();
        assert_eq!(state.queue.items.len(), 1, "трек не должен дублироваться");
        assert_eq!(state.queue.index, 0);
    }

    #[test]
    fn repeat_one_keeps_track_on_next() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        app.command("enqueue", Some(&track_json())).unwrap();
        app.command("repeat", Some(&serde_json::json!({ "value": "one" })))
            .unwrap();

        let before = app.snapshot();
        app.command("next", None).unwrap();
        let after = app.snapshot();
        assert_eq!(before.queue.index, after.queue.index);
        assert_eq!(after.position_ms, 0);
    }

    #[test]
    fn repeat_off_stops_at_queue_end() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        app.command("repeat", Some(&serde_json::json!({ "value": "off" })))
            .unwrap();

        app.command("next", None).unwrap();
        let state = app.snapshot();
        assert_eq!(state.status, "stopped");
    }

    #[test]
    fn queue_remove_shifts_index() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        app.command("enqueue", Some(&track_json())).unwrap();
        app.command("queue_remove", Some(&serde_json::json!({ "index": 0 })))
            .unwrap();

        let state = app.snapshot();
        assert_eq!(state.queue.items.len(), 1);
        assert_eq!(state.queue.index, 0);
        assert_eq!(state.queue.length, 1);
    }

    #[test]
    fn unknown_op_is_error() {
        let app = AppState::new();
        assert!(app.command("nope", None).is_err());
    }
}
