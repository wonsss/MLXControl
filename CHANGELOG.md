# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.2] - 2026-06-04
### Fixed
- Ensure only one `mlx_lm.server` instance runs while switching models.
- Wait for the previous server process and port to stop before launching the selected model.
- Queue a follow-up restart when the model is changed again during an active transition.

## [1.3.0] - 2026-06-04
### Added
- Initial public release.
- Menu bar control for a local `mlx-lm` server: Start / Stop / Restart.
- Auto-detect installed MLX models from the HuggingFace cache.
- Model search / download / delete via the HuggingFace API (size, metadata, README preview, detail view).
- Real-time MLX process RAM & CPU and system GPU utilization / memory (via `ioreg`), with a GPU sparkline.
- Warm-up action: pre-load the model and measure tokens/sec.
- Resource-threshold notifications (process RAM, free system memory).
- Copy endpoint, Launch-at-Login toggle, move-to-/Applications on first launch.

### Security
- All subprocess calls use `Process` argument arrays (no shell-string interpolation).
- Model delete validates the repo-ID format and is confined to the HF cache directory.
- Tool paths (`mlx_lm.server`, `hf`) are resolved via PATH search, not hardcoded.

### Performance
- Polling I/O runs off the main thread (gather/apply split); idle CPU stays near zero.

[Unreleased]: https://github.com/wonsss/MLXControl/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/wonsss/MLXControl/compare/v0.1.1...v0.1.2
[1.3.0]: https://github.com/wonsss/MLXControl/releases/tag/v1.3.0
