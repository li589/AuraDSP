# CLAUDE.md — Claude Code / IDE Agent Project Guide

## Overview
AuraDSP is a next-generation high-fidelity audio DSP engine and modern desktop UI workstation.
- **Engine Core (`core/desktop/`)**: C++20, libjamesdsp port, RT-Safe audio pipeline (zero-alloc, zero-lock, zero-syscall in audio thread).
- **Frontend App (`app/auradsp_app/`)**: Flutter 3.47.7+, Dart FFI, lockless SPSC ring buffer for 30fps visualization frames.
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

# Push via API fallback if git push origin fails
python tools/push_via_api.py main
```

## Critical Engineering Constraints
1. **Audio Real-Time Safety**: Under NO circumstances should memory allocation (`malloc`, `new`), locks (`std::mutex`), or I/O be performed on the audio processing thread.
2. **Icon Tree-Shaking Warning**: Always pass `--no-tree-shake-icons` when compiling Flutter, or MaterialIcons will silently render blank glyphs.
3. **UI Automated Testing Integrity**:
   - Every GUI interaction test MUST bring the target window to foreground top-most (`HWND_TOPMOST + SetForegroundWindow`).
   - Every slider interaction MUST check and guarantee that the effect switch is ON before dragging (disabled sliders ignore input).
   - Mouse events MUST hit exact Thumb center pixels and use image difference assertions (`assert_images_differ`) to ensure real visual change.
4. **Third-Party Code (`source/`)**: `source/` is read-only reference code. Never commit nested `.git` repositories in `source/`.
