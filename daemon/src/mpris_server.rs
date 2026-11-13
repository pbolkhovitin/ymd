//! Исходящий MPRIS-сервер: демон представляется системе как медиаплеер.
//!
//! Благодаря этому работают медиа-клавиши, системный виджет `media` в KDE,
//! блокировка экрана и `playerctl` — без внешнего клиента.

use std::collections::HashMap;

use serde_json::Value;
use zbus::zvariant::{ObjectPath, OwnedValue, Value as ZValue};
use zbus::{interface, Connection};

use crate::state::AppState;

const ROOT_PATH: &str = "/org/mpris/MediaPlayer2";
const BUS_NAME: &str = "org.mpris.MediaPlayer2.ymd";

/// Корневой интерфейс `org.mpris.MediaPlayer2`.
pub struct MprisRoot {
    #[allow(dead_code)]
    app: AppState,
}

/// Интерфейс `org.mpris.MediaPlayer2.Player`.
pub struct MprisPlayer {
    app: AppState,
}

impl MprisRoot {
    pub fn new(app: AppState) -> Self {
        Self { app }
    }
}

impl MprisPlayer {
    pub fn new(app: AppState) -> Self {
        Self { app }
    }

    fn status(&self) -> String {
        let state = self.app.snapshot();
        match state.status.as_str() {
            "playing" => "Playing",
            "paused" => "Paused",
            _ => "Stopped",
        }
        .to_string()
    }

    fn position_us(&self) -> i64 {
        (self.app.snapshot().position_ms as i64) * 1000
    }
}

#[interface(name = "org.mpris.MediaPlayer2")]
impl MprisRoot {
    #[zbus(property)]
    fn identity(&self) -> String {
        "ymd".to_string()
    }

    #[zbus(property)]
    fn desktop_entry(&self) -> String {
        "ymd".to_string()
    }

    #[zbus(property)]
    fn can_quit(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn can_raise(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn has_track_list(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn supported_uri_schemes(&self) -> Vec<String> {
        vec!["https".to_string()]
    }

    #[zbus(property)]
    fn supported_mime_types(&self) -> Vec<String> {
        vec!["audio/mpeg".to_string(), "audio/mp4".to_string(), "audio/flac".to_string()]
    }

    fn raise(&self) {}

    fn quit(&self) {}
}

#[interface(name = "org.mpris.MediaPlayer2.Player")]
impl MprisPlayer {
    #[zbus(property)]
    fn playback_status(&self) -> String {
        self.status()
    }

    #[zbus(property)]
    fn loop_status(&self) -> String {
        "None".to_string()
    }

    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }

    #[zbus(property)]
    fn shuffle(&self) -> bool {
        self.app.snapshot().queue.shuffle
    }

    #[zbus(property)]
    fn metadata(&self) -> HashMap<String, OwnedValue> {
        let state = self.app.snapshot();
        let mut map: HashMap<String, OwnedValue> = HashMap::new();

        let Some(track) = state.track else {
            return map;
        };

        let path = format!("/org/ymd/track/{}", sanitize(&track.id));
        if let Ok(object_path) = ObjectPath::try_from(path) {
            if let Ok(value) = OwnedValue::try_from(ZValue::from(object_path)) {
                map.insert("mpris:trackid".to_string(), value);
            }
        }
        if let Ok(value) = OwnedValue::try_from(ZValue::from(track.duration_ms as i64 * 1000)) {
            map.insert("mpris:length".to_string(), value);
        }
        if let Ok(value) = OwnedValue::try_from(ZValue::from(track.title.clone())) {
            map.insert("xesam:title".to_string(), value);
        }
        if let Ok(value) = OwnedValue::try_from(ZValue::from(track.artists.clone())) {
            map.insert("xesam:artist".to_string(), value);
        }
        if let Some(album) = track.album {
            if let Ok(value) = OwnedValue::try_from(ZValue::from(album)) {
                map.insert("xesam:album".to_string(), value);
            }
        }
        map
    }

    #[zbus(property)]
    fn volume(&self) -> f64 {
        self.app.snapshot().volume
    }

    #[zbus(property)]
    fn set_volume(&self, volume: f64) {
        let payload = serde_json::json!({ "value": volume.clamp(0.0, 1.0) });
        let _ = self.app.command("volume", Some(&payload));
    }

    #[zbus(property)]
    fn position(&self) -> i64 {
        self.position_us()
    }

    #[zbus(property)]
    fn minimum_rate(&self) -> f64 {
        1.0
    }

    #[zbus(property)]
    fn maximum_rate(&self) -> f64 {
        1.0
    }

    #[zbus(property)]
    fn can_go_next(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_go_previous(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_play(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_pause(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_seek(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_control(&self) -> bool {
        true
    }

    async fn next(&self) {
        if let Err(err) = self.app.command_async("next", None).await {
            tracing::warn!("mpris next: {err}");
        }
    }

    async fn previous(&self) {
        if let Err(err) = self.app.command_async("prev", None).await {
            tracing::warn!("mpris prev: {err}");
        }
    }

    fn pause(&self) {
        let _ = self.app.command("pause", None);
    }

    fn play_pause(&self) {
        let _ = self.app.command("toggle", None);
    }

    fn stop(&self) {
        let _ = self.app.command("stop", None);
    }

    fn play(&self) {
        let _ = self.app.command("play", None);
    }

    fn seek(&self, offset: i64) {
        let state = self.app.snapshot();
        let target = (state.position_ms as i64 + offset / 1000).max(0) as u64;
        let payload = serde_json::json!({ "positionMs": target });
        let _ = self.app.command("seek", Some(&payload));
    }

    fn set_position(&self, _track_id: ObjectPath<'_>, position: i64) {
        let payload = serde_json::json!({ "positionMs": (position / 1000).max(0) as u64 });
        let _ = self.app.command("seek", Some(&payload));
    }

    fn open_uri(&self, uri: String) {
        tracing::info!("mpris open_uri: {uri}");
    }
}

fn sanitize(id: &str) -> String {
    let cleaned: String = id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    if cleaned.is_empty() {
        "unknown".to_string()
    } else {
        cleaned
    }
}

/// Публикует MPRIS-интерфейсы в сессионной шине.
pub async fn serve(app: AppState) -> zbus::Result<Connection> {
    let connection = Connection::session().await?;

    connection
        .object_server()
        .at(ROOT_PATH, MprisRoot::new(app.clone()))
        .await?;
    connection
        .object_server()
        .at(ROOT_PATH, MprisPlayer::new(app))
        .await?;

    let reply = connection.request_name(BUS_NAME).await?;
    tracing::info!("mpris: {BUS_NAME} on {ROOT_PATH} (reply: {reply:?})");
    Ok(connection)
}

/// Отладочный дамп: сколько полей метаданных отдаём.
#[allow(dead_code)]
pub fn metadata_len(state: &Value) -> usize {
    state
        .get("track")
        .and_then(|track| track.as_object())
        .map(|object| object.len())
        .unwrap_or(0)
}
