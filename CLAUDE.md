# Spinebrowser

Arc/Zen-style browser for the iPhone Duo. Native SwiftUI + WKWebView.

## Writing

Follow [voice.md](voice.md) for all words the project ships or publishes: UI copy, onboarding screens, empty states, error messages, settings labels, App Store text, READMEs, specs and technical docs. Commit messages and code comments stay plain and technical.

## Design

[.impeccable.md](.impeccable.md) holds the design context (palette, type, principles). The spec is [docs/mvp-spec.md](docs/mvp-spec.md); the Paper file it links is the source of truth for layouts.

All designs and the design language (color, type, space and motion, device and system UI, the Spine, every posture mode) live in the Paper file **Spinebrowser**. Read them through the Paper MCP (`get_basic_info`, `get_screenshot`, `get_jsx`, `get_computed_styles`) before building or changing UI, and take exact values from there, not from screenshots.
