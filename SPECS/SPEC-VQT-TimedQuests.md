# SPEC-VQT-TimedQuests: timed quest countdown on the card

- **Status:** Approved design (owner 2026-11-23), not yet implemented
- **Parent:** `SPEC-VelocityQuestTracker.md` (Part 2: actionable block)
- **Code:** `Client/Client*.lua`, `Core/Model.lua`, `UI/Blocks.lua`, `UI/Theme.lua`, `UI/StockTracker.lua`, `VelocityQuestTracker.lua`

## Problem

A timed quest (escort with a clock, "deliver within 15 minutes", ...) shows no countdown in the tracker. Blizzard draws
it in `QuestTimerFrame`, a frame separate from the objective tracker that we swallow, so the player either sees two
trackers or no timer at all. A running timer is also the one quest state that must never fall out of the card: ageing
it onto a nearby/other line after `ActiveWindowSeconds` hides the clock exactly when it matters.

## Decisions (owner 2026-11-23)

| # | Decision |
|---|---|
| 1 | A quest with a running timer is **always a card** (category `active`) while the timer runs: no zone test, no activity window, no auto-untrack. |
| 2 | The countdown is **its own centred line directly under the title**: `Remaining: mm:ss` (hours as `h:mm:ss` when >= 1 h). |
| 3 | Tone: `Recent` (yellow) the whole time -> new `Danger` (red) under **15 s**. Threshold and the red are settings. (Originally `Label` until 60 s, then yellow; owner 2026-11-27: a running clock is always yellow and drawn at `RowSize`, not `LabelSize`, so it is obvious. `TimerWarnSeconds` removed.) |
| 4 | Timed cards sort **first** in the active bucket (rank is otherwise append-only; a clock is the one legitimate reason to jump the queue). |
| 5 | Blizzard's `QuestTimerFrame` is swallowed alongside the stock tracker. |
| 6 | A **failed** timed quest (`isFailed`) loses the countdown line and the pin; it is categorised as today. |

## API ground truth (verified 2026-11-23, wiki + wowlua)

| Client | Call | Returns |
|---|---|---|
| Forever (1.60.1) | `C_QuestLog.GetQuestTimers()` | `{ { questID, questTimer }, ... }` -- `questTimer` = seconds **remaining** |
| Forever | `C_QuestLog.GetTimeAllowed(questID)` | `totalTime, elapsedTime` (may return nothing) |
| Era (1.15) | `GetQuestTimers()` | varargs: remaining seconds per running timer, in log-slot order; failed/expired omitted |
| Era | `GetQuestIndexForTimer(i)` | quest log index for the i-th running timer |
| Both | event `QUEST_TIMER_UPDATE` | fires when a timer starts/stops/changes; the stock `QuestTimerFrame` listens to it |

Remaining time is **sampled once per model build** and extrapolated with `GetTime()` on the view side; no per-frame API
calls. `QUEST_TIMER_UPDATE` and the existing quest-log events mark the model dirty, which resamples.

Notes saved to `AddonManagement\_EXTERNAL_APIS\wow_quest_timer_api.md`.

## Design

### Client (`Client/Client.lua` + flavours)

`VQT_Quest` gains two optional fields, nil when the quest is not timed or its timer is not running:

```lua
--     timerRemainingSeconds = number|nil,   -- seconds left when Quests() was called
--     timerSampledAt        = number|nil,   -- GetTime() at that call (view extrapolates from this)
--     timerTotalSeconds     = number|nil,   -- Forever only (GetTimeAllowed); Era nil
```

- `Client_Forever.lua`: before the log loop, build `timersByQuestID` from `C_QuestLog.GetQuestTimers()`; attach to the
  matching quest; `timerTotalSeconds` from `GetTimeAllowed` (pcall, nil-safe).
- `Client_ClassicEra.lua`: `local t = { GetQuestTimers() }`; for `i, secs` use `GetQuestIndexForTimer(i)` -> log index
  -> `timersByLogIndex[idx] = secs`; attach in the loop by `i`.
- `Client.INTERFACE` gains `"QuestTimerFrame"` -> `Frame|nil` (`QuestTimerFrame` global on both; nil-safe) for the
  stock swallow.

### Model (`Core/Model.lua`)

