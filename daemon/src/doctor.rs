//! `ymd doctor` — что в системе есть, а чего нет. Без секретов.

use crate::session;

pub fn run() {
    println!("ymd doctor");
    println!("{}", "-".repeat(60));

    let key_present = session::read_key().ok().flatten().is_some();
    row(
        "session key",
        key_present,
        &session::key_path().display().to_string(),
    );

    #[cfg(target_os = "linux")]
    {
        let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
        let kde = desktop.to_ascii_lowercase().contains("kde");
        let desktop_detail = if desktop.is_empty() {
            "XDG_CURRENT_DESKTOP не задан"
        } else {
            desktop.as_str()
        };
        row("KDE Plasma", kde, desktop_detail);
        row("plasmashell", on_path("plasmashell"), "панель Plasma");
        row("playerctl", on_path("playerctl"), "apt install playerctl");
    }

    #[cfg(target_os = "macos")]
    {
        row("macOS", true, &std::env::consts::ARCH.to_string());
        row("security", on_path("security"), "связка ключей (есть в системе)");
    }

    row(
        "gst-launch-1.0",
        on_path("gst-launch-1.0"),
        if cfg!(target_os = "macos") {
            "brew install gstreamer gst-plugins-base gst-plugins-good"
        } else {
            "apt install gstreamer1.0-tools"
        },
    );
    row("mpv", on_path("mpv"), "опционально");
    #[cfg(target_os = "linux")]
    row(
        "secret-tool",
        on_path("secret-tool"),
        "apt install libsecret-tools",
    );
    row("curl", on_path("curl"), "проверки HTTP API");

    let log = crate::logging::path();
    let size = std::fs::metadata(&log).map(|meta| meta.len()).unwrap_or(0);
    let human = if size < 1024 {
        format!("{size} Б")
    } else {
        format!("{} КиБ", size / 1024)
    };
    row("log", log.exists(), &format!("{} ({human})", log.display()));

    // Плагин Noctalia — симлинк из репозитория. После переименования каталога
    // ссылка остаётся, но ведёт в никуда: виджет продолжает жить в памяти и
    // показывает устаревшее состояние, пока плагин не переустановят.
    #[cfg(target_os = "linux")]
    if let Some(link) = dirs::data_dir().map(|dir| dir.join("noctalia/plugins/yandex-music")) {
        let detail = match std::fs::symlink_metadata(&link) {
            Err(_) => "не подключён (bash scripts/install-noctalia.sh)".to_string(),
            Ok(_) => match std::fs::canonicalize(&link) {
                Ok(path) => format!("-> {}", path.display()),
                Err(_) => "симлинк висит — переустановите (install-noctalia.sh)".to_string(),
            },
        };
        row(
            "noctalia plugin",
            std::fs::canonicalize(&link).is_ok(),
            &detail,
        );
    }

    let port = 8765;
    let listening = std::net::TcpStream::connect(("127.0.0.1", port)).is_ok();
    row(
        "daemon :8765",
        listening,
        if listening {
            "отвечает"
        } else {
            "не запущен — нужен «ymd serve»"
        },
    );

    println!("{}", "-".repeat(60));
    println!("warn — не ошибка: без части пакетов доступны не все возможности.");
}

fn row(name: &str, ok: bool, detail: &str) {
    println!(
        "{:<18} {:<5} {}",
        name,
        if ok { "ok" } else { "warn" },
        detail
    );
}

fn on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join(name))
                .any(|candidate| candidate.is_file())
        })
        .unwrap_or(false)
}
