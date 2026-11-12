//! MPRIS-мост: управление внешним плеером через `playerctl`.
//!
//! Пока прямой поток Яндекса недоступен (см. `notes/m1-findings.md`), демон
//! работает как пульт: читает состояние любого MPRIS-плеера и транслирует
//! команды. Контракт `/v1/state` при этом не меняется — позже демон станет
//! источником MPRIS сам.

use std::process::Command;

pub const PREFERRED: &[&str] = &[
    "yandexmusic",
    "YandexMusic",
    "chromium",
    "firefox",
    "mpv",
    "spotify",
];

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub player: String,
    pub status: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub duration_ms: u64,
    pub position_ms: u64,
    #[allow(dead_code)] // понадобится панели для обложки
    pub art_url: Option<String>,
}

fn run(player: &str, args: &[&str]) -> Option<String> {
    let output = Command::new("playerctl")
        .arg("--player")
        .arg(player)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Первый доступный плеер: сначала из списка предпочтений, иначе любой.
pub fn detect() -> Option<String> {
    let list = Command::new("playerctl")
        .arg("--list-all")
        .output()
        .ok()?;
    if !list.status.success() {
        return None;
    }
    let players: Vec<String> = String::from_utf8_lossy(&list.stdout)
        .lines()
        .map(|line| line.split_whitespace().next().unwrap_or("").to_string())
        // Свой собственный MPRIS-сервер не должен быть источником состояния.
        .filter(|name| !name.is_empty() && !name.eq_ignore_ascii_case("ymd"))
        .collect();

    for preferred in PREFERRED {
        if let Some(found) = players
            .iter()
            .find(|p| p.eq_ignore_ascii_case(preferred))
        {
            return Some(found.clone());
        }
    }
    players.into_iter().next()
}

pub fn poll() -> Option<Snapshot> {
    let player = detect()?;

    let status = run(&player, &["status"])?.to_lowercase();
    let meta = run(
        &player,
        &[
            "metadata",
            "--format",
            "{{title}}\u{1f}{{artist}}\u{1f}{{album}}\u{1f}{{mpris:length}}\u{1f}{{mpris:artUrl}}",
        ],
    )?;

    let mut parts = meta.split('\u{1f}');
    let title = parts.next().unwrap_or("").to_string();
    let artists = parts
        .next()
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let album = parts.next().filter(|s| !s.is_empty()).map(str::to_string);
    let duration_ms = parts
        .next()
        .and_then(|v| v.parse::<u64>().ok())
        .map(|us| us / 1000)
        .unwrap_or(0);
    let art_url = parts.next().filter(|s| !s.is_empty()).map(str::to_string);

    let position_ms = run(&player, &["position"])
        .and_then(|v| v.parse::<f64>().ok())
        .map(|secs| (secs * 1000.0) as u64)
        .unwrap_or(0);

    Some(Snapshot {
        player,
        status,
        title,
        artists,
        album,
        duration_ms,
        position_ms,
        art_url,
    })
}

/// Транслирует команду демона во внешний плеер.
pub fn send(op: &str) -> bool {
    let Some(player) = detect() else {
        return false;
    };
    let command = match op {
        "toggle" => "play-pause",
        "play" => "play",
        "pause" => "pause",
        "next" => "next",
        "prev" => "previous",
        _ => return false,
    };
    Command::new("playerctl")
        .arg("--player")
        .arg(player)
        .arg(command)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
