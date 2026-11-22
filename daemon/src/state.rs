//! Состояние плеера и команды.
//!
//! Контракт `/v1/state` — camelCase (его читает плазмоид KDE). Источник
//! состояния — собственный GStreamer-плеер; внешний MPRIS используется как
//! резервный, пока локальный плеер не взял управление.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::broadcast;

pub const CHANNEL_CAPACITY: usize = 64;

/// Сколько раз подряд перезапускаем поток, прежде чем взять следующий трек.
const MAX_RECOVERIES: u32 = 2;
/// Тиков без движения позиции (1 Гц), после которых поток считается вставшим.
const STALL_TICKS: u32 = 10;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default)]
    pub album: Option<String>,
    /// id альбома — нужен для добавления трека в плейлист и лайков.
    #[serde(default)]
    pub album_id: Option<String>,
    /// id первого исполнителя — для перехода и станции по артисту.
    #[serde(default)]
    pub artist_id: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub liked: bool,
    #[serde(default)]
    pub cover: Option<String>,
    #[serde(default)]
    pub cached: bool,
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
    pub album_id: Option<String>,
    #[serde(default)]
    pub artist_id: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub liked: bool,
    #[serde(default)]
    pub cover: Option<String>,
    #[serde(default)]
    pub cached: bool,
}

impl From<&Track> for QueueItem {
    fn from(track: &Track) -> Self {
        Self {
            id: track.id.clone(),
            title: track.title.clone(),
            artists: track.artists.clone(),
            album_id: track.album_id.clone(),
            artist_id: track.artist_id.clone(),
            duration_ms: track.duration_ms,
            liked: track.liked,
            cover: track.cover.clone(),
            cached: track.cached,
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

/// Переставляет элемент очереди и сохраняет текущий трек выбранным.
fn move_queue_item(state: &mut State, from: usize, to: usize) -> Result<(), String> {
    let len = state.queue.items.len();
    if from >= len || to >= len {
        return Err(format!(
            "queue_move: нет индекса {from}->{to} (в очереди {len})"
        ));
    }
    if from == to {
        return Ok(());
    }
    let item = state.queue.items.remove(from);
    state.queue.items.insert(to, item);
    let index = state.queue.index;
    if index == from {
        state.queue.index = to;
    } else if from < index && to >= index {
        state.queue.index = index - 1;
    } else if from > index && to <= index {
        state.queue.index = index + 1;
    }
    state.queue.sync_length();
    Ok(())
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

/// Прогресс скачивания трека в офлайн-кэш.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Download {
    pub id: String,
    pub title: String,
    /// `downloading` | `done` | `error`.
    pub state: String,
    pub bytes: u64,
    pub total: u64,
    #[serde(default)]
    pub error: Option<String>,
}

/// Состояние сессии «Моей волны».
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaveInfo {
    pub session_id: String,
    pub batch_id: Option<String>,
    pub active: bool,
    /// Станция ротора (`genre:rock`, `mood:calm`, `artist:42`). `None` — «Моя волна».
    #[serde(default)]
    pub station: Option<String>,
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
    /// Битрейт текущего потока в кбит/с.
    #[serde(default)]
    pub bitrate_kbps: Option<u64>,
    /// Активные и завершённые скачивания (для индикатора прогресса).
    #[serde(default)]
    pub downloads: Vec<Download>,
    /// Сколько треков ждёт в очереди на скачивание.
    #[serde(default)]
    pub download_pending: u64,
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
            bitrate_kbps: None,
            downloads: Vec::new(),
            download_pending: 0,
        }
    }
}

/// Часть состояния, которая переживает перезапуск демона.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Persisted {
    #[serde(default)]
    pub queue: Queue,
    #[serde(default)]
    pub track: Option<Track>,
    #[serde(default)]
    pub position_ms: u64,
    #[serde(default)]
    pub volume: f64,
    #[serde(default)]
    pub quality: String,
}

fn state_path() -> std::path::PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| std::path::PathBuf::from("."));
    base.join("ymd").join("state.json")
}

fn load_persisted() -> Option<Persisted> {
    let data = std::fs::read(state_path()).ok()?;
    serde_json::from_slice(&data).ok()
}

