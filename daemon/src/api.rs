//! HTTP-клиент внутреннего API Яндекс Музыки.
//!
//! Контракт непубличный, поэтому ответы разбираются толерантно:
//! * часть эндпоинтов заворачивает данные в `result`, часть — нет;
//! * неизвестные поля игнорируются.
//!
//! Схема ответа `/search` зависит от авторизации: без токена — плоский объект,
//! с токеном — `{"result": {…}}`.

use std::time::Duration;

use serde_json::{json, Value};

pub const BASE_URL: &str = "https://api.music.yandex.ru";
pub const CLIENT_HEADER: &str = "YandexMusicDesktopApp";

const TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("HTTP: {0}")]
    Http(#[from] reqwest::Error),
    #[error("API ответил {status}: {body}")]
    Status { status: u16, body: String },
    #[error("нет токена: ymd auth import --from-official")]
    NoToken,
    #[error("нет потока для трека {0}")]
    NoStream(String),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
}

pub struct Client {
    http: reqwest::Client,
    token: String,
}

impl Client {
    #[allow(dead_code)] // album/artist/playlists/likes — для M2
    pub fn new(token: String) -> Result<Self, ApiError> {
        let http = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .user_agent(concat!("ymd/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self { http, token })
    }

    /// Клиент с токеном из keyring/файла.
    pub fn from_store() -> Result<Self, ApiError> {
        let token = crate::auth::load_token().ok_or(ApiError::NoToken)?;
        Self::new(token)
    }

    async fn get(&self, path: &str, query: &[(&str, String)]) -> Result<Value, ApiError> {
        self.get_with_client(path, query, CLIENT_HEADER).await
    }

    async fn get_with_client(
        &self,
        path: &str,
        query: &[(&str, String)],
        client: &str,
    ) -> Result<Value, ApiError> {
        let response = self
            .http
            .get(format!("{BASE_URL}{path}"))
            .query(query)
            .header("authorization", format!("OAuth {}", self.token))
            .header("x-yandex-music-client", client)
            .header("accept-language", "ru")
            .send()
            .await?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(ApiError::Status {
                status: status.as_u16(),
                body: body.chars().take(200).collect(),
            });
        }

        Ok(response.json().await?)
    }

    /// POST с JSON-телом. Используется ротором («Моя волна»).
    async fn post_json(&self, path: &str, body: &Value) -> Result<Value, ApiError> {
        let response = self
            .http
            .post(format!("{BASE_URL}{path}"))
            .header("authorization", format!("OAuth {}", self.token))
            .header("x-yandex-music-client", crate::media::DESKTOP_CLIENT)
            .header("accept-language", "ru")
            .json(body)
            .send()
            .await?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(ApiError::Status {
                status: status.as_u16(),
                body: body.chars().take(200).collect(),
            });
        }

        Ok(response.json().await?)
    }

