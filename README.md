# POOL GOD — 8 Ball Duels

Auto-aim / auto-shot for **8 Ball Duels** (Roblox).

## Loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/celineasher/pool-god/main/poolgod.lua"))()
```

Cache-busted:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/celineasher/pool-god/main/poolgod.lua?t=" .. os.time()))()
```

## Keys

| Key | Action |
| --- | --- |
| `G` | Aim + shoot the best shot |
| `H` | Aim only (draws the guide line) |
| `J` | Toggle auto-shot |
| `R` | Release aim / hide guide |
| `RightShift` | Show / hide panel |

The panel also has AUTO SHOT / AIM ONLY / SHOOT buttons.

## How it works

- Finds the local match seat through `getgc(true)`.
- Uses the game's own `PoolRules.IsLegalFirstContact` so it targets a legal ball.
- Ghost-ball geometry against every pocket, with cue and object path clearance checks, picks the lowest cut/distance shot.
- Aims through `PoolInputController.SetAimDirection` and shoots through `ShotBindable`, so the game's normal validation, prediction and server event are used.
- Waits for balls to settle before aiming; never fires while a shot is resolving.
- Reloading is safe (old GUI and connections are cleaned up).