fn save_persisted(state: &State) -> Result<(), String> {
    let persisted = Persisted {
        queue: state.queue.clone(),
        track: state.track.clone(),
        position_ms: state.position_ms,
        volume: state.volume,
        quality: state.quality.clone(),
    };
    let path = state_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| format!("создать {}: {err}", parent.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    let data = serde_json::to_vec_pretty(&persisted).map_err(|err| err.to_string())?;
    std::fs::write(&tmp, data).map_err(|err| format!("записать {}: {err}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|err| format!("переименовать {}: {err}", path.display()))
}

/// Результат резолва потока: URL плюс фактические качество, кодек и битрейт.
struct ResolvedStream {
    url: String,
    quality: String,
    codec: String,
    bitrate: Option<u64>,
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
    /// Защита от повторного `advance` по целиком устаревшей позиции:
    /// после смены трека GStreamer ещё тик отдаёт позицию прошлого потока.
    end_guard: Arc<AtomicBool>,
    /// Сколько перезапусков потока уже было на текущем треке.
    recoveries: Arc<AtomicU32>,
    /// Подряд идущие тики без движения позиции.
    stall: Arc<AtomicU32>,
    /// Позиция предыдущего тика — для детектора зависания.
    last_pos: Arc<AtomicU64>,
    /// Позиция, на которую надо вернуться после перезапуска потока.
    pending_seek: Arc<AtomicU64>,
    /// Сколько тиков уже пытались выполнить `pending_seek`.
    seek_attempts: Arc<AtomicU32>,
    /// Защита от параллельных догрузок «Моей волны».
    wave_pending: Arc<AtomicBool>,
    /// Треки, ждущие последовательной загрузки.
    download_queue: Arc<Mutex<VecDeque<Track>>>,
    /// Один воркер скачивания; true, пока он жив.
    download_worker: Arc<AtomicBool>,
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
            end_guard: Arc::new(AtomicBool::new(false)),
            recoveries: Arc::new(AtomicU32::new(0)),
            stall: Arc::new(AtomicU32::new(0)),
            last_pos: Arc::new(AtomicU64::new(0)),
            pending_seek: Arc::new(AtomicU64::new(0)),
            seek_attempts: Arc::new(AtomicU32::new(0)),
            wave_pending: Arc::new(AtomicBool::new(false)),
            download_queue: Arc::new(Mutex::new(VecDeque::new())),
            download_worker: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Демон со звуком: локальный плеер становится основным источником.
    pub fn with_player(player: crate::player::Player) -> Self {
        let mut app = Self::new();
        app.player = Some(Arc::new(player));
        app
    }

    /// Восстанавливает очередь и позицию после перезапуска демона.
    pub fn restore_state(&self) {
        let Some(saved) = load_persisted() else {
            return;
        };
        let Ok(mut st) = self.inner.write() else {
            return;
        };
        st.queue = saved.queue;
        st.queue.sync_length();
        if saved.volume > 0.0 {
            st.volume = saved.volume.clamp(0.0, 1.0);
        }
        if !saved.quality.is_empty() {
            st.quality = saved.quality;
        }
        st.track = saved.track.or_else(|| {
            st.queue
                .items
                .get(st.queue.index)
                .map(track_from_queue_item)
        });
        // Позиция из прошлой сессии могла остаться на самом конце (или за ним):
        // тогда первый `play` ничего не грузит, а пайплайн стоит на длительности.
        let duration = st.track.as_ref().map(|track| track.duration_ms).unwrap_or(0);
        st.position_ms = if duration > 0 && saved.position_ms + 500 >= duration {
            0
        } else {
            saved.position_ms
        };
        st.status = "paused".to_string();
        if let Some(player) = &self.player {
            player.set_volume(st.volume);
        }
        if st.queue.items.is_empty() && st.track.is_none() {
            return;
        }
        st.rev += 1;
        tracing::info!(
            tracks = st.queue.items.len(),
            position = st.position_ms,
            "state restored"
        );
    }

    /// Сохраняет очередь и позицию на диск (best effort).
    pub fn save_state(&self) {
        if let Err(err) = save_persisted(&self.snapshot()) {
            tracing::warn!("save state: {err}");
        }
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
                "next" | "prev" | "advance" => {
                    let delta = if op == "prev" { -1 } else { 1 };
                    // Ручной next/prev игнорирует repeat=one; автопереход («advance»)
                    // его соблюдает — иначе один трек крутится по кругу.
                    let honor_repeat_one = op == "advance";
                    // Индекс мог посчитать `command_async` перед резолвом URL —
                    // тогда берём именно его, иначе состояние и звук разъедутся.
                    let target = payload
                        .and_then(|p| p.get("index"))
                        .and_then(Value::as_u64)
                        .map(|index| index as usize);
                    advance(&mut st, delta, target, honor_repeat_one);
                    tracing::info!(
                        op,
                        index = st.queue.index,
                        len = st.queue.items.len(),
                        repeat = %st.queue.repeat,
                        shuffle = st.queue.shuffle,
                        track = %st.track.as_ref().map(|t| t.id.as_str()).unwrap_or("-"),
                        status = %st.status,
                        "queue step"
                    );
                }
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
                "queue_set" => {
                    let tracks = payload
                        .and_then(|v| v.get("tracks"))
                        .and_then(Value::as_array)
                        .ok_or_else(|| "queue_set: нужен tracks".to_string())?;
                    if tracks.is_empty() {
                        return Err("queue_set: пустой список треков".to_string());
                    }
                    let mut items = Vec::with_capacity(tracks.len());
                    for value in tracks {
                        let mut track = track_from_payload(Some(value))?;
                        // Флаги кэша обновим одним проходом по индексу ниже.
                        track.cached = false;
                        items.push(QueueItem::from(&track));
                    }
                    st.queue.items = items;
                    st.queue.sync_length();
                    let index = payload
                        .and_then(|v| v.get("index"))
                        .and_then(Value::as_u64)
                        .unwrap_or(0) as usize;
                    if index >= st.queue.items.len() {
                        return Err(format!("queue_set: нет индекса {index}"));
                    }
                    st.queue.index = index;
                    refresh_cached(&mut st);
                    if payload
                        .and_then(|v| v.get("play"))
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
                    {
                        st.track = Some(track_from_queue_item(&st.queue.items[index]));
                        st.position_ms = 0;
                        st.status = "playing".to_string();
                    }
                }
                "cache_remove" => {
                    let id = payload
                        .and_then(|v| v.get("id"))
                        .and_then(value_to_id)
                        .ok_or_else(|| "cache_remove: нужен id".to_string())?;
                    crate::cache::remove(&id)?;
                    refresh_cached(&mut st);
                }
                "cache_clear" => {
                    crate::cache::clear()?;
                    refresh_cached(&mut st);
                }
                "cache_limit" => {
                    let limit = payload
                        .and_then(|v| {
                            v.get("limitMb")
                                .or_else(|| v.get("limit_mb"))
                                .and_then(Value::as_u64)
                        })
                        .ok_or_else(|| "cache_limit: нужен limitMb".to_string())?;
                    crate::config::set_cache_limit(limit)?;
                    crate::cache::enforce_limit("")?;
                    refresh_cached(&mut st);
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
                "queue_move" => {
                    let from = payload
                        .and_then(|v| v.get("from"))
                        .and_then(Value::as_u64)
                        .ok_or_else(|| "queue_move: нужен from".to_string())?
                        as usize;
                    let to = payload
                        .and_then(|v| v.get("to"))
                        .and_then(Value::as_u64)
                        .ok_or_else(|| "queue_move: нужен to".to_string())?
                        as usize;
                    move_queue_item(&mut st, from, to)?;
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
            if st.status != "stopped"
                && matches!(
                    op,
                    "play_track"
                        | "queue_play"
                        | "queue_set"
                        | "next"
                        | "prev"
                        | "advance"
                        | "play"
                        | "toggle"
                )
            {
                if let Some(url) = payload.and_then(|v| v.get("url")).and_then(Value::as_str) {
                    if let Some(player) = &self.player {
                        match player.load(url) {
                            Ok(()) => {
                                self.local.store(true, Ordering::Relaxed);
                                self.owned.store(true, Ordering::Relaxed);
                                self.reset_playback_guards();
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
        if matches!(
            op,
            "play_track"
                | "queue_play"
                | "queue_set"
                | "queue_move"
                | "queue_remove"
                | "queue_clear"
                | "volume"
                | "repeat"
                | "shuffle"
                | "next"
                | "prev"
                | "stop"
        ) {
            self.save_state();
        }
        Ok(snapshot.rev)
    }

    /// Как `command`, но для операций, которым нужен URL потока, сначала
    /// резолвит его через API — это сетевой вызов, поэтому async.
    pub async fn command_async(&self, op: &str, payload: Option<&Value>) -> Result<u64, String> {
        match op {
            "wave_start" => return self.wave_start().await,
            "station_start" => {
                let station = payload
                    .and_then(|v| v.get("station"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| "station_start: нужна station".to_string())?;
                return self.station_start(station).await;
            }
            "wave_more" => return self.wave_more().await,
            "wave_feedback" => return self.wave_feedback(payload).await,
            "download_track" => return self.download_track(payload).await,
            "download_tracks" => return self.download_tracks(payload).await,
            "playlist_create" => return self.playlist_create(payload).await,
            "playlist_delete" => return self.playlist_delete(payload).await,
            "playlist_add_tracks" => return self.playlist_add_tracks(payload).await,
            "playlist_remove_track" => return self.playlist_remove_track(payload).await,
            "like_track" => return self.like_track(payload).await,
            _ => {}
        }

        // После рестарта демон восстанавливает очередь в paused без потока.
        // Первый play/toggle должен снова загрузить URL текущего трека.
        if matches!(op, "play" | "toggle")
            && self.player.is_some()
            && !self.is_local()
            && !self.is_external()
        {
            if let Some(track) = self.snapshot().track {
                if self.snapshot().status != "playing" {
                    if let Ok(resolved) = self.resolve_url(&track.id).await {
                        let mut owned = payload
                            .cloned()
                            .unwrap_or_else(|| Value::Object(Default::default()));
                        if let Some(object) = owned.as_object_mut() {
                            object.insert("url".to_string(), Value::String(resolved.url));
                        }
                        if let Ok(mut st) = self.inner.write() {
                            st.quality = resolved.quality;
                            st.codec = Some(resolved.codec);
                            st.bitrate_kbps = resolved.bitrate;
                        }
                        return self.command(op, Some(&owned));
                    }
                }
            }
        }

        let play_requested = payload
            .and_then(|v| v.get("play"))
            .and_then(Value::as_bool)
            .unwrap_or(op != "queue_set");
        let needs_url = play_requested
            && matches!(
                op,
                "play_track" | "queue_play" | "queue_set" | "next" | "prev" | "advance"
            );
        if !needs_url || self.player.is_none() {
            return self.command(op, payload);
        }

        let mut planned_index: Option<usize> = None;
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
            "queue_set" => payload
                .and_then(|v| v.get("tracks"))
                .and_then(Value::as_array)
                .and_then(|tracks| {
                    let index = payload
                        .and_then(|v| v.get("index"))
                        .and_then(Value::as_u64)
                        .unwrap_or(0) as usize;
                    tracks.get(index)
                })
                .and_then(|v| v.get("id"))
                .and_then(value_to_id),
            _ => {
                // Тот же алгоритм, что и в `advance`: иначе при `repeat=one`
                // или `shuffle` резолвился URL чужого трека. Ручной next/prev
                // не учитывает repeat=one, автопереход «advance» — учитывает.
                let state = self.snapshot();
                let delta = if op == "prev" { -1 } else { 1 };
                let honor_repeat_one = op == "advance";
                match plan_step(&state, delta, honor_repeat_one) {
                    Step::Index(index) => {
                        planned_index = Some(index);
                        state.queue.items.get(index).map(|item| item.id.clone())
                    }
                    Step::Stop => {
                        tracing::info!(
                            op,
                            len = state.queue.items.len(),
                            repeat = %state.queue.repeat,
                            "queue step: конец очереди без повтора"
                        );
                        None
                    }
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
                    || st.codec.as_deref() != Some(resolved.codec.as_str())
                    || st.bitrate_kbps != resolved.bitrate;
                if changed {
                    st.quality = resolved.quality.clone();
                    st.codec = Some(resolved.codec.clone());
                    st.bitrate_kbps = resolved.bitrate;
                    st.rev += 1;
                }
            }
        }
        let url = resolved.map(|resolved| resolved.url);

        let mut owned = payload
            .cloned()
            .unwrap_or_else(|| Value::Object(Default::default()));
        // Явный индекс: `command` не должен выбирать трек повторно (особенно
        // при shuffle, где второй выбор был бы другим).
        if let (Some(index), Some(object)) = (planned_index, owned.as_object_mut()) {
            object.insert("index".to_string(), Value::from(index as u64));
        }
        if let (Some(url), Some(object)) = (url, owned.as_object_mut()) {
            object.insert("url".to_string(), Value::String(url));
        }

        self.command(op, Some(&owned))
    }

    /// Создаёт плейлист и возвращает его `kind`.
    async fn playlist_create(&self, payload: Option<&Value>) -> Result<u64, String> {
        let title = payload
            .and_then(|v| v.get("title"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .ok_or_else(|| "playlist_create: нужно title".to_string())?;
        let visibility = payload
            .and_then(|v| v.get("visibility"))
            .and_then(Value::as_str)
            .unwrap_or("private");
        let account = crate::auth::load_account().ok_or_else(|| "нет аккаунта".to_string())?;
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let value = client
            .create_playlist(account.uid, title, visibility)
            .await
            .map_err(|err| err.to_string())?;
        let kind = value
            .get("kind")
            .and_then(Value::as_u64)
            .ok_or_else(|| "playlist_create: API не вернул kind".to_string())?;
        self.bump();
        Ok(kind)
    }

    async fn playlist_delete(&self, payload: Option<&Value>) -> Result<u64, String> {
        let kind = payload
            .and_then(|v| v.get("kind"))
            .and_then(Value::as_u64)
            .ok_or_else(|| "playlist_delete: нужен kind".to_string())?;
        let account = crate::auth::load_account().ok_or_else(|| "нет аккаунта".to_string())?;
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        client
            .delete_playlist(account.uid, kind)
            .await
            .map_err(|err| err.to_string())?;
        self.bump();
        Ok(self.snapshot().rev)
    }

    /// Добавляет треки в конец плейлиста.
    async fn playlist_add_tracks(&self, payload: Option<&Value>) -> Result<u64, String> {
        let kind = payload
            .and_then(|v| v.get("kind"))
            .and_then(Value::as_u64)
            .ok_or_else(|| "playlist_add_tracks: нужен kind".to_string())?;
        let items = payload
            .and_then(|v| v.get("tracks"))
            .and_then(Value::as_array)
            .ok_or_else(|| "playlist_add_tracks: нужны tracks".to_string())?;
        let account = crate::auth::load_account().ok_or_else(|| "нет аккаунта".to_string())?;
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let playlist = client
            .playlist(account.uid, kind)
            .await
            .map_err(|err| err.to_string())?;
        let revision = playlist
            .get("revision")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let at = playlist
            .get("tracks")
            .and_then(Value::as_array)
            .map(Vec::len)
            .unwrap_or(0);
        let tracks: Vec<Value> = items
            .iter()
            .filter_map(|item| {
                let id = item.get("id").and_then(value_to_id)?;
                let album = item
                    .get("albumId")
                    .or_else(|| item.get("album_id"))
                    .and_then(value_to_id);
                let mut track = serde_json::json!({ "id": json_id(&id) });
                if let Some(album) = album {
                    track["albumId"] = json_id(&album);
                }
                Some(track)
            })
            .collect();
        if tracks.is_empty() {
            return Err("playlist_add_tracks: нет треков".to_string());
        }
        let diff = serde_json::json!([{ "op": "insert", "at": at, "tracks": tracks }]);
        client
            .change_playlist(account.uid, kind, revision, &diff.to_string())
            .await
            .map_err(|err| err.to_string())?;
        self.bump();
        Ok(self.snapshot().rev)
    }

    /// Удаляет один трек по индексу в плейлисте.
    async fn playlist_remove_track(&self, payload: Option<&Value>) -> Result<u64, String> {
        let kind = payload
            .and_then(|v| v.get("kind"))
            .and_then(Value::as_u64)
            .ok_or_else(|| "playlist_remove_track: нужен kind".to_string())?;
        let index = payload
            .and_then(|v| v.get("index"))
            .and_then(Value::as_u64)
            .ok_or_else(|| "playlist_remove_track: нужен index".to_string())?;
        let account = crate::auth::load_account().ok_or_else(|| "нет аккаунта".to_string())?;
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let playlist = client
            .playlist(account.uid, kind)
            .await
            .map_err(|err| err.to_string())?;
        let revision = playlist
            .get("revision")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        // В diff Яндекса `to` — исключающая граница: удаление одного
        // элемента с индексом i задаётся как {from:i, to:i+1}.
        let end = index.saturating_add(1);
        let diff = serde_json::json!([{ "op": "delete", "from": index, "to": end }]);
        client
            .change_playlist(account.uid, kind, revision, &diff.to_string())
            .await
            .map_err(|err| err.to_string())?;
        self.bump();
        Ok(self.snapshot().rev)
    }

    async fn like_track(&self, payload: Option<&Value>) -> Result<u64, String> {
        let id = payload
            .and_then(|v| v.get("id"))
            .and_then(value_to_id)
            .ok_or_else(|| "like_track: нужен id".to_string())?;
        let liked = payload
            .and_then(|v| v.get("liked"))
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let account = crate::auth::load_account().ok_or_else(|| "нет аккаунта".to_string())?;
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        client
            .like_track(account.uid, &id, liked)
            .await
            .map_err(|err| err.to_string())?;
        if let Ok(mut st) = self.inner.write() {
            for item in &mut st.queue.items {
                if item.id == id {
                    item.liked = liked;
                }
            }
            if let Some(track) = st.track.as_mut() {
                if track.id == id {
                    track.liked = liked;
                }
            }
            st.rev += 1;
        }
        self.save_state();
        let snapshot = self.snapshot();
        self.publish(&snapshot);
        Ok(snapshot.rev)
    }

    /// Публично обновляет ревизию: например, после входа в аккаунт.
    pub fn refresh(&self) {
        self.bump();
    }

    /// Увеличивает ревизию состояния и рассылает его подписчикам.
    fn bump(&self) {
        if let Ok(mut st) = self.inner.write() {
            st.rev += 1;
            let snapshot = st.clone();
            drop(st);
            self.publish(&snapshot);
        }
    }

    /// Ставит один трек в очередь на скачивание.
    async fn download_track(&self, payload: Option<&Value>) -> Result<u64, String> {
        let source = payload.and_then(|v| v.get("track")).or(payload);
        let track = track_from_payload(source)?;
        self.enqueue_downloads(vec![track]).await
    }

    /// Ставит в очередь все треки плейлиста, пропуская уже известные.
    async fn download_tracks(&self, payload: Option<&Value>) -> Result<u64, String> {
        let items = payload
            .and_then(|v| v.get("tracks"))
            .and_then(Value::as_array)
            .ok_or_else(|| "нет списка треков".to_string())?;
        let mut tracks = Vec::new();
        for item in items {
            if let Ok(track) = track_from_payload(Some(item)) {
                tracks.push(track);
            }
        }
        if tracks.is_empty() {
            return Err("нет треков для скачивания".to_string());
        }
        self.enqueue_downloads(tracks).await
    }

    async fn enqueue_downloads(&self, tracks: Vec<Track>) -> Result<u64, String> {
        let mut added = 0;
        {
            let mut queue = self
                .download_queue
                .lock()
                .map_err(|_| "download queue lock poisoned".to_string())?;
            let mut st = self
                .inner
                .write()
                .map_err(|_| "state lock poisoned".to_string())?;
            let cached: std::collections::HashSet<String> = crate::cache::list()
                .into_iter()
                .map(|entry| entry.id)
                .collect();
            let mut known: std::collections::HashSet<String> =
                queue.iter().map(|track| track.id.clone()).collect();
            known.extend(
                st.downloads
                    .iter()
                    .filter(|item| item.state == "downloading")
                    .map(|item| item.id.clone()),
            );
            for track in tracks {
                if cached.contains(&track.id) || known.contains(&track.id) {
                    continue;
                }
                known.insert(track.id.clone());
                queue.push_back(track);
                added += 1;
            }
            st.download_pending = queue.len() as u64;
            // Обновляем `cached` и при пустом добавлении: пользователь мог
            // нажать «скачать» на уже готовом треке.
            refresh_cached(&mut st);
            st.rev += 1;
            let snapshot = st.clone();
            drop(st);
            drop(queue);
            self.publish(&snapshot);
        }
        if added > 0 {
            self.ensure_download_worker();
        }
        Ok(self.snapshot().rev)
    }

    fn ensure_download_worker(&self) {
        if self
            .download_worker
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }
        let app = self.clone();
        tokio::spawn(async move {
            app.download_worker_loop().await;
        });
    }

    /// Один воркер качает треки строго последовательно.
    async fn download_worker_loop(&self) {
        loop {
            let Some(track) = self.next_download() else {
                self.download_worker.store(false, Ordering::SeqCst);
                // Закрываем гонку: enqueue мог прийти между pop_front и сбросом флага.
                if !self
                    .download_queue
                    .lock()
                    .map(|queue| queue.is_empty())
                    .unwrap_or(true)
                {
                    self.ensure_download_worker();
                }
                return;
            };
            let id = track.id.clone();
            let client = match crate::api::Client::from_store() {
                Ok(client) => client,
                Err(err) => {
                    finish_download(self, &id, Err(err.to_string()));
                    continue;
                }
            };
            let quality = crate::config::quality();
            let progress_app = self.clone();
            let progress_id = id.clone();
            let result = crate::cache::download(&client, &track, quality, move |bytes, total| {
                if let Ok(mut st) = progress_app.inner.write() {
                    if let Some(item) = st.downloads.iter_mut().find(|item| item.id == progress_id)
                    {
                        item.bytes = bytes;
                        item.total = total;
                    }
                }
            })
            .await;

            match result {
                Ok(entry) => finish_download(self, &id, Ok((entry.bytes, entry.bytes))),
                Err(err) => finish_download(self, &id, Err(err)),
            }
        }
    }

    /// Берёт следующий трек и сразу показывает его в `state.downloads`.
    fn next_download(&self) -> Option<Track> {
        let mut queue = self.download_queue.lock().ok()?;
        let track = queue.pop_front()?;
        let pending = queue.len() as u64;
        let snapshot = self.inner.write().ok().map(|mut st| {
            st.download_pending = pending;
            st.downloads.retain(|item| item.id != track.id);
            st.downloads.push(Download {
                id: track.id.clone(),
                title: track.title.clone(),
                state: "downloading".to_string(),
                bytes: 0,
                total: 0,
                error: None,
            });
            if st.downloads.len() > 20 {
                let excess = st.downloads.len() - 20;
                st.downloads.drain(0..excess);
            }
            st.rev += 1;
            st.clone()
        });
        drop(queue);
        if let Some(snapshot) = snapshot {
            self.publish(&snapshot);
        }
        Some(track)
    }

    async fn resolve_url(&self, track_id: &str) -> Result<ResolvedStream, String> {
        // Офлайн-кэш приоритетнее сети: локальный файл играет без токена и сети.
        if let Some(path) = crate::cache::path_for(track_id) {
            tracing::debug!(track = %track_id, file = %path.display(), "play from cache");
            let (quality, codec, bitrate) = crate::cache::entry_for(track_id)
                .map(|entry| (entry.quality, entry.codec, entry.bitrate_kbps))
                .unwrap_or_else(|| ("cache".to_string(), String::new(), None));
            return Ok(ResolvedStream {
                url: format!("file://{}", path.display()),
                quality,
                codec,
                bitrate,
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
            // API отдаёт битрейт в бит/с, в состоянии и UI — кбит/с.
            // Ноль означает «неизвестно», а не 0 kbps.
            bitrate: stream
                .bitrate
                .map(|value| (value + 500) / 1000)
                .filter(|value| *value > 0),
        })
    }

    /// Включена ли «Моя волна».
    pub fn wave_active(&self) -> bool {
        self.snapshot()
            .wave
            .map(|wave| wave.active)
            .unwrap_or(false)
    }

    /// Новая сессия «Моей волны»: очередь заменяется партией радио.
    pub async fn wave_start(&self) -> Result<u64, String> {
        self.start_radio(None).await
    }

    /// Радио по станции: жанр, настроение, артист.
    pub async fn radio_start(&self, station: &str) -> Result<u64, String> {
        self.start_radio(Some(station)).await
    }

    async fn start_radio(&self, station: Option<&str>) -> Result<u64, String> {
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let batch = match station {
            Some(station) => client.station_start(station).await,
            None => client.wave_start().await,
        }
        .map_err(|err| err.to_string())?;

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
            // Волна и радио бесконечны: repeat=one превращал бы их
            // в «зациклило первый трек».
            st.queue.repeat = "all".to_string();
            st.queue.shuffle = false;
            st.wave = Some(WaveInfo {
                session_id: batch.session_id.clone(),
                batch_id: batch.batch_id.clone(),
                active: true,
                station: station.map(str::to_string),
            });
            st.rev += 1;
            let _ = self
                .tx
                .send(serde_json::to_string(&*st).unwrap_or_default());
        }

        // `Box::pin` разрывает рекурсию async-функций (`command_async` ↔ `wave_start`).
        Box::pin(self.command_async("queue_play", Some(&serde_json::json!({ "index": 0 })))).await
    }

    /// Станция по треку или исполнителю (`track:<id>` / `artist:<id>`).
    pub async fn station_start(&self, station: &str) -> Result<u64, String> {
        let client = crate::api::Client::from_store().map_err(|err| err.to_string())?;
        let batch = client
            .station_tracks(station)
            .await
            .map_err(|err| err.to_string())?;

        if batch.session_id.is_empty() || batch.tracks.is_empty() {
            return Err("станция: пустой ответ".to_string());
        }

        let items: Vec<QueueItem> = batch
            .tracks
            .iter()
            .filter_map(|value| track_from_value(value).ok())
            .map(|track| QueueItem::from(&track))
            .collect();

        if items.is_empty() {
            return Err("станция: не удалось разобрать треки".to_string());
        }

        {
            let mut st = self.inner.write().map_err(|err| err.to_string())?;
            st.queue.items = items;
            st.queue.sync_length();
            st.queue.index = 0;
            // Волна и радио бесконечны: repeat=one превращал бы их
            // в «зациклило первый трек».
            st.queue.repeat = "all".to_string();
            st.queue.shuffle = false;
            st.wave = Some(WaveInfo {
                session_id: batch.session_id.clone(),
                batch_id: batch.batch_id.clone(),
                active: true,
                station: Some(station.to_string()),
            });
            st.rev += 1;
            let _ = self
                .tx
                .send(serde_json::to_string(&*st).unwrap_or_default());
        }

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
        let _ = self
            .tx
            .send(serde_json::to_string(&*st).unwrap_or_default());
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
        state
            .queue
            .items
            .len()
            .saturating_sub(state.queue.index + 1)
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
            let duration = st.track.as_ref().map(|track| track.duration_ms).unwrap_or(0);
            let position_ms = if duration > 0 {
                position_ms.min(duration)
            } else {
                position_ms
            };
            // Позиция меняется каждый тик (< 1 с), поэтому сравниваем секунды:
            // ровно одно обновление `rev` в секунду — этого ждут SSE-клиенты
            // (панель Noctalia рисует прогресс по событиям, а не по таймеру).
            let changed = st.status != status || position_ms / 1000 != st.position_ms / 1000;
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

    /// Сбрасывает счётчики восстановления при смене трека: лимит
    /// перезапусков считается на трек, а не на всю сессию.
    fn reset_playback_guards(&self) {
        self.recoveries.store(0, Ordering::SeqCst);
        self.stall.store(0, Ordering::SeqCst);
        self.last_pos.store(0, Ordering::SeqCst);
        self.pending_seek.store(0, Ordering::SeqCst);
        self.seek_attempts.store(0, Ordering::SeqCst);
    }

    /// Отмечает позицию тика и возвращает серию тиков без движения.
    /// Один и тот же вызов питает детектор зависания.
    fn note_position(&self, position_ms: u64) -> u32 {
        let previous = self.last_pos.swap(position_ms, Ordering::SeqCst);
        if position_ms > previous.saturating_add(400) {
            self.stall.store(0, Ordering::SeqCst);
            return 0;
        }
        self.stall.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// Возвращает поток на место обрыва. `seek_simple` до preroll
    /// отклоняется, поэтому попытки повторяются из тикера.
    fn apply_pending_seek(&self, position_ms: u64) {
        let target = self.pending_seek.load(Ordering::SeqCst);
        if target == 0 {
            return;
        }
        if position_ms.saturating_add(3000) >= target {
            self.pending_seek.store(0, Ordering::SeqCst);
            return;
        }
        let attempts = self.seek_attempts.fetch_add(1, Ordering::SeqCst) + 1;
        if attempts > 8 {
            tracing::warn!(
                target_ms = target,
                position_ms,
                "player: не удалось вернуться на место обрыва"
            );
            self.pending_seek.store(0, Ordering::SeqCst);
            return;
        }
        if let Some(player) = &self.player {
            player.try_seek(target);
        }
    }

    /// Перезапускает текущий трек: ошибка источника и застывший поток
    /// лечатся только свежим подписанным URL. Возвращает поток на ту же
    /// позицию, если обрыв случился не в начале и не в конце.
    async fn restart_current(&self, position_ms: u64) -> Result<(), String> {
        let (id, duration_ms) = {
            let state = self.snapshot();
            let track = state
                .track
                .ok_or_else(|| "нет текущего трека".to_string())?;
            (track.id, track.duration_ms)
        };
        let resolved = self.resolve_url(&id).await?;
        let player = self
            .player
            .as_ref()
            .ok_or_else(|| "плеер не создан".to_string())?;
        player.load(&resolved.url).map_err(|err| err.to_string())?;

        let resume = should_resume(position_ms, duration_ms);
        self.pending_seek
            .store(if resume { position_ms } else { 0 }, Ordering::SeqCst);
        self.seek_attempts.store(0, Ordering::SeqCst);
        self.stall.store(0, Ordering::SeqCst);
        self.last_pos.store(position_ms, Ordering::SeqCst);
        self.local.store(true, Ordering::SeqCst);
        self.owned.store(true, Ordering::SeqCst);
        if resume {
            player.try_seek(position_ms);
        }
        if let Ok(mut state) = self.inner.write() {
            state.status = "playing".to_string();
            state.position_ms = position_ms;
            state.quality = resolved.quality;
            state.codec = Some(resolved.codec);
            state.bitrate_kbps = resolved.bitrate;
            state.rev += 1;
        }
        tracing::info!(track = %id, position_ms, resume, "player: поток перезапущен");
        Ok(())
    }

    /// Реакция на ошибку шины или зависание: до `MAX_RECOVERIES` раз
    /// перезапускаем поток, дальше берём следующий трек — иначе тишина
    /// остаётся навсегда и её видно только по замершей позиции.
    async fn recover_after_error(&self, reason: &str, position_ms: u64) {
        // Нечего перезапускать: очередь пуста или трек уже снят — глушим
        // звук, а не крутим пустой «advance» с вечным статусом playing.
        let Some(current) = self.snapshot().track else {
            tracing::warn!(reason, "player: нет текущего трека, останавливаю");
            if let Some(player) = &self.player {
                player.stop();
            }
            self.local.store(false, Ordering::SeqCst);
            if let Ok(mut state) = self.inner.write() {
                state.status = "stopped".to_string();
                state.position_ms = 0;
                state.rev += 1;
            }
            return;
        };
        let attempt = self.recoveries.fetch_add(1, Ordering::SeqCst) + 1;
        let track = current.id;
        if attempt <= MAX_RECOVERIES {
            tracing::warn!(
                track = %track,
                position_ms,
                attempt,
                reason,
                "player: перезапускаю поток"
            );
            if let Err(err) = self.restart_current(position_ms).await {
                tracing::warn!(track = %track, error = %err, "player: перезапуск не удался");
                let _ = self.command_async("advance", None).await;
            }
        } else {
            tracing::warn!(
                track = %track,
                position_ms,
                attempt,
                reason,
                "player: лимит перезапусков, следующий трек"
            );
            let _ = self.command_async("advance", None).await;
        }
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
                advance(&mut st, 1, None, true);
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
                || snapshot.position_ms / 1000 != st.position_ms / 1000
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
                album_id: None,
                artist_id: None,
                duration_ms: snapshot.duration_ms,
                liked: false,
                cover: None,
                cached: false,
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
            let mut tick = 0u64;
            loop {
                ticker.tick().await;
                tick = tick.wrapping_add(1);
                if tick % 5 == 0 {
                    app.save_state();
                }

                // Локальный плеер главнее: он и звук, и позиция.
                // После первого запуска внешний MPRIS не подхватывает эстафету.
                if app.is_local() || app.owns_output() {
                    if !app.is_local() {
                        app.sync_local(0);
                        continue;
                    }
                    // 1. Шина: конец потока или ошибка источника.
                    //    Ошибку нельзя оставлять без реакции: пайплайн уже
                    //    стоит, позиция замирает, а статус остаётся «playing».
                    let event = app
                        .player
                        .as_ref()
                        .map(|player| player.poll_events())
                        .unwrap_or(crate::player::BusEvent::None);
                    match event {
                        crate::player::BusEvent::Eos => {
                            let before = app.snapshot();
                            tracing::info!(
                                track = %before
                                    .track
                                    .as_ref()
                                    .map(|track| track.id.as_str())
                                    .unwrap_or("-"),
                                index = before.queue.index,
                                len = before.queue.items.len(),
                                repeat = %before.queue.repeat,
                                shuffle = before.queue.shuffle,
                                "eos -> next"
                            );
                            if let Err(err) = app.command_async("advance", None).await {
                                tracing::warn!("next after eos: {err}");
                            }
                            continue;
                        }
                        crate::player::BusEvent::Error(reason) => {
                            let position = app
                                .player
                                .as_ref()
                                .map(|player| player.position_ms())
                                .unwrap_or(0);
                            app.recover_after_error(&reason, position).await;
                            continue;
                        }
                        crate::player::BusEvent::None => {}
                    }
                    let position = app
                        .player
                        .as_ref()
                        .map(|player| player.position_ms())
                        .unwrap_or(0);

                    // 2. Возврат на место обрыва: до preroll seek отклоняется,
                    //    поэтому пробуем несколько тиков, а не один раз.
                    app.apply_pending_seek(position);
                    // Страховка: seek по устаревшей длительности уводит поток за
                    // конец, EOS не приходит и позиция замирает — считаем это
                    // концом трека, иначе очередь встаёт навсегда.
                    let overrun = app
                        .snapshot()
                        .track
                        .as_ref()
                        .map(|track| track.duration_ms > 0 && position > track.duration_ms)
                        .unwrap_or(false);
                    if overrun {
                        // Один тик после смены трека плеер ещё отдаёт позицию
                        // прошлого потока — иначе проскочим пол-очереди.
                        if !app.end_guard.swap(true, Ordering::SeqCst) {
                            tracing::warn!(
                                position_ms = position,
                                "player position past duration, advancing"
                            );
                            if let Err(err) = app.command_async("advance", None).await {
                                tracing::warn!("advance after overrun: {err}");
                            }
                        }
                        continue;
                    }
                    app.end_guard.store(false, Ordering::SeqCst);
                    app.sync_local(position);

                    // 3. Поток мог встать без сообщения об ошибке: позиция не
                    //    двигается, а элемент всё ещё «playing». Лечится так же.
                    let streak = app.note_position(position);
                    let stalled = streak >= STALL_TICKS
                        && app
                            .player
                            .as_ref()
                            .map(|player| player.is_playing() && !player.is_buffering())
                            .unwrap_or(false);
                    if stalled {
                        app.stall.store(0, Ordering::SeqCst);
                        app.recover_after_error("позиция не двигается", position)
                            .await;
                        continue;
                    }

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

/// Возвращает поток на место обрыва только если обрыв случился не в самом
/// начале и не в конце: в начале перемотка бессмысленна, в конце — уже поздно.
fn should_resume(position_ms: u64, duration_ms: u64) -> bool {
    position_ms > 2000 && (duration_ms == 0 || position_ms + 2000 < duration_ms)
}

/// Завершает запись о скачивании и обновляет флаги `cached`.
fn finish_download(app: &AppState, id: &str, result: Result<(u64, u64), String>) {
    let Ok(mut st) = app.inner.write() else {
        return;
    };
    refresh_cached(&mut st);
    if let Some(item) = st.downloads.iter_mut().find(|item| item.id == id) {
        match result {
            Ok((bytes, total)) => {
                item.state = "done".to_string();
                item.bytes = bytes;
                item.total = total;
                item.error = None;
            }
            Err(err) => {
                item.state = "error".to_string();
                item.error = Some(err);
            }
        }
    }
    st.rev += 1;
    let snapshot = st.clone();
    drop(st);
    app.publish(&snapshot);
}

/// Обновляет `cached` у текущего трека и очереди по индексу кэша.
fn refresh_cached(state: &mut State) {
    let cached: std::collections::HashSet<String> = crate::cache::list()
        .into_iter()
        .map(|entry| entry.id)
        .collect();
    for item in &mut state.queue.items {
        item.cached = cached.contains(&item.id);
    }
    if let Some(track) = state.track.as_mut() {
        track.cached = cached.contains(&track.id);
    }
}

/// Приводит id из JSON (строка или число) к строке.
fn value_to_id(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(str::to_string)
        .or_else(|| value.as_u64().map(|number| number.to_string()))
}

/// Yandex API ждёт числовые id; строковые оставляем как есть.
fn json_id(id: &str) -> Value {
    id.parse::<u64>()
        .map(|number| Value::Number(number.into()))
        .unwrap_or_else(|_| Value::String(id.to_string()))
}

/// Куда шагнёт воспроизведение: конкретный индекс или конец очереди.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    /// Очередь кончилась и повтор выключен.
    Stop,
    Index(usize),
}

/// Решает, какой трек играть следующим.
///
/// Чистая функция специально одна на двоих: `command_async` по ней решает,
/// какой URL резолвить, а `command` — какой трек показать. Пока логика была
/// продублирована, при `repeat=one` резолвился URL следующего трека, а
/// состояние оставалось на текущем — и один трек играл по кругу.
fn plan_step(state: &State, delta: isize, honor_repeat_one: bool) -> Step {
    let len = state.queue.items.len();
    if len == 0 {
        return Step::Stop;
    }

    // repeat=one: повтор текущего трека. Действует только на автоматический
    // переход (EOS/тикер): ручной next/prev должен идти дальше по очереди,
    // иначе кнопка «следующий» зацикливает один и тот же трек.
    if honor_repeat_one && delta > 0 && state.queue.repeat == "one" {
        return Step::Index(state.queue.index.min(len - 1));
    }

    if delta > 0 && state.queue.shuffle && len > 1 {
        let mut next = state.queue.index;
        while next == state.queue.index {
            next = pseudo_random() % len;
        }
        return Step::Index(next);
    }

    let raw = state.queue.index as isize + delta;
    if state.queue.repeat == "all" {
        Step::Index(raw.rem_euclid(len as isize) as usize)
    } else if raw < 0 {
        Step::Index(0)
    } else if raw as usize >= len {
        Step::Stop
    } else {
        Step::Index(raw as usize)
    }
}

/// Шаг по очереди: +1 — следующий, -1 — предыдущий.
/// `target` — уже выбранный индекс (его посчитал `plan_step` перед резолвом URL).
/// `honor_repeat_one` — учитывать ли `repeat=one` (только для автоперехода).
fn advance(state: &mut State, delta: isize, target: Option<usize>, honor_repeat_one: bool) {
    let len = state.queue.items.len();
    if len == 0 {
        state.position_ms = 0;
        return;
    }

    let step = match target {
        Some(index) if index < len => Step::Index(index),
        _ => plan_step(state, delta, honor_repeat_one),
    };

    match step {
        Step::Stop => {
            state.position_ms = 0;
            state.status = "stopped".to_string();
        }
        Step::Index(index) => {
            state.queue.index = index;
            state.track = Some(track_from_queue_item(&state.queue.items[index]));
            state.position_ms = 0;
        }
    }
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
        album_id: item.album_id.clone(),
        artist_id: item.artist_id.clone(),
        duration_ms: item.duration_ms,
        liked: item.liked,
        cover: item.cover.clone(),
        cached: item.cached,
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
    let album = field("album").and_then(|v| {
        v.as_str()
            .map(str::to_string)
            .or_else(|| v.get("title").and_then(Value::as_str).map(str::to_string))
    });
    let album_id = field("albumId")
        .or_else(|| field("album_id"))
        .or_else(|| value.pointer("/albums/0/id"))
        .and_then(value_to_id);
    let artist_id = field("artistId")
        .or_else(|| field("artist_id"))
        .or_else(|| value.pointer("/artists/0/id"))
        .and_then(value_to_id);
    let liked = field("liked").and_then(Value::as_bool).unwrap_or(false);
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

    let cached = crate::cache::is_cached(&id);
    Ok(Track {
        id,
        title,
        artists,
        album,
        album_id,
        artist_id,
        duration_ms,
        liked,
        cover,
        cached,
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
            album_id: None,
            artist_id: None,
            duration_ms: 1000,
            liked: false,
            cover: None,
            cached: false,
        });
        state.download_pending = 3;
        let json = serde_json::to_string(&state).unwrap();
        assert!(json.contains("\"positionMs\""));
        assert!(json.contains("\"durationMs\""));
        assert!(json.contains("\"downloadPending\":3"));
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
    fn repeat_one_keeps_track_on_auto_advance() {
        let app = AppState::new();
        app.command("play_track", Some(&track_json())).unwrap();
        app.command("enqueue", Some(&track_json())).unwrap();
        app.command("repeat", Some(&serde_json::json!({ "value": "one" })))
            .unwrap();

        let before = app.snapshot();
        app.command("advance", None).unwrap();
        let after = app.snapshot();
        assert_eq!(before.queue.index, after.queue.index);
        assert_eq!(after.position_ms, 0);
    }

    #[test]
    fn plan_step_matches_advance_for_every_repeat_mode() {
        let mut state = State::default();
        state.queue.items = vec![
            QueueItem::from(
                &track_from_value(&serde_json::json!({ "id": "1", "title": "One" })).unwrap(),
            ),
            QueueItem::from(
                &track_from_value(&serde_json::json!({ "id": "2", "title": "Two" })).unwrap(),
            ),
        ];
        state.queue.sync_length();
        state.queue.index = 0;

        state.queue.repeat = "one".into();
        assert_eq!(plan_step(&state, 1, true), Step::Index(0));
        // Ручной next в repeat=one идёт дальше по очереди, а не повторяет трек.
        assert_eq!(plan_step(&state, 1, false), Step::Index(1));
        assert_eq!(plan_step(&state, -1, false), Step::Index(0));
        state.queue.repeat = "all".into();
        assert_eq!(plan_step(&state, 1, true), Step::Index(1));
        state.queue.index = 1;
        assert_eq!(plan_step(&state, 1, true), Step::Index(0));
        state.queue.repeat = "off".into();
        assert_eq!(plan_step(&state, 1, true), Step::Stop);
        assert_eq!(plan_step(&state, -1, true), Step::Index(0));
    }

    #[test]
    fn manual_next_skips_repeat_one_but_eos_repeats() {
        let app = AppState::new();
        app.command(
            "queue_set",
            Some(&serde_json::json!({
                "tracks": [
                    { "id": "1", "title": "One", "durationMs": 1000 },
                    { "id": "2", "title": "Two", "durationMs": 1000 }
                ]
            })),
        )
        .unwrap();
        app.command("repeat", Some(&serde_json::json!({ "value": "one" })))
            .unwrap();

        // Кнопка «следующий»: следующий трек, несмотря на repeat=one.
        app.command("next", None).unwrap();
        assert_eq!(app.snapshot().queue.index, 1);

        // Автопереход после EOS: остаётся на текущем.
        app.command("advance", None).unwrap();
        assert_eq!(app.snapshot().queue.index, 1);
    }

    #[test]
    fn next_with_explicit_index_takes_that_track() {
        let app = AppState::new();
        app.command(
            "queue_set",
            Some(&serde_json::json!({
                "tracks": [
                    { "id": "1", "title": "One" },
                    { "id": "2", "title": "Two" }
                ],
                "index": 0
            })),
        )
        .unwrap();
        app.command("repeat", Some(&serde_json::json!({ "value": "one" })))
            .unwrap();

        // Так `command_async` передаёт индекс, для которого уже скачан URL.
        app.command("next", Some(&serde_json::json!({ "index": 1 })))
            .unwrap();
        let state = app.snapshot();
        assert_eq!(state.queue.index, 1);
        assert_eq!(state.track.unwrap().id, "2");
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
    fn queue_move_keeps_current_track_selected() {
        let app = AppState::new();
        app.command(
            "queue_set",
            Some(&serde_json::json!({
                "tracks": [
                    { "id": "1", "title": "One" },
                    { "id": "2", "title": "Two" },
                    { "id": "3", "title": "Three" }
                ],
                "index": 1
            })),
        )
        .unwrap();

        app.command(
            "queue_move",
            Some(&serde_json::json!({ "from": 1, "to": 2 })),
        )
        .unwrap();
        let state = app.snapshot();
        assert_eq!(state.queue.items[2].id, "2");
        assert_eq!(state.queue.index, 2);
        assert_eq!(state.queue.length, 3);
    }

    #[test]
    fn track_reads_album_and_liked() {
        let value = serde_json::json!({
            "id": "7",
            "title": "T",
            "albumId": 42,
            "liked": true
        });
        let track = track_from_value(&value).unwrap();
        assert_eq!(track.album_id.as_deref(), Some("42"));
        assert!(track.liked);
    }

    #[test]
    fn stall_streak_resets_when_position_moves() {
        let app = AppState::new();
        // Первый тик после сброса — это ещё не зависание.
        assert_eq!(app.note_position(1000), 0);
        assert_eq!(app.note_position(1000), 1);
        assert_eq!(app.note_position(2600), 0);
        assert_eq!(app.note_position(2600), 1);
    }

    #[test]
    fn reset_playback_guards_clears_counters() {
        let app = AppState::new();
        app.recoveries.store(MAX_RECOVERIES, Ordering::SeqCst);
        app.stall.store(7, Ordering::SeqCst);
        app.pending_seek.store(9000, Ordering::SeqCst);
        app.reset_playback_guards();
        assert_eq!(app.recoveries.load(Ordering::SeqCst), 0);
        assert_eq!(app.stall.load(Ordering::SeqCst), 0);
        assert_eq!(app.pending_seek.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn pending_seek_clears_when_position_reaches_target() {
        let app = AppState::new();
        app.pending_seek.store(5000, Ordering::SeqCst);
        app.apply_pending_seek(3000);
        assert_eq!(app.pending_seek.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn resume_only_mid_track() {
        assert!(!should_resume(0, 184_440));
        assert!(!should_resume(1_500, 184_440));
        assert!(should_resume(30_000, 184_440));
        // Длительность неизвестна — доверяем позиции.
        assert!(should_resume(30_000, 0));
        // Уже почти конец: перезапуск с перемоткой только продлит тишину.
        assert!(!should_resume(183_000, 184_440));
    }

    #[test]
    fn unknown_op_is_error() {
        let app = AppState::new();
        assert!(app.command("nope", None).is_err());
    }
}