    /// POST с form-urlencoded телом. Так работают плейлисты и лайки.
    async fn post_form(&self, path: &str, form: &[(&str, String)]) -> Result<Value, ApiError> {
        let response = self
            .http
            .post(format!("{BASE_URL}{path}"))
            .header("authorization", format!("OAuth {}", self.token))
            .header("x-yandex-music-client", CLIENT_HEADER)
            .header("accept-language", "ru")
            .form(form)
            .send()
            .await?;

        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(ApiError::Status {
                status: status.as_u16(),
                body: body.chars().take(200).collect(),
            });
        }
        Ok(serde_json::from_str(&body).unwrap_or(Value::Null))
    }

    /// Создание плейлиста. `visibility`: `public` или `private`.
    pub async fn create_playlist(
        &self,
        uid: u64,
        title: &str,
        visibility: &str,
    ) -> Result<Value, ApiError> {
        let value = self
            .post_form(
                &format!("/users/{uid}/playlists/create"),
                &[
                    ("title", title.to_string()),
                    ("visibility", visibility.to_string()),
                ],
            )
            .await?;
        Ok(unwrap_result(value))
    }

    /// Удаление плейлиста.
    pub async fn delete_playlist(&self, uid: u64, kind: u64) -> Result<Value, ApiError> {
        self.post_form(&format!("/users/{uid}/playlists/{kind}/delete"), &[])
            .await
    }

    /// Изменение плейлиста через diff-операции.
    pub async fn change_playlist(
        &self,
        uid: u64,
        kind: u64,
        revision: u64,
        diff: &str,
    ) -> Result<Value, ApiError> {
        let value = self
            .post_form(
                &format!("/users/{uid}/playlists/{kind}/change"),
                &[
                    ("kind", kind.to_string()),
                    ("revision", revision.to_string()),
                    ("diff", diff.to_string()),
                ],
            )
            .await?;
        Ok(unwrap_result(value))
    }

    /// Поставить или снять лайк трека.
    pub async fn like_track(&self, uid: u64, track_id: &str, liked: bool) -> Result<(), ApiError> {
        let action = if liked { "add-multiple" } else { "remove" };
        self.post_form(
            &format!("/users/{uid}/likes/tracks/{action}"),
            &[("track-ids", track_id.to_string())],
        )
        .await?;
        Ok(())
    }

    /// Блоки главной страницы.
    pub async fn landing(&self) -> Result<Value, ApiError> {
        // `blocks` обязателен: без него API отвечает ошибкой валидации.
        const BLOCKS: &str =
            "personal-playlists,promotions,new-releases,new-playlists,mixes,chart,albums,playlists";
        self.get("/landing3", &[("blocks", BLOCKS.to_string())])
            .await
    }

    /// Дерево метатегов: настроения, занятия, жанры, эпохи.
    pub async fn metatags(&self) -> Result<Value, ApiError> {
        self.get("/landing3/metatags", &[]).await
    }

    /// Жанры с поджанрами и иконками.
    pub async fn genres(&self) -> Result<Value, ApiError> {
        self.get("/genres", &[]).await
    }

    /// Страница тега: плейлисты и `stationId` для радио.
    pub async fn metatag_playlists(&self, tag: &str) -> Result<Value, ApiError> {
        let encoded = encode_segment(tag);
        self.get(&format!("/metatags/{encoded}/playlists"), &[])
            .await
    }

    /// Новая ротор-сессия для станции (`genre:rock`, `mood:calm`, `artist:42`).
    pub async fn station_start(&self, station: &str) -> Result<WaveBatch, ApiError> {
        let value = self
            .post_json("/rotor/session/new", &json!({ "station": station }))
            .await?;
        let result = value.get("result").unwrap_or(&value);
        Ok(WaveBatch {
            session_id: result
                .get("radioSessionId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            batch_id: result
                .get("batchId")
                .and_then(Value::as_str)
                .map(str::to_string),
            tracks: collect_sequence(result),
        })
    }

    /// Новая сессия «Моей волны».
    pub async fn wave_start(&self) -> Result<WaveBatch, ApiError> {
        let value = self.post_json("/rotor/session/new", &json!({})).await?;
        let result = value.get("result").unwrap_or(&value);
        Ok(WaveBatch {
            session_id: result
                .get("radioSessionId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            batch_id: result
                .get("batchId")
                .and_then(Value::as_str)
                .map(str::to_string),
            tracks: collect_sequence(result),
        })
    }

    /// Следующая партия треков существующей сессии.
    pub async fn wave_more(&self, session_id: &str) -> Result<WaveBatch, ApiError> {
        let value = self
            .post_json(&format!("/rotor/session/{session_id}/tracks"), &json!({}))
            .await?;
        let result = value.get("result").unwrap_or(&value);
        Ok(WaveBatch {
            session_id: session_id.to_string(),
            batch_id: result
                .get("batchId")
                .and_then(Value::as_str)
                .map(str::to_string),
            tracks: collect_sequence(result),
        })
    }

    /// Обратная связь сессии. `kind`: `trackStarted`, `trackFinished`, `skip`,
    /// `like`, `dislike`.
    ///
    /// Работает только **множественный** эндпоинт `/feedbacks`: одиночный
    /// `/feedback` в ответ не отдаёт ничего (проверено).
    pub async fn wave_feedback(
        &self,
        session_id: &str,
        track_id: &str,
        batch_id: Option<&str>,
        kind: &str,
    ) -> Result<(), ApiError> {
        let mut event = json!({ "type": kind, "trackId": track_id });
        if let Some(batch_id) = batch_id {
            event["batchId"] = json!(batch_id);
        }
        self.post_json(
            &format!("/rotor/session/{session_id}/feedbacks"),
            &json!({ "feedback": [event] }),
        )
        .await?;
        Ok(())
    }

    /// Поиск. Возвращает `result` (или корень, если обёртки нет).
    pub async fn search(&self, text: &str, page: u32) -> Result<Value, ApiError> {
        let value = self
            .get(
                "/search",
                &[
                    ("text", text.to_string()),
                    ("type", "all".to_string()),
                    ("page", page.to_string()),
                ],
            )
            .await?;
        Ok(unwrap_result(value))
    }

    pub async fn track(&self, id: &str) -> Result<Value, ApiError> {
        let value = self.get(&format!("/tracks/{id}/full-info"), &[]).await?;
        Ok(unwrap_result(value))
    }

    #[allow(dead_code)]
    pub async fn album(&self, id: &str) -> Result<Value, ApiError> {
        let value = self.get(&format!("/albums/{id}/with-tracks"), &[]).await?;
        Ok(unwrap_result(value))
    }

    #[allow(dead_code)]
    pub async fn artist(&self, id: &str) -> Result<Value, ApiError> {
        let value = self.get(&format!("/artists/{id}/info"), &[]).await?;
        Ok(unwrap_result(value))
    }

    pub async fn playlists(&self, uid: u64) -> Result<Value, ApiError> {
        let value = self
            .get(&format!("/users/{uid}/playlists/list"), &[])
            .await?;
        Ok(unwrap_result(value))
    }

    /// Полный плейлист пользователя: метаданные и треки.
    pub async fn playlist(&self, uid: u64, kind: u64) -> Result<Value, ApiError> {
        let value = self
            .get(&format!("/users/{uid}/playlists/{kind}"), &[])
            .await?;
        Ok(unwrap_result(value))
    }

    #[allow(dead_code)]
    pub async fn likes(&self, uid: u64) -> Result<Value, ApiError> {
        let value = self.get(&format!("/users/{uid}/likes/tracks"), &[]).await?;
        Ok(unwrap_result(value))
    }

    /// Прямой URL потока.
    ///
    /// Основной путь — подписанный `/get-file-info` (как у официального клиента):
    /// он отдаёт готовые CDN-ссылки `strm.yandex.net` и поддерживает lossless.
    /// ВАЖНО: подпись и заголовок `X-Yandex-Music-Client` связаны парой —
    /// `kzqU4XhfCaY6B6JTHODeq5` + `YandexMusicDesktopAppWindows/5.95.0`.
    /// Любая другая комбинация даёт `403 not-allowed`.
    ///
    /// Резервный путь — `/tracks/{id}/download-info` + XML + md5-подпись
    /// (`/get-mp3/{sign}/{ts}{path}`), только mp3/aac.
    pub async fn stream(&self, track_id: u64, quality: Quality) -> Result<Stream, ApiError> {
        match self.file_info(track_id, quality).await {
            Ok(stream) => Ok(stream),
            Err(primary) => match self.download_info_stream(track_id, quality).await {
                Ok(stream) => Ok(stream),
                Err(_) => Err(primary),
            },
        }
    }

    /// `/get-file-info` — подписанный запрос за прямыми ссылками.
    async fn file_info(&self, track_id: u64, quality: Quality) -> Result<Stream, ApiError> {
        self.file_info_with(track_id, quality, "raw").await
    }

    /// Офлайн-поток: `transport=encraw` + ключ расшифровки в ответе.
    pub async fn encraw(&self, track_id: u64, quality: Quality) -> Result<Stream, ApiError> {
        self.file_info_with(track_id, quality, "encraw").await
    }

    async fn file_info_with(
        &self,
        track_id: u64,
        quality: Quality,
        transport: &str,
    ) -> Result<Stream, ApiError> {
        let ts = crate::media::now_ts();
        let codecs = crate::media::FILE_INFO_CODECS;
        // В подписи кодеки конкатенируются без разделителя, в query — через запятую.
        let sign = crate::media::sign_file_info(
            crate::media::DESKTOP_SIGN_KEY,
            ts,
            &[track_id],
            quality.as_str(),
            &codecs.concat(),
            transport,
        );

        let value = self
            .get_with_client(
                "/get-file-info",
                &[
                    ("ts", ts.to_string()),
                    ("trackId", track_id.to_string()),
                    ("quality", quality.as_str().to_string()),
                    ("codecs", codecs.join(",")),
                    ("transports", transport.to_string()),
                    ("sign", sign),
                ],
                crate::media::DESKTOP_CLIENT,
            )
            .await?;

        let info = value
            .get("result")
            .and_then(|r| r.get("downloadInfo"))
            .or_else(|| value.get("downloadInfo"))
            .ok_or_else(|| ApiError::NoStream(track_id.to_string()))?;

        let url = info
            .get("url")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| {
                info.get("urls")
                    .and_then(Value::as_array)
                    .and_then(|urls| urls.first())
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .ok_or_else(|| ApiError::NoStream(track_id.to_string()))?;

        Ok(Stream {
            url,
            transport: info
                .get("transport")
                .and_then(Value::as_str)
                .unwrap_or("raw")
                .to_string(),
            key: info.get("key").and_then(Value::as_str).map(str::to_string),
            codec: info
                .get("codec")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            bitrate: info
                .get("bitrate")
                .and_then(Value::as_u64)
                .filter(|value| *value > 0),
        })
    }

    /// GET с `Range` для почанковой загрузки. Возвращает (данные, полный размер).
    ///
    /// `end = None` означает «до конца файла» — так узнаём размер.
    pub async fn fetch_range(
        &self,
        url: &str,
        start: u64,
        end: Option<u64>,
    ) -> Result<(Vec<u8>, Option<u64>), ApiError> {
        let range = match end {
            Some(end) => format!("bytes={start}-{end}"),
            None => format!("bytes={start}-"),
        };

        let response = self
            .http
            .get(url)
            .header("range", range)
            .header("x-yandex-music-client", crate::media::DESKTOP_CLIENT)
            .send()
            .await?;

        let status = response.status();
        if !(status.is_success() || status.as_u16() == 206) {
            return Err(ApiError::Status {
                status: status.as_u16(),
                body: String::new(),
            });
        }

        let total = response
            .headers()
            .get("content-range")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit('/').next())
            .and_then(|v| v.parse::<u64>().ok());

        let bytes = response.bytes().await?.to_vec();
        Ok((bytes, total))
    }

    /// `/tracks/{id}/download-info` + XML → подписанная ссылка `/get-mp3/...`.
    async fn download_info_stream(
        &self,
        track_id: u64,
        quality: Quality,
    ) -> Result<Stream, ApiError> {
        let value = unwrap_result(
            self.get(&format!("/tracks/{track_id}/download-info"), &[])
                .await?,
        );

        let entries = value.as_array().cloned().unwrap_or_default();
        let entry =
            pick_entry(&entries, quality).ok_or(ApiError::NoStream(track_id.to_string()))?;

        let info_url = entry
            .get("downloadInfoUrl")
            .and_then(Value::as_str)
            .ok_or(ApiError::NoStream(track_id.to_string()))?;

        let xml = self.http.get(info_url).send().await?.text().await?;
        let host = parse_tag(&xml, "host").ok_or(ApiError::NoStream(track_id.to_string()))?;
        let path = parse_tag(&xml, "path").ok_or(ApiError::NoStream(track_id.to_string()))?;
        let ts = parse_tag(&xml, "ts").ok_or(ApiError::NoStream(track_id.to_string()))?;
        let s = parse_tag(&xml, "s").unwrap_or_default();

        Ok(Stream {
            url: crate::media::direct_link(&host, &path, &ts, &s),
            transport: "raw".to_string(),
            key: None,
            codec: entry
                .get("codec")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            bitrate: entry.get("bitrateInKbps").and_then(Value::as_u64),
        })
    }
}

/// Предпочтение кодеков по качеству.
fn pick_entry<'a>(entries: &'a [Value], quality: Quality) -> Option<&'a Value> {
    let wanted: &[&str] = match quality {
        Quality::Lossless => &["flac", "flac-mp4", "aac-mp4"],
        Quality::Hq => &["aac", "he-aac", "mp3"],
        Quality::Nq => &["mp3"],
        Quality::Lq => &["mp3"],
    };

    for codec in wanted {
        let mut best: Option<&Value> = None;
        for entry in entries {
            if entry.get("codec").and_then(Value::as_str) != Some(codec) {
                continue;
            }
            let bitrate = entry
                .get("bitrateInKbps")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            let better = best
                .and_then(|b| b.get("bitrateInKbps").and_then(Value::as_u64))
                .map(|current| match quality {
                    // Для lossless берём максимальный, для остальных — ближайший снизу.
                    Quality::Lossless => bitrate > current,
                    _ => bitrate < current && bitrate >= target_bitrate(quality),
                })
                .unwrap_or(true);
            if better {
                best = Some(entry);
            }
        }
        if best.is_some() {
            return best;
        }
    }
    entries.first()
}

