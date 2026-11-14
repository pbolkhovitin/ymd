//! GStreamer-бэкенд воспроизведения: `playbin3` → pipewire через autoaudiosink.
//!
//! Состояние трека (название, очередь) живёт в `state.rs`; здесь — только звук
//! и позиция. Все методы дешёвые и неблокирующие (GStreamer работает в своих
//! потоках).
//!
//! На каждый трек создаётся **новый** `playbin3`: при смене `uri` в том же
//! пайплайне playbin3 переносит позицию прошлого потока, из-за чего трек
//! стартовал с середины, а EOS не приходил.

use std::sync::Mutex;

use gstreamer as gst;
use gstreamer::prelude::*;

#[derive(Debug, thiserror::Error)]
pub enum PlayerError {
    #[error("gstreamer init: {0}")]
    Init(#[from] gst::glib::Error),

    #[error("не найден элемент playbin3/playbin")]
    NoElement,

    #[error("смена состояния: {0}")]
    State(#[from] gst::StateChangeError),
}

pub struct Player {
    playbin: Mutex<gst::Element>,
    /// Громкость переживает смену пайплайна.
    volume: Mutex<f64>,
    /// Флаг EOS, выставленный из последнего опроса шины.
    eos: Mutex<bool>,
}

#[cfg(target_os = "macos")]
fn configure_macos_tls(source: &gst::Element, ca_file: &str) {
    // У souphttpsrc собственная база доверия: путь Homebrew на другом Mac
    // отсутствует. Проверка сертификатов остаётся включённой.
    if source.find_property("tls-database").is_some() {
        match gio::TlsFileDatabase::new(ca_file) {
            Ok(database) => source.set_property("tls-database", database),
            Err(error) => tracing::warn!("не удалось прочитать сертификаты из .app: {error}"),
        }
    }
}

impl Player {
    fn element() -> Result<gst::Element, PlayerError> {
        gst::ElementFactory::make("playbin3")
            .build()
            .or_else(|_| gst::ElementFactory::make("playbin").build())
            .map_err(|_| PlayerError::NoElement)
    }

    pub fn new() -> Result<Self, PlayerError> {
        gst::init()?;

    let playbin = Self::element()?;
      
    #[cfg(target_os = "macos")]
      if let Ok(ca_file) = std::env::var("YMD_CA_BUNDLE") {
          playbin.connect("source-setup", false, move |values| {
              if let Ok(source) = values[1].get::<gst::Element>() {
                  configure_macos_tls(&source, &ca_file);
              }
              None
          });
      }
        playbin.set_property("volume", 1.0f64);

        Ok(Self {
            playbin: Mutex::new(playbin),
            volume: Mutex::new(1.0),
            eos: Mutex::new(false),
        })
    }

    /// Загружает URL и сразу начинает воспроизведение в свежем пайплайне.
    pub fn load(&self, url: &str) -> Result<(), PlayerError> {
        // Сначала гасим прошлый пайплайн и дожидаемся NULL: два playbin3
        // одновременно дерутся за один PipeWire-узел, и новый поток падает
        // с «Can't typefind stream».
        if let Ok(guard) = self.playbin.lock() {
            let _ = guard.set_state(gst::State::Null);
            let _ = guard.state(gst::ClockTime::from_mseconds(1000));
        }

        let fresh = Self::element()?;
        let volume = self.volume.lock().map(|value| *value).unwrap_or(1.0);
        fresh.set_property("volume", volume);
        fresh.set_property("uri", url);
        fresh.set_state(gst::State::Playing)?;

        self.set_eos(false);
        if let Ok(mut guard) = self.playbin.lock() {
            *guard = fresh;
        }

        tracing::info!("player: load {url}");
        Ok(())
    }

    pub fn play(&self) -> Result<(), PlayerError> {
        if let Ok(playbin) = self.playbin.lock() {
            playbin.set_state(gst::State::Playing)?;
        }
        Ok(())
    }

    pub fn pause(&self) -> Result<(), PlayerError> {
        if let Ok(playbin) = self.playbin.lock() {
            playbin.set_state(gst::State::Paused)?;
        }
        Ok(())
    }

    pub fn toggle(&self) -> Result<(), PlayerError> {
        if self.is_playing() {
            self.pause()
        } else {
            self.play()
        }
    }

    #[allow(dead_code)]
    pub fn stop(&self) {
        if let Ok(playbin) = self.playbin.lock() {
            let _ = playbin.set_state(gst::State::Null);
        }
    }

    pub fn seek_ms(&self, position_ms: u64) {
        if let Ok(playbin) = self.playbin.lock() {
            let _ = playbin.seek_simple(
                gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE,
                gst::ClockTime::from_mseconds(position_ms),
            );
        }
    }

    pub fn position_ms(&self) -> u64 {
        self.playbin
            .lock()
            .ok()
            .and_then(|playbin| playbin.query_position::<gst::ClockTime>())
            .map(|time| time.mseconds())
            .unwrap_or(0)
    }

    #[allow(dead_code)]
    pub fn duration_ms(&self) -> u64 {
        self.playbin
            .lock()
            .ok()
            .and_then(|playbin| playbin.query_duration::<gst::ClockTime>())
            .map(|time| time.mseconds())
            .unwrap_or(0)
    }

    pub fn set_volume(&self, volume: f64) {
        let volume = volume.clamp(0.0, 1.0);
        if let Ok(mut guard) = self.volume.lock() {
            *guard = volume;
        }
        if let Ok(playbin) = self.playbin.lock() {
            playbin.set_property("volume", volume);
        }
    }

    #[allow(dead_code)]
    pub fn volume(&self) -> f64 {
        self.volume.lock().map(|value| *value).unwrap_or(1.0)
    }

    pub fn is_playing(&self) -> bool {
        self.playbin
            .lock()
            .map(|playbin| playbin.current_state() == gst::State::Playing)
            .unwrap_or(false)
    }

    /// Пайплайн ещё переходит в Playing (буферизация, открытие потока).
    /// В этот момент `is_playing()` уже false, но пауза ещё не наступила.
    pub fn is_buffering(&self) -> bool {
        self.playbin
            .lock()
            .map(|playbin| {
                let (result, _current, _pending) = playbin.state(gst::ClockTime::ZERO);
                matches!(result, Ok(gst::StateChangeSuccess::Async))
            })
            .unwrap_or(false)
    }

    /// Состояние пайплайна для диагностики зависаний: результат перехода,
    /// текущее и целевое состояние, позиция.
    #[allow(dead_code)]
    pub fn debug_state(&self) -> String {
        let Ok(playbin) = self.playbin.lock() else {
            return "locked".to_string();
        };
        let (result, current, pending) = playbin.state(gst::ClockTime::ZERO);
        let position = playbin
            .query_position::<gst::ClockTime>()
            .map(|time| time.mseconds())
            .unwrap_or(0);
        format!("result={result:?} current={current:?} pending={pending:?} position={position}")
    }

    /// Забирает сообщения шины и сообщает, дошло ли до конца потока.
    pub fn poll_eos(&self) -> bool {
        let Ok(playbin) = self.playbin.lock() else {
            return false;
        };
        let Some(bus) = playbin.bus() else {
            return false;
        };

        while let Some(message) = bus.timed_pop(gst::ClockTime::ZERO) {
            match message.view() {
                gst::MessageView::Eos(..) => {
                    tracing::debug!("player: eos");
                    self.set_eos(true);
                }
                gst::MessageView::Error(err) => {
                    tracing::warn!(
                        "player error: {} ({})",
                        err.error(),
                        err.debug().unwrap_or_default()
                    );
                }
                _ => {}
            }
        }

        self.take_eos()
    }

    fn set_eos(&self, value: bool) {
        if let Ok(mut guard) = self.eos.lock() {
            *guard = value;
        }
    }

    fn take_eos(&self) -> bool {
        match self.eos.lock() {
            Ok(mut guard) => std::mem::replace(&mut *guard, false),
            Err(_) => false,
        }
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        if let Ok(playbin) = self.playbin.lock() {
            let _ = playbin.set_state(gst::State::Null);
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn bundled_tls_uses_explicit_ca_without_disabling_verification() {
        gst::init().unwrap();
        let source = gst::ElementFactory::make("souphttpsrc").build().unwrap();
        let ca_file = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/macos-ca.pem");
        configure_macos_tls(&source, ca_file);
        let database = source.property::<gio::TlsDatabase>("tls-database");
        assert_eq!(database.property::<String>("anchors"), ca_file);
        assert!(source.property::<bool>("ssl-strict"));
        // Локальный файл также вызывает source-setup, но TLS-свойств не имеет.
        let file = gst::ElementFactory::make("filesrc").build().unwrap();
        configure_macos_tls(&file, ca_file);
    }
}
