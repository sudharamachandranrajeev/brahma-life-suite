# Brahma — notes for Claude Code sessions

Brahma is a Flutter suite (Linux, Windows, Android) with one shared core and a self-hosted,
end-to-end encrypted sync server. It is also the shared layer of Brahma OS
(images and installer live in the separate `brahma-os` repository).

## Layout

- `app/` — Brahma, the all-in-one app (life dashboard, launcher for the suite apps).
- `apps/<name>/` — each app is a git subtree of its own repository. Never edit them here:
  change the app's repository, then run `scripts/pull-apps.sh <name>`.
- `core/` — `brahma_core`: encrypted database (drift + SQLite3MultipleCiphers), keychain-held key,
  sync, device pairing, app frame, Sentinel, `SuiteApp`. See `core/README.md`.
- `server/` — the sync server (Node/TypeScript; home or Cloudflare). See `server/README.md`.
- `sentinel/` — signed security advisories every app shows.
- `watch/` — Cloudflare Worker + ntfy alerts.

## Build and test

Flutter 3.47 (CI pins 3.47.7). Linux build needs `clang cmake ninja-build pkg-config
libgtk-3-dev libsecret-1-dev`.

```bash
cd app && flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze && flutter test
flutter build linux --release
```

Server: `cd server && npm ci && npm test`.

CI: `.github/workflows/ci.yml` on every push; `release.yml` on `v*` tags.

## Rules

- Security matters: user data is encrypted on the device; the server stores only ciphertext.
  Do not weaken encryption, pairing or Sentinel signature checks.
- No personal data, hostnames, IPs, tailnet names or secrets in commits. Run gitleaks before pushing.
- Licence: Apache-2.0 (see `LICENSE`, `NOTICE`). `apps/*` follow their own repositories' licences.
- READMEs use plain, step-by-step language.
