# PLAN-VelocityQuestTracker: build plan and decisions

- **Status:** Active (2026-11-20)
- **Design of record:** `SPEC-VelocityQuestTracker.md` (behaviour) and `Velocity Quest Tracker.html` (visual). This file holds the
  decisions taken in review and the milestone order; it does not restate the design.

## Decisions (owner review, 2026-11-20)

| Topic | Decision |
|---|---|
| Repo layout | Packager-style like KondoBags: repo root holds `.pkgmeta`, `README.md`, `CHANGELOG.md`, `LICENSE`, `SPECS\`, `Assets\`; the addon lives in `VelocityQuestTracker\VelocityQuestTracker\` (TOC at `D\D\D.toc`). `.pkgmeta` `package-as: VelocityQuestTracker`, `move-folders: VelocityQuestTracker/VelocityQuestTracker: VelocityQuestTracker`. |
| Slash | `/vqt` |
| SavedVariables | `VelocityQuestTrackerDB` (account: settings, tones) and `VelocityQuestTrackerCharDB` (per character: nearby view choice, placement). Any per-character table inside the account DB is keyed by `Client.PlayerKey()` = `UnitGUID("player")`. |
| Positioning | Modern Edit Mode via vendored **LibEditMode** (copy from `KondoBags\KondoBags\Libs\LibEditMode`, pattern `KondoBags\KondoBags\UI\EditMode.lua`). Initial anchor = the stock tracker's position (`ObjectiveTrackerFrame` on Forever, `QuestWatchFrame` on Era) read once at first login, then saved. |
| Options panel | Pattern of `GotJunk\GotJunk.lua` (`Section` / `Check` / `Slider` helpers, `Settings.RegisterCanvasLayoutCategory` with `InterfaceOptions_AddCategory` fallback). First two checkboxes, both default on: **Enable Velocity Quest Tracker**, **Lock position (edit with Edit Mode)**. |
| Stock tracker | Disappears when enabled. Method = KondoBags sink pattern: re-parent the stock frame into a hidden `VelocityQuestTrackerStockSink` frame; never unregister its events or replace its functions. Toggling the enable checkbox re-parents back. Owner to playtest; fallback is `:Hide()` + `HookScript("OnShow")`. |
| Which quests | **Every quest in the log.** Focus-set override (inter-addon) still applies. |
| Tracked == active (2026-11-20) | Ticking "track" in the stock quest log is activity (Touch). A quest leaving active (or its hand-in card) is untracked in the stock log when **Auto-untrack inactive quests** (default on) is ticked. `Client.SetWatched` per flavour. `QUEST_WATCH_LIST_CHANGED` is the event that carries the checkbox on Forever. |
| Actionable vs nearby | **Recent-activity timer AND in-zone.** Accepting, tracking, progressing, or completing a quest sets `Quest.lastActivityAt = GetTime()`. A quest is **active** (block) while `GetTime() - lastActivityAt < ActiveWindowSeconds` (default 300 s) **and** its remaining work (or, when complete, its hand-in place) is in the current zone; a recent quest for another zone sits under `+N in Zone`. Otherwise **nearby** (line view) or **other-zone**. Memory persists per character (`VelocityQuestTrackerCharDB.model`, epoch-stamped). Proximity promotion deferred to M4. |
| Completion | Derived from the objectives (`Client.DeriveComplete`): every objective done. The log's IsComplete flag is only trusted when there are no counted objectives. Forever reported quest 399 complete with `0/1` outstanding. |
| Difficulty colour | `GetQuestDifficultyColor(questLevel)` (client palette) for turn-in and other-zone squares. Resolves the spec's "one difficulty scale" question. |
| Count text | Keep `done/total` (`6/7`) for v1. |
| No-count objectives | One segment; completing it is progress like any other. |
| Large counts | Segments: **10 per segment row**, wrapping to further rows (two segment rows fit in one text line; 20 covers almost every quest). Never collapse to a proportional bar. Map stacks: cap at 10 marks per cell (M3). |
| Hiding done work | Two settings, both default off: **Hide completed segments** (done units are not drawn, the bar shows only what is left) and **Hide fully completed rows** (an objective row at `have == need` leaves the block after its final fade). |
| Font | `Fonts\ARIALN.TTF`, 13 px rows, 11 px labels (mockup 14/12). |
| Shared code with Split Tracker | None. Each addon owns its `Client\` layer and `Theme` (workspace rule). |
| Objective -> source IDs | Do what Questie does. Pull Questie's own objective-matching code (installed at `_forever_\Interface\AddOns\Questie`) and mirror it; QuestieDB `Quest.objectives` is already in Blizzard objective order. Research item for M3, not M1. |
| Position smoothing (map view) | Pins move as little as possible. Cell = (sector of 8, band of 3). Sector change requires crossing the boundary by a hysteresis margin (asymmetric: enter at +7.5 deg past the boundary, leave at -2.5 deg); band change likewise (+-10 % of band width). Pin moves are eased over ~0.4 s, not snapped. Detailed in M3. |
| Git | Assistant does `git init` + first commit. Owner handles webhooks row, publish, release. |

## Nearby-work scale and marks (owner review, 2026-11-20)

Zone sizes in yards (HereBeDragons `mapData`, Classic): Redridge 2170 x 1447, Westfall 3500 x 2333,
Darkshore 6550 x 4367, Elwynn 3470 x 2313. The 600 yd spark-line cap is 10-20 % of a zone; from a
town every marker pins to the right end and carries no information. **Decision (owner): the nearby
range is `max(600 yd, farthest spawn of the quests being shown)`.** It follows the log, not the zone.

| Topic | Decision |
|---|---|
| Range | `VQT_Nearby_RangeYards = max(VQT_Nearby_MinRangeYards (600), farthest spawn distance among the nearby quests' objectives in the current zone)`. Spark line right end = that; map view band width = range / 3. Every nearby spawn is therefore inside the field; only cross-zone spawns pin to the edge. |
| Range stability | The farthest-spawn term is recomputed only when the **set of nearby objectives changes** (quest accepted / completed / promoted / zone change), not on every position sample. Between those events the range is fixed, so walking slides markers along a steady scale instead of rescaling the whole line. The 600 floor stops a single close objective from collapsing the scale. |
| Spark-line scale | Square-root distance (`sqrt(d / range)`) so the near half of the line covers the near quarter of the zone; linear bunched everything far. Verify in playtest; a setting toggles linear. |
| Marks per direction (replaces one-mark-per-unit) | Nearby marks show only for **inactive** quests (the active block already carries counts). One mark per **(source type, sector)** -- "there are spiders to the NE", not "five spiders". Sector = 8 compass directions; band ignored for marks, used only for the ring/radial placement. |
| Mark size by weight | Mark size scales with `spawns in that sector / spawns in the zone` for that source type: `size = base * (0.75 + 0.5 * sqrt(share))`, clamped 5-9 px at 250 px field. The biggest mark is where most of that mob lives. Pure visual weight; no number is drawn. |
| Apportion() | Retired. The spec's unit apportionment assumed one mark per unit owed; with one mark per sector the count enters only through size. |
| Radial placement | The mark sits at the **spawn-weighted mean distance** of that sector's spawns (clamped to band 3), so a type that is both near and far reads as "medium". |
| Hysteresis | Sector boundary +-7.5 deg (enter) / -2.5 deg (leave) per PLAN "Position smoothing"; radial position eased 0.4 s. |
| Line view | Keeps one marker per unit owed (the spec's shape), scaled by the new range. |

```lua
-- pseudocode: marks for the map field (one source type)
function MarksFor(sourceType, playerPos, zoneRange)
  local bySector = {}                              -- sector -> { n = count, sumDist = yards }
  for _, s in ipairs(spawnsInZone(sourceType)) do
    local sector, dist = CellFor(playerPos, s)     -- 0..7, yards
    bySector[sector] = bySector[sector] or { n = 0, sumDist = 0 }
    bySector[sector].n = bySector[sector].n + 1; bySector[sector].sumDist = bySector[sector].sumDist + dist
  end
  local total = #spawnsInZone(sourceType)
  for sector, b in pairs(bySector) do
    emit { sector = sector, radius = min(b.sumDist / b.n, zoneRange), size = 0.75 + 0.5 * sqrt(b.n / total) }
  end
end
```

## File layout (target)

```
VelocityQuestTracker\                       repo root
  .pkgmeta  .gitignore  LICENSE  README.md  CHANGELOG.md
  SPECS\   (this folder)
  Assets\  (icon, screenshots; ignored by packager)
  VelocityQuestTracker\                     the addon
    VelocityQuestTracker.toc                Interface 16001 (Forever)
    VelocityQuestTracker_Vanilla.toc        Classic Era (generated by publish.cs; committed like siblings)
    Libs\LibStub\  Libs\LibEditMode\
    Client\Client.lua                       Client.INTERFACE + NS.ClientFlavours
    Client\Client_ClassicEra.lua            index-based quest log (GetNumQuestLogEntries, GetQuestLogTitle, GetQuestLogLeaderBoard)
    Client\Client_Forever.lua               C_QuestLog.* / C_QuestLog.GetQuestObjectives
    Client\Client_Select.lua                binds NS.Client, warns on interface drift
    Core\Util.lua                           Print, colour helpers, timers
    Core\Model.lua                          quest/objective model, diffing, activity timers, dirty/rebuild
    Core\Zones.lua                          current zone + per-quest zone attribution (M1: quest log header zone; M3: spawns)
    Core\Location.lua                       (M3) QuestieDB adapter: spawns, finisher, cells
    Core\Position.lua                       (M3) sampler, cell boundaries, hysteresis
    UI\Theme.lua                            tones, font, widget factories
    UI\Panel.lua                            the 250 px panel; parts 1-4 stacked, omitted when empty
    UI\Blocks.lua                           part 2: quest blocks, rows, segments, pop/hold/fade
    UI\Nearby.lua                           part 3: M1 list; M3 map + line views + hover tabs
    UI\Lines.lua                            parts 1 and 4: turn-in line, other-zone line
    UI\EditMode.lua                         LibEditMode placeholder, initial anchor from stock tracker
    UI\StockTracker.lua                     sink for the Blizzard tracker
    UI\Options.lua                          settings panel
    VelocityQuestTracker.lua                bootstrap, DB init, slash, event wiring
```

## Client interface (minimum, M1)

```lua
Client.INTERFACE = {
  "PlayerKey", "PlayerDisplayName", "PlayerFirstName",
  "Quests",            -- -> { VQT_Quest... } snapshot of the whole log
  "StockTrackerFrame", -- -> Frame|nil (ObjectiveTrackerFrame | QuestWatchFrame)
  "CurrentZoneName",   -- -> string
}
-- VQT_Quest  = { questID, title, level, isComplete, isWatched, zoneName (log header), objectives = { VQT_Objective... } }
-- VQT_Objective = { index, text, type ("monster"|"item"|"object"|"event"|...), have, need, done }
```

Era: `GetNumQuestLogEntries`, `GetQuestLogTitle(i)` (header rows give `zoneName`), `GetQuestLogLeaderBoard(j, i)`, `GetQuestLogSpecialItemInfo`. Forever: `C_QuestLog.GetNumQuestLogEntries`, `C_QuestLog.GetInfo(i)`, `C_QuestLog.GetQuestObjectives(questID)`, `C_QuestLog.IsComplete`, `C_QuestLog.GetQuestWatchType`. Verify names in game on both clients before freezing.

## Milestones

### M1 - Everything without QuestieDB (bring-up)

Goal: the panel on screen, correct and stable, over real quest-log data on Forever and Era.

- [ ] Repo skeleton: layout above, `.pkgmeta`, TOCs, LibStub + LibEditMode vendored, `git init`, first commit
- [ ] `Client\` layer for both flavours; `/vqt dump` prints the snapshot for verification
- [ ] `Core\Model.lua`: build from snapshot; diff counts against last snapshot; per-objective `recentUnits` with timestamps; per-quest `lastActivityAt`; `isActionable()`; dirty flag + one rebuild per frame via `C_Timer.After(0)`
- [ ] Events: `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`, `UNIT_QUEST_LOG_CHANGED`, `QUEST_WATCH_UPDATE`, `ZONE_CHANGED*`, `PLAYER_REGEN_ENABLED`, `PLAYER_LOGIN`
- [ ] `UI\Theme.lua`: tones from spec table, 1 px shadow, factories
- [ ] `UI\Blocks.lua` (part 2): block per actionable quest, rows in `1fr | 56 | 28` columns, segments 4 px tall / 2 px gap, pop 0.28 s -> hold -> fade 1 s per segment, row dims on completion, block removed after final fade
- [ ] `UI\Lines.lua` part 1: turn-in line. M1 has no finisher location, so one line **per quest-log header zone** of the completed quest; squares coloured by difficulty. M3 swaps the place name for the finisher sub-zone
- [ ] `UI\Lines.lua` part 4: other-zone line per header zone != current zone
- [ ] `UI\Nearby.lua` M1: the spec's **line view** (shape, full name, 60 px spark line, one 4 px marker per unit owed), one line per objective of each in-zone not-actionable quest. No location data yet, so every marker sits at the same placeholder distance (mid-line). M2 makes the distances real
- [ ] Slot stability: blocks and rows keep insertion order; new entries append; nothing re-sorts on progress
- [ ] `UI\StockTracker.lua`: sink pattern; re-parent back on disable
- [ ] `UI\EditMode.lua`: placeholder, initial anchor from stock tracker, lock checkbox honoured
- [ ] `UI\Options.lua`: Enable, Lock position, **Hide completed segments** (done units not drawn), **Hide fully completed rows** (rows at `have == need` removed after their fade), Active window seconds (60-900), Hold, Fade
- [ ] `/vqt` toggles, `/vqt options`, `/vqt status`, `/vqt dump`
- [ ] Playtest on Forever and Era; fix adapter shape differences

### M2 - QuestieDB first contact: real spark-line distances

- [x] Research: read `LibQuestieDB` contract 4 (`Types\*.t.lua`, `src\api.lua`), Questie's objective-to-ID matching, `C_Map.GetWorldPosFromMapPos` on Era; write findings to `AddonManagement\_EXTERNAL_APIS\questiedb_contract_4.md`
- [x] `Core\Location.lua`: spawns per objective, zone-percent -> yards cache (`GetWorldPosFromMapPos` is present on Era, no fallback needed)
- [x] QuestieDB is a required dependency: `.pkgmeta` `required-dependencies: - questiedb: 1696795`, TOC `## RequiredDeps: QuestieDB`; `publish.cs` installs missing required dependencies into each AddOns root
- [x] Hand-in card (owner request 2026-11-20): a complete quest stays in part 2 as a card (check, finisher place, square) while recently active, then drops to the turn-in line with a 2 s yellow outline on its square. Becoming complete counts as activity, so errand quests accepted complete show the card too
- [x] Other-zone / nearby attribution from the zones of the REMAINING work (QuestieDB spawns), fallback to the log header. Turn-in place = finisher sub-zone (pulled forward from M3)
- [ ] `Core\Position.lua`: sampler between started/stopped-moving (fallback ticker); distance per spawn; spark-line markers placed by real distance, beyond band 3 at the right end
- [ ] `VelocityQuestTracker.SetFocus(questIDs|nil)` public API; Split Tracker optional publisher
- [ ] Combat deferral of category moves
- [ ] Tone/wash settings

### M3 - Zone-scaled range, map view

- [ ] `Core\Position.lua`: `NearbyRangeYards(snapshot)` = max(600, farthest nearby spawn), recomputed on objective-set change only; replaces `Nearby.SparkRangeYards`
- [ ] Line view: sqrt distance scale (setting to toggle linear)
- [ ] `Core\Position.lua`: `CellFor` (sector, dist) with hysteresis; `MarksFor` per the pseudocode above
- [ ] `UI\MapView.lua`: square field, band-2 ring, one mark per (source type, sector) sized by spawn share, eased radial moves, cross-zone edge pins, key below
- [ ] Hover tabs (map / lines) on the panel, side chosen by the same screen-half test as the hover card; per-character view choice (`CharDB.nearbyView`)
- [x] Finisher per quest from QuestieDB (done in M2)
- [ ] Turn-in line: Forever POI first (QuestieDB finisher is in place)
- [x] Other-zone attribution by remaining spawns (done in M2)
- [ ] QuestieDB gap behaviour (quest missing -> M1 list row)

### M4 - Deferred

- [ ] Promotion by proximity (setting)
- [ ] Role of the watched flag
- [ ] Shape budget fallback (>6 source types)
- [ ] Field shrink while blocks present
- [ ] Fold/cap for many turn-in places or zones

## Open Questions (carried)

- Band width in yards (playtest, M3)
- Colours over terrain (playtest, M1 onward)
- Whether `ActiveWindowSeconds` should pause while the player is away from the objective's zone