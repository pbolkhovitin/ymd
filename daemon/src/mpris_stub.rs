//! Заглушка MPRIS-моста для платформ без D-Bus и `playerctl` (macOS).
//!
//! Интерфейс совпадает с `mpris.rs`, но внешних плееров нет: источник
//! состояния — собственный GStreamer-плеер, а управление идёт через
//! локальный HTTP API (`ymd-qt`, `ymd ctl`, curl).

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub player: String,
    pub status: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub duration_ms: u64,
    pub position_ms: u64,
    pub art_url: Option<String>,
}

/// Внешних MPRIS-плееров на этой платформе нет.
pub fn poll() -> Option<Snapshot> {
    None
}

/// Управлять внешним плеером нечем.
pub fn send(_op: &str) -> bool {
    false
}
