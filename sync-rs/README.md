# brahma-sync (Rust)

The Rust client for Brahma sync: the same end-to-end encrypted protocol as
brahma core's Dart sync (`core/lib/src/sync`). Rust apps use it to join the
same Brahma account as the Flutter apps: Samriddhi for the money and wealth
bridge rows, Setu for its sync rules and device list.

- Argon2id and HKDF keys, a wrapped data key, XChaCha20-Poly1305 per change.
- Hybrid logical clocks, an outbox with numbered batches, a cursor per device.
- Clashing edits are kept, not lost; pairing links; moved-server links.
- The server only ever sees ciphertext.

Use it from another repository by git:

```toml
brahma-sync = { git = "https://github.com/sudharamachandranrajeev/brahma-life-suite" }
```

Tests: `cargo test`. `tests/vectors.rs` checks the Rust and Dart sides
against each other with the shared files in `core/test/fixtures`.
`tests/live.rs` starts the real server (`server/src/home.ts`, Node 24+) on
loopback, and skips with a note when Node is missing.
