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
- **Bank shots**: mirrors every pocket across every cushion segment (cushion gaps included), validates the rail contact point, both path legs and the cut angle, then scores banks with a penalty so direct pots are preferred. Bank shots are marked `BANK` in the panel.
- **Guide lines**: cyan = cue path traced with up to 3 cushion bounces, gold = bank object route (ball -> rail contact -> pocket), green = direct object route.
- Aims through `PoolInputController.SetAimDirection` and shoots through `ShotBindable`, so the game's normal validation, prediction and server event are used.
- Waits for balls to settle before aiming; never fires while a shot is resolving.
- Reloading is safe (old GUI and connections are cleaned up).
