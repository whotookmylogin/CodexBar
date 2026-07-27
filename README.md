# CodexBar (macOS 13 Intel fork)

Menu bar usage meters for AI coding limits on **macOS 13 / Intel**.

This is **not** a full port of upstream CodexBar 0.45+ (macOS 14+, Swift 6.2, 60+ providers).
It starts from the original lightweight CodexBar app and adds the highest-value modern features that still compile on Swift 5.9 / macOS 13.

## Providers
- **Codex** — local `~/.codex/sessions` token_count events + auth plan/email
- **Claude** — OAuth usage API via `~/.claude/.credentials.json`
- **OpenRouter** — credits + key limits via `OPENROUTER_API_KEY` or `~/.config/codexbar/config.json`
- **Grok** — identity from `~/.grok/auth.json` + local session signals (billing % needs macOS 14 full app / browser session)

## Modern features included
- Multi-provider menu with switcher
- Separate status items or merged icon mode
- Relative reset countdowns
- Refresh presets: Manual / 1 / 2 / 5 / 15 / 30 min
- Low-quota notifications
- Launch at login (best-effort; unsigned builds may need manual Login Items)
- Provider enable toggles

## Build (on the Intel Mac)
```bash
ARCH=x86_64 ./Scripts/package_app.sh release
open CodexBar.app
# or install:
cp -R CodexBar.app /Applications/
```

## Branch
`compat/macos-13-modern`