fn target_bitrate(quality: Quality) -> u64 {
    match quality {
        Quality::Lossless => 0,
        Quality::Hq => 320,
        Quality::Nq => 192,
        Quality::Lq => 128,
    }
}

/// `<download-info><host>…</host><path>…</path>…` → (host, path).
#[allow(dead_code)] // используется в тестах
pub fn parse_download_info(xml: &str) -> Option<(String, String)> {
    Some((parse_tag(xml, "host")?, parse_tag(xml, "path")?))
}

pub fn parse_tag(xml: &str, name: &str) -> Option<String> {
    let open = format!("<{name}>");
    let close = format!("</{name}>");
    let start = xml.find(&open)? + open.len();
    let rest = &xml[start..];
    let end = rest.find(&close)?;
    Some(rest[..end].to_string())
}

fn unwrap_result(value: Value) -> Value {
    match value.get("result") {
        Some(inner) => inner.clone(),
        None => value,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quality {
    Lossless,
    Hq,
    Nq,
    Lq,
}

#[allow(dead_code)] // as_str/codec нужны для encraw и логов
impl Quality {
    pub fn as_str(self) -> &'static str {
        match self {
            Quality::Lossless => "lossless",
            Quality::Hq => "hq",
            Quality::Nq => "nq",
            Quality::Lq => "lq",
        }
    }

    fn codec(self) -> &'static str {
        match self {
            Quality::Lossless => "flac",
            Quality::Hq => "aac",
            Quality::Nq => "mp3",
            Quality::Lq => "mp3",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "lossless" => Some(Quality::Lossless),
            "hq" => Some(Quality::Hq),
            "nq" => Some(Quality::Nq),
            "lq" => Some(Quality::Lq),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Stream {
    pub url: String,
    pub transport: String,
    pub key: Option<String>,
    pub codec: String,
    pub bitrate: Option<u64>,
}

/// Партия треков сессии радио.
#[derive(Debug, Clone)]
pub struct WaveBatch {
    pub session_id: String,
    pub batch_id: Option<String>,
    pub tracks: Vec<Value>,
}

/// Достаёт треки из `result.sequence` — элементы бывают `{"type":"track","track":{…}}`.
fn encode_segment(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn collect_sequence(result: &Value) -> Vec<Value> {
    result
        .get("sequence")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("track").cloned())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwraps_result_envelope() {
        let value = serde_json::json!({"result": {"tracks": {"total": 1}}});
        assert_eq!(unwrap_result(value)["tracks"]["total"], 1);

        let flat = serde_json::json!({"tracks": {"total": 2}});
        assert_eq!(unwrap_result(flat)["tracks"]["total"], 2);
    }

    #[test]
    fn parses_download_info_xml() {
        let xml = "<?xml version=\"1.0\"?><download-info><host>mds.storage.yandex.net</host><path>/rmusic/abc/29043</path><ts>1</ts></download-info>";
        let (host, path) = parse_download_info(xml).expect("parsed");
        assert_eq!(host, "mds.storage.yandex.net");
        assert_eq!(path, "/rmusic/abc/29043");
    }

    #[test]
    fn builds_signed_direct_link() {
        let url = crate::media::direct_link(
            "api.music.yandex.net",
            "/U2FsdGVkX19/0/1771562/93cb8a19",
            "1a1d0a63e9a",
            "abc",
        );
        assert!(url.starts_with("https://api.music.yandex.net/get-mp3/"));
        assert!(url.ends_with("/1a1d0a63e9a/U2FsdGVkX19/0/1771562/93cb8a19"));
    }

    #[test]
    fn collects_sequence_tracks() {
        let value = json!({
            "sequence": [
                {"type": "track", "track": {"id": "1", "title": "A"}},
                {"type": "track", "track": {"id": "2", "title": "B"}},
                {"type": "concert", "concert": {"id": "3"}}
            ]
        });
        let tracks = collect_sequence(&value);
        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[0]["title"], "A");
    }

    #[test]
    fn picks_codec_per_quality() {
        let entries = vec![
            serde_json::json!({"codec": "mp3", "bitrateInKbps": 320}),
            serde_json::json!({"codec": "aac", "bitrateInKbps": 192}),
        ];
        let chosen = pick_entry(&entries, Quality::Hq).expect("entry");
        assert_eq!(chosen["codec"], "aac");
    }
}
