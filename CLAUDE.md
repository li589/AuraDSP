# CLAUDE.md — Claude Code / IDE Agent Project Guide

## Overview
AuraDSP is a next-generation high-fidelity audio DSP engine and modern desktop UI workstation.
- **Engine Core (`engine/`)**: C++20, RT-Safe audio pipeline (zero-alloc, zero-lock, zero-syscall in audio thread). Layout (P3a top-level move + P4b subdirs + 2026-10-16 legacy absorption + 2026-10-20 P1 plugin move): `auradsp_engine.{h,cpp,def}` (C ABI) + `engine_internal.h` + `chain/` (chain/convolver/viz/probe/audiofile) + `dsp/` (11 self-developed effect TUs) + `plugins/` (api/driver/formats/platform/integration/tests VST3/CLAP host) + `legacy/` (JamesDSP C algorithm core, absorbed from `vendor/libjamesdsp/`; patch ledger at `engine/legacy/PATCHES.md`).
- **Windows Driver Suite (`core/desktop/windows-drivers/`)**: Decoupled transport/format layer — `01_vaio_driver/` (PortCls/WaveRT AuraVAIO virtual sound card, modern + Win7 legacy tracks), `02_voicemeeter_client/` (VM callback pump), `03_system_apo/` (self-built APO `AuraApo.dll` + Configurator/selftest/tone_play/probes), `04_asio_client/` + `04_asio_driver/` (ASIO host and virtual driver), `bridge/` (unnumbered FFI bridges: `common/PluginBridge.h` + `vm_bridge/`, `asio_bridge/`, `vaio_bridge/`). Separate CMake, NOT part of engine build. See its README.
- **Platform Shell (`core/`)**: `core/desktop/windows/` (CMake + WASAPI, DLL truth source `out/Release/auradsp_engine.dll`), `core/android/` (AIDL effects HAL registrar/spike/stubs).
- **Frontend App (`app/auradsp_app/`)**: Flutter 3.47.7+, Dart FFI, lockless SPSC ring buffer for 30fps visualization frames (536-byte `auradsp_viz_frame`). 6-page navigation; audio backend modes (vaio/vbcallback/sysapo/asio) persisted in `lib/core/audio_modes.dart` (vbcallback/asio live-switch; vaio/sysapo selection persisted).
- **Assets (`assets/`)**: IR/VDC/EEL runtime resources (251MB local). `.irs`/`.vdc` are gitignored for NEW files, but 2214 historical files (73MB) remain tracked — removal pending owner decision, do not `git rm --cached` unilaterally.
- **Reference Docs (`docs/参考技术手册/`)**: Third-party PDF manuals (Microsoft WDK/Win32/UWP/MSVC/WSL, Steinberg ASIO, android_guides_cn, ~220MB) — local read-only, only README manifest committed. Do not push PDFs (GitHub 100MB limit + redistribution not licensed).
- **Testing (`test/`)**: `test/smoke/` for C++ DLL tests via ctypes; `test/ui/` for topmost automated GUI assertions.
- **Tools (`tools/`)**: Developer utilities, diagnostic probes, and generator tools.
- **AI Knowledge (`.ai/`)**: Multi-agent shared memories and guidelines.

## Build & Test Commands
```bash
# Engine smoke tests (ctypes, non-GUI, instant)
python test/runner.py --smoke

# UI automated verification (requires window, top-most foreground activated)
python test/runner.py --ui

# Flutter lint & analyze
cd app/auradsp_app && flutter analyze

# Build Release application (MANDATORY: --no-tree-shake-icons)
cd app/auradsp_app && flutter build windows --release --no-tree-shake-icons

# Build C++ engine DLL and auto-sync artifacts to test/app-runner/dist
# (build_engine.sh invokes tools/sync_artifacts.ps1 after a successful build)
bash core/desktop/windows/build_engine.sh

# One-shot incremental artifact sync ONLY (no compile): cover-distribute truth sources
# to test/, app-runner, dist/. Any missing endpoint or single-file failure warns and skips.
powershell -ExecutionPolicy Bypass -File tools/sync_artifacts.ps1

# Push via API fallback if git push origin fails
python tools/bin/push_via_api.py main
```

## Critical Engineering Constraints
1. **Audio Real-Time Safety**: Under NO circumstances should memory allocation (`malloc`, `new`), locks (`std::mutex`), or I/O be performed on the audio processing thread.
2. **Icon Tree-Shaking Warning**: Always pass `--no-tree-shake-icons` when compiling Flutter, or MaterialIcons will silently render blank glyphs.
3. **UI Automated Testing Integrity**:
   - Every GUI interaction test MUST bring the target window to foreground top-most (`HWND_TOPMOST + SetForegroundWindow`).
   - Every slider interaction MUST check and guarantee that the effect switch is ON before dragging (disabled sliders ignore input).
   - Mouse events MUST hit exact Thumb center pixels and use image difference assertions (`assert_images_differ`) to ensure real visual change.
4. **Third-Party Code (`source/`)**: `source/` is read-only reference code (17 ORIGIN entries, 16 top-level clones; see `source/ORIGIN.md` and `docs/10-架构/source-参考项目审理报告.md`). Never commit nested `.git` repositories in `source/`. No LICENSE ≠ open source — GitHub default is All Rights Reserved; ViPER-family code must never be merged into this GPL-3.0 project.
