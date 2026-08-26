# Go Bridge Design

## Goal

Replace the 64.4 MB self-contained .NET `VotVCoopBridge.exe` with a small native Windows executable written in Go, without changing the installed Lua mod, configuration format, state-file format, launcher behavior, or UDP wire protocol.

## Scope

The Go bridge is a drop-in replacement for the existing .NET bridge. It supports the existing `host` and `client` roles, periodically exchanges player state over UDP, writes the newest remote state atomically, prints connection telemetry, survives transient file-sharing and network errors, and stops cleanly when the game exits.

This migration does not add gameplay synchronization features, change the Lua marker, introduce a binary protocol, or embed Go into UE4SS.

## Compatibility Contract

- Platform: Windows x64.
- Distribution: one statically linked `VotVCoopBridge.exe`; players do not install Go or .NET.
- Configuration: retain the current `config.ini` keys and defaults.
- Local input: retain `runtime/local_state.txt` and its current text representation.
- Remote output: retain `runtime/remote_state.txt` and its current text representation.
- Network: retain the current UDP endpoint selection and packet text representation so a Go bridge can interoperate with the current C# bridge during migration testing.
- Console: retain startup, game-loaded, connection, peer-position, distance, warning, and fatal diagnostics in a visible console window.

## Structure

The bridge will live in `bridge-go/` as a small Go module. `main.go` owns process startup and shutdown. Focused files own configuration parsing, state parsing/formatting, UDP transport, atomic state-file IO, and telemetry. Tests live beside each component using Go's standard `testing` package; no third-party runtime dependencies are required.

The existing C# source remains in `bridge/` during migration as a protocol reference and rollback implementation. Packaging scripts switch to the Go artifact only after compatibility and integration tests pass.

## Runtime Flow

1. Resolve the mod directory from the executable location.
2. Read and validate `config.ini`; invalid roles, hosts, or ports produce actionable console errors.
3. Wait for the configured game process and local state file while continuing to print status.
4. Open UDP in host or client mode and exchange the existing text packets.
5. Parse valid peer packets, reject malformed packets without terminating, and atomically replace `runtime/remote_state.txt`.
6. Once per second, print peer name, coordinates, distance, and connection status.
7. When the game exits, close the socket and process cleanly.

## Reliability

Transient `sharing violation`, missing-file, malformed-file, and UDP errors are warnings or ignored samples rather than process-fatal errors. Atomic output uses a temporary file in the runtime directory followed by replacement. The bridge never truncates a readable remote-state file before replacement succeeds. Network receive activity has deadlines so shutdown cannot hang.

## Verification

- Unit tests cover configuration, state and packet parsing, malformed input, atomic writes, distance calculation, and telemetry throttling.
- A compatibility test exchanges packets between Go and the existing C# bridge in both host/client directions.
- The existing local-copy validator continues to pass after packaging changes.
- Installed Server and Client copies are launched on one PC and must both remain alive, show `CONNECTED`, update `remote_state.txt`, and display the in-game locator.
- The release binary is built with `CGO_ENABLED=0` for `windows/amd64`; its size and SHA-256 are recorded during packaging.

## Delivery

The Go toolchain is a developer-only build dependency. The repository receives source, tests, deterministic build instructions, updated installer/package files, and documentation. Verified changes are committed and pushed to the existing private GitHub repository.