- `q.timerRunning = q.timerRemainingSeconds ~= nil and not q.isComplete and not q.isFailed`
- `Categorise`: **first line** -> `if q.timerRunning then return "active" end` (before the complete / in-zone logic).
- `Build`: after the bucket sort, stable re-sort of `byCategory.active` so `timerRunning` quests come first (rank order
  among themselves, rank order among the rest).
- Auto-untrack: skip when `q.timerRunning` (the transition test never fires for a pinned quest anyway; make it explicit).
- `Model.Tick` already re-categorises every 5 s; no change. When the timer expires the game fails the quest and fires
  `QUEST_LOG_UPDATE`/`QUEST_TIMER_UPDATE`, which rebuilds.
- `/vqt dump` prints ` timer=mm:ss` on timed quests.

### Events (`VelocityQuestTracker.lua`)

- Register `QUEST_TIMER_UPDATE` -> `Model.MarkDirty("timer")` (pcall the RegisterEvent: unknown event names raise).

### View (`UI/Blocks.lua`)

`RenderBlock` (incomplete-quest block only; the hand-in card has no timer by definition):

```lua
-- after the title, before the objective rows
if quest.timerRunning then
  local left = math.max(0, quest.timerRemainingSeconds - (now - quest.timerSampledAt))
  b.timer:SetText("Remaining: " .. Blocks.FormatTimer(left))     -- mm:ss | h:mm:ss
  T.SetColour(b.timer, TimerTone(left))                           -- Recent (yellow) | Danger < TimerDangerSeconds
  b.timer:Show(); y = y - T.RowSize - 2
  anyAnim = true                                                   -- ticks every frame via Panel.OnUpdate
else b.timer:Hide() end
```

- `b.timer` is a `T.Text(b, T.RowSize)` (one size up from the title, so a running clock is obvious) created in `AcquireBlock`, centred, anchored under `titleButton`.
- `anyAnim = true` is what makes `Blocks.animating` true, so `Panel.OnUpdate` re-renders each frame while a timer card
  exists. Rendering already runs per frame during segment pops; cost is one `string.format` per timed quest.
- `Blocks.FormatTimer(secs)`: `floor`, `%d:%02d` or `%d:%02d:%02d`.

### Theme (`UI/Theme.lua`)

- New tone `T.Tone.Danger` default `#e0564d`, exposed in Options alongside the other tone colours and retinted by
  the zone-brightness band like the rest.

### Stock tracker (`UI/StockTracker.lua`)

- `Swallow`/`Release` act on **both** `Client.StockTrackerFrame()` and `Client.QuestTimerFrame()` (loop over a list;
  hook each once; sink shared). `Status()` reports both.

### Settings (`UI/Options.lua`, defaults in `VelocityQuestTracker.lua`)

| Key | Default | Meaning |
|---|---|---|
| `TimerDangerSeconds` | 15 | below this the countdown is Danger (red) |
| `Tone.Danger` | `#e0564d` | the red |

## Milestones

- [x] **M1 Client**: timer fields on both flavours + `QuestTimerFrame` interface method; `/vqt dump` shows `timer=`.
- [x] **M2 Model**: `timerRunning`, pin to a card, timed-first sort, `QUEST_TIMER_UPDATE` registered.
- [x] **M3 View**: `Remaining: mm:ss` line, tones, per-frame tick; `Danger` tone in Theme + Options; settings.
- [x] **M4 Stock**: swallow `QuestTimerFrame`.
- [x] **M5 Playtest (Forever)**: "Grace of An'she and Mu'sha" (Mulgore, 2026-11-23) -- clock on the hand-in card, yellow at 0:40.
      Lesson: most timed quests are COMPLETE ON ACCEPT (deliver before it expires), so the first cut, which only ran the
      clock on incomplete quests, drew nothing; `timerRunning` now ignores `isComplete` and the hand-in card carries the line.
- [ ] **M5 Playtest (Era)**: verify `GetQuestTimers` / `GetQuestIndexForTimer` with a collapsed header, and that failure drops the line.

## Open questions

- **Depletion bar** (Forever has `totalTime`): rejected for now in favour of text only; revisit after playtest.
- **Sound/flash at Danger threshold**: not in scope; the red is the signal.
- **Era `GetQuestTimers` with a collapsed header**: `GetQuestIndexForTimer` returns an index that `GetQuestLogTitle` still
  resolves (collapsed headers hide rows in the *frame*, not the API) -- confirm in M5.