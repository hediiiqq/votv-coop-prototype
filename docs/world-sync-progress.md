# World sync — progress and handoff

Living notes for the co-op world synchronisation work. Written so the next
session can pick up without re-deriving anything.

## Working agreement

- Antigravity (`agy` CLI) writes the code and runs the tests.
- Claude Code orchestrates and does the code review, reading the diffs itself.
- Work happens on `main` and is pushed once tests and review are green.
- The user plays both sides in the game and reports what happened; logs are
  read from disk rather than pasted.

`agy` is driven directly through Bash:
`agy.exe --dangerously-skip-permissions --effort high --print-timeout 25m -p "<task>"`.
The MCP path does not work here (no `tmux`), and the `task` CLI is not installed,
so contracts are passed inline.

## Where things stand

Stage 1 of world sync (doors, light switches, power panel) is written and
committed, but **not yet confirmed working in game**. The last in-game attempt
failed completely; the cause was found and fixed, and the fix is awaiting a
retest.

### Done

- **Ping marker (F9)** — was drawn above the player's head, inside the
  first-person blind spot. Now drawn on the floor in front of the player.
- **Mod delivery** — the repo copy was fixed while `F:\VOTV\Client` and
  `F:\VOTV\Server` kept a stale one, so no fix ever reached the game.
  Scripts are now copied on setup and on every windowed launch, and
  `Validate-LocalCopies.ps1` fails on a hash mismatch or an orphan file.
- **F7 inspector** (`mod/scripts/diag_interact.lua`) — read-only probe that
  dumps the actor under the crosshair: class chain, properties, functions.
  This is how the object model below was discovered.
- **Crash fix** — F10 was already bound to `ConsoleEnablerMod`'s dev console,
  and handlers touched UE objects off the game thread. Moved to F7, everything
  routed through `ExecuteInGameThread`, F9 throttled to one ping per 0.5s.
- **Bridge protocol** (`bridge/Program.cs`) — `INTERACT_REQ`, `WORLD_STATE`,
  `WORLD_ACK` with retransmit-until-acked, host-side dedup, snapshot on join
  and on reconnect. Inbound state accumulates in a journal: the bridge writes
  every 25ms and the mod reads every 50ms, so per-cycle writes dropped states.
- **Mod side** (`mod/scripts/coop_world.lua`) — hooks, echo guard, object cache,
  host-authoritative apply.
- **Refactor** — object knowledge lives in one `KINDS` table instead of four
  parallel if/elseif chains. Adding a kind is one row.
- **Deferred attach** — the fix for the failed test, see below.

### Open — next action

Retest stage 1 in game, both windows, after the level has loaded:
host opens a door, then the client opens one, then light switches. Then read
`UE4SS.log` in both install folders. The log now states how many hooks
attached, how many objects were found, and what was sent and applied.

## The object model (measured, not guessed)

All three inherit from `triggerBase_C`. Paths are exactly as dumped by F7:

| Kind | Class | State | Apply via | Id |
|---|---|---|---|---|
| Door | `/Game/objects/door.door_C` | `isOpened` (bool) | `doorOpen(true)` / `doorClose(true)` | map `Key`, e.g. `basedoor_signalroom` |
| Light switch | `/Game/objects/lightswitch.lightswitch_C` | `A` (bool) | `runTrigger()` / `player_use()` | map `Key`, e.g. `lightswitch_signalroom` |
| Power panel | `/Game/objects/powerControl.powerControl_C` | `press_calc`, `press_coord`, `press_downl`, `press_play`, `press_light` | `powerChanged(calc, downl, coord, play, light)` + `moveLevers()` | **actor path** |

The power panel `Key` is generated per save (`UrCgZUozHxXzTc5Ky5a9ZQ`) and does
not match between players, so it is addressed by actor path instead. Door and
switch keys are stable, readable and identical on both sides.

## Design decisions

- **The host owns the truth.** The client sends `INTERACT_REQ` and applies what
  it is told; it never broadcasts `WORLD_STATE`. This makes an echo loop
  structurally impossible and keeps client traffic tiny.
- **World packets are reliable, position packets are not.** A dropped position
  is corrected by the next frame; a dropped "door opened" desyncs the session
  permanently.
- **A guard flag suppresses our own hooks while applying remote state**, so an
  applied change is not reported back as a fresh local change.

## Failures worth remembering

- **Attaching at startup.** The mod initialises in the main menu, before
  `/Game/objects` blueprints exist. All 20 hooks failed and the world scan
  cached zero actors, with nothing rescanning later. Anything that depends on a
  loaded world must be deferred and retried.
- **Invented blueprint paths.** A first attempt used `/Script/VotV.door_C`,
  which silently matches nothing. Always take paths from an actual F7 dump.
- **Green tests that assert nothing.** A geometry check passed only because old
  values survived in code comments; a dedup test was filtered client-side before
  reaching the network; a snapshot test read stdout instead of the file, which
  hid a data-loss bug. Reintroduce the defect and confirm the test goes red.
- **Reviews that pass the shape, not the behaviour.** The first crash review
  approved a module that then crashed the game, because it never asked about
  threads or key conflicts with other mods.

## Verification

```
powershell -ExecutionPolicy Bypass -File tests/<name>.ps1
```

`Test-LuaWorldSync`, `Test-BridgeWorldSync`, `Test-LuaRemoteAvatar`,
`Test-BridgeActionEvent`, `Test-BridgeTelemetry`, `Test-BridgeStaleExit`,
`Validate-LocalCopies`. All seven were green at the last commit.

`Test-BridgeStaleExit` prints a UDP bind error on the way to PASS; that is the
scenario it exercises, not a failure.

Logs from the failed in-game run are kept in `.local-logs/` (git-ignored).

## Roadmap

1. Doors, switches, power panel — **written, awaiting in-game confirmation**
2. Time of day
3. Items: pick up, carry, drop — needs a net id registry; F7 dumps of carryable
   items still to be taken
4. Base equipment: terminal, dishes, signals
5. Physics and vehicles — heaviest, deliberately last
