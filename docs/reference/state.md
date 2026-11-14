# Состояние плеера

Файл генерируется `bash scripts/docs-sync.sh`; правьте код, а не таблицу.

<!-- generated:state -->
| `rev` | `u64` |
| `status` | `String` |
| `track` | `Option<Track>` |
| `positionMs` | `u64` |
| `volume` | `f64` |
| `queue` | `Queue` |
| `env` | `EnvState` |
| `ui` | `UiState` |
| `wave` | `Option<WaveInfo>` |
| `quality` | `String` |
| `codec` | `Option<String>` |
| `bitrateKbps` | `Option<u64>` |
| `downloads` | `Vec<Download>` |
| `downloadPending` | `u64` |
<!-- /generated:state -->
