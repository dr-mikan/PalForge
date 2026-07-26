# 03 — Audio

Fills **`dump_targets.md` §9.2** (audio SoundIDs), **§9.4** (`setVolume`), and **§9.5**
(`FileSource:play`), using the plan in **§4 (mechanism 2e)** and **§8**.

Palworld SEs/BGM are **Wwise events named by an FName SoundID row** — not `USoundBase` — so
`PlaySound2D` does not apply. The engine call is already wired in
`utils/sound/native.lua : NativeSource:play` (`UPalSoundUtility:PlaySoundByActor(actor,
{ Key = FName(id) }, { FadeInTime = 0 })`). Each `native/audio/*` file only supplies the
**data** (`soundId`); the base `BackgroundMusic`/`SoundEffect` in `base/audio.lua` inherit
`play()`/`stop()`.

---

## 3.1 BGM SoundIDs — `native/audio/bgm/*`

1. **Target** — the `soundId` placeholder in each BGM file:
   - `native/audio/bgm/main_theme.lua` → `MainTheme.soundId = "MainTheme"`
   - `native/audio/bgm/battle_theme.lua` → `BattleTheme.soundId = "BattleTheme"`
   - `native/audio/bgm/victory_theme.lua` → `VictoryTheme.soundId = "VictoryTheme"`
2. **Dump source** — `01_datatables.txt`. Grep for Sound tables: `Sound` / `BGM` / `Wwise` /
   `Ak` (mechanism 2a). The rows are the valid SoundID FNames.
3. **Extract** — the Wwise-event FName row for each track. **Confirm each by playing it**
   (mechanism 2e), reusing the proven CDO call:
   ```lua
   local u = StaticFindObject("/Script/Pal.Default__PalSoundUtility")
   u:PlaySoundByActor(FindFirstOf("PalPlayerCharacter"), { Key = FName("<row>") }, { FadeInTime = 0 })
   ```
   Audible ⇒ valid. (This is exactly what `NativeSource:play` will do at runtime.)
4. **Implement** — set `<Cls>.soundId = "<confirmed FName>"` in each file. Nothing else
   changes — the play path already works once the id is real.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- Sound table name (01_datatables.txt): ____________
-- confirmed SoundID rows (audible via PlaySoundByActor):
--   MainTheme.soundId    = "____________"
--   BattleTheme.soundId  = "____________"
--   VictoryTheme.soundId = "____________"
```

---

## 3.2 SE SoundIDs — `native/audio/se/*`

1. **Target** — the `soundId` placeholder in each SE file:
   - `native/audio/se/explosion.lua` → `Explosion.soundId = "Explosion"`
   - `native/audio/se/laser.lua` → `Laser.soundId = "Laser"`
   - `native/audio/se/footstep.lua` → `Footstep.soundId = "Footstep"`
2. **Dump source** — same Sound tables in `01_datatables.txt` (`Sound`/`SE`/`Wwise`/`Ak`).
3. **Extract** — the Wwise-event FName for each SE; confirm each by `PlaySoundByActor`
   (mechanism 2e, as §3.1).
4. **Implement** — set `<Cls>.soundId = "<confirmed FName>"` in each file.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- confirmed SoundID rows (audible via PlaySoundByActor):
--   Explosion.soundId = "____________"
--   Laser.soundId     = "____________"
--   Footstep.soundId  = "____________"
```

---

## 3.3 `setVolume` — `base/audio.lua`

1. **Target** — `base/audio.lua : BackgroundMusic:setVolume(volume)` and
   `SoundEffect:setVolume(volume)` — both are inert `-- TODO:` seams. There is **no** volume
   control on `PalSoundUtility`.
2. **Dump source** — `02_reflection.txt`: grep `/Script/Pal.PalSoundUtility` and any AkAudio
   class present for `Volume|Gain|RTPC|SetRTPCValue`. If none reflect, use the UE4SS object
   dump to look for an `AkComponent` / `SetRTPCValue` global-parameter path.
3. **Extract** — either an AkAudio RTPC set-call signature (`SetRTPCValue(FName, float, actor)`)
   or a component-gain path. If **none exists**, record that volume is not controllable and
   the seam stays a documented no-op.
4. **Implement** — in `base/audio.lua`, replace the TODO with the discovered call, clamping
   `volume` to `0.0..1.0`. Both `BackgroundMusic:setVolume` and `SoundEffect:setVolume` share
   the same mechanism — implement once and call from both.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- volume mechanism found (RTPC name / gain path) or "none — not controllable":
--   ____________
-- final code (base/audio.lua : setVolume):
--
```

---

## 3.4 Custom-file playback — `utils/sound/file.lua`

1. **Target** — `utils/sound/file.lua : FileSource:play(actor)` — a TODO stub that returns
   `false`. Reached when a `native/audio/*` class sets `self.soundFile` instead of
   `self.soundId` (see `base/audio.lua : resolveSourceSpec`, which prefers a file over an id).
2. **Dump source** — `02_reflection.txt` + probing: look for a way to build/load a
   `USoundWave`/`USoundBase` from a file at runtime. **Palworld uses Wwise**, so this may be
   impossible — the first goal is to confirm feasibility.
3. **Extract** — a loader signature (e.g. an engine import call producing a `USoundWave`) and
   a play call that accepts it; or the confirmation that no such path exists.
4. **Implement** — if feasible: load `self.path` → `USoundWave`, then play it on `actor`
   (fail-soft, return the pcall result). If not: leave the no-op and document that custom-file
   audio is unsupported under Wwise (the framework already degrades gracefully — `sound.play`
   treats an unresolvable spec as a success no-op).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- runtime file->USoundWave loader found?  yes/no + signature:
--   ____________
-- final code (utils/sound/file.lua : FileSource:play) OR "confirmed impossible under Wwise":
--
```

---

## Coverage — this doc

| Checklist item | Section |
|---|---|
| §9.2 `native/audio/bgm/{main,battle,victory}_theme.lua` — `soundId` | §3.1 |
| §9.2 `native/audio/se/{explosion,laser,footstep}.lua` — `soundId` | §3.2 |
| §9.4 `base/audio.lua : BackgroundMusic:setVolume` | §3.3 |
| §9.4 `base/audio.lua : SoundEffect:setVolume` | §3.3 |
| §9.5 `utils/sound/file.lua : FileSource:play` | §3.4 |
