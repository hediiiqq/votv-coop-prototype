# VotV Coop Prototype

Experimental LAN cooperative-play prototype for Voices of the Void 0.9.x.

## Current state

- UDP host/client handshake and heartbeat.
- Player position and yaw exchange through a UE4SS Lua bridge.
- Remote-player debug marker.
- Host/client configuration helper.
- Windowed launch helpers for two local game copies.

This is not full multiplayer yet. The current milestone validates networking and remote transforms; world interactions, inventories, events, saves, and a visible replicated character remain future work.

## Repository layout

- `bridge/` — self-contained .NET UDP companion source.
- `mod/` — UE4SS Lua mod.
- `installer/` — manual setup helpers.
- `launchers/` — windowed game launch scripts.
- `tests/` — local integration checks.

## Build

```powershell
dotnet publish .\bridge\VotVCoopBridge.csproj -c Release -r win-x64 --self-contained true -o .\standalone
```

## Safety and licensing

This repository intentionally excludes the game, game assets, PAK files, saves, UE4SS binaries, and compiled executables. Users must obtain Voices of the Void and UE4SS separately from their official distribution channels.
