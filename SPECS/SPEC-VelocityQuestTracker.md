# SPEC-VelocityQuestTracker: Velocity Quest Tracker

- **Status:** Draft
- **References:**
  - Live mockup and design basis: https://claude.ai/artifact/WGuweex15KrCJn1opPA1SP
  - QuestieDB (data dependency): https://github.com/Questie/QuestieDB
  - WoW QuestLog API index: https://warcraft.wiki.gg/wiki/Category:API_systems/QuestLog

- [ ] Map view prototype: the field alone, fed by QuestieDB spawns, in one zone
- [ ] Actionable block: segment rows, promotion on action, recent-progress timing
- [ ] Turn-in line: Forever quest POIs first, QuestieDB otherwise
- [ ] Line view and hover tabs
- [ ] Other-zone line and settings
- [ ] Playtest tuning: colours over terrain, shape budget, field size, band distances

## Overview

Velocity Quest Tracker is a standalone World of Warcraft addon for Classic Era and Forever that replaces the stock quest tracker. It shows the state of the player's quest work and leaves every decision to the player: what is owed, how much, where it can be done, and where it is handed in.

It is built for a glance during play. Nothing is drawn at rest except the information itself, remaining work is the brightest thing on screen, and rows do not move unless something entered or left.

It is a sibling of Velocity Split Tracker and does not depend on it. It requires the QuestieDB addon for location data.

## Principles

1. **Show state, never instructions.** No route, no "best next", no suggested direction, no auto-selected target.
2. **Attention goes to what is left.** Remaining work is bright. Finished work recedes.
3. **Nothing shifts without cause.** A row keeps its slot. A new entry takes the next slot. Nothing re-sorts on progress.
4. **No chrome at rest.** No frame, header or buttons until hover.
5. **Name the thing in the world.** Mob and objective names are shown in full. Quest names are labels and never carry emphasis.
6. **Everything is derived.** The display is computed from the quest log, the player position and the location data. There is no plan or step pointer.

## Design

### Layout

One panel, 250 px wide, four parts stacked top to bottom. Any part with nothing to show is omitted.

```
 ✓ Dolanaar ▪▪                        1. turn-in line (one per place)
┌──────────────────────────────────┐
│       The Balance of Nature      │  2. actionable block (one per quest)
│ Young Nightsaber    ▪▪▪▪▪▪▫  6/7 │
│ Young Thistle Boar  ▪■▫▫     2/4 │
└──────────────────────────────────┘
┌──────────────────────────────────┐
│  ●                               │  3. nearby work: map view
│        ( ring = middle band )    │     (or line view)
│ ▲▲                     ▲▲▲       │
│ ■■■                    ■         │
└──────────────────────────────────┘
 ▲ Webwood Spider
 ■ Gnarlpine Warrior
 ● Strigid Owl
 +6 in Ashenvale ▪▪▪▪▪▪               4. other-zone line (one per zone)
```

### Visual language

Three tones carry one meaning each. Hex values are the mockup's starting points and are settings.

| Tone | Meaning | Start value |
|---|---|---|
| Bright | Still to do, here | `#f2f2ea` |
| Dim | Done, or a label | `#566058` (done units), `#8d958e` (label text) |
| Yellow | Just happened | `#ffcf4d` |
| Middle | Nearby work not yet started | `#aab1aa` |

Difficulty colour appears only on the small squares of the turn-in and other-zone lines.

Text over terrain uses a 1 px dark shadow. Quest blocks use a faint wash (white at 6% in the mockup); wash colour and alpha are settings.

### Part 1: turn-in line

One line per hand-in place: a check glyph, the place name, and one 6 px square per completed quest to hand in there, coloured by quest difficulty. Individual quest names are not shown.

The place is the sub-zone or settlement name at the turn-in location. Turn-in location comes from the Location layer (below).

### Part 2: actionable block

One block per quest that has at least one actionable objective. The quest name is small, dim and centred at the top.

**Row shape.** Every objective row is identical: name, segmented bar, count, in fixed columns (`1fr | 56 px | 28 px`) so bars and counts align down the list. State changes tone only.

**Segments.** One segment per unit, 4 px tall, 2 px gap. Done segments are dim, remaining segments are bright, the most recently completed is yellow.

**Promotion.** An objective becomes actionable when the player makes progress on it (a kill or loot that advances its count). A setting switches this to proximity (the objective has a spawn in the inner band).

**Slots.** A promoted objective joins its quest's block; a new block is appended below existing blocks. Existing rows and blocks never reorder.

**Completion.** When an objective's last unit lands, its name and count dim with that segment's fade. When every objective of a quest is done, the block is removed after the final fade and the quest is added to the turn-in line.

**Recent-progress timing.**

| Phase | Default | Behaviour |
|---|---|---|
| Pop | 0.28 s | Segment flashes white and swells, settles to yellow |
| Hold | 4 s | Stays yellow |
| Fade | 1 s | Yellow to dim, linear |

Each segment runs its own timer. Hold and fade are settings.

### Part 3: nearby work

Objectives in the current zone that are not actionable. Two views over the same data; the choice is remembered per character.

Objectives are grouped by **source type**: the mob, object or item source the player would look for. Several objectives fed by the same mob share one source type.

#### Map view

A square field as wide as the panel (250 px), north up, player at the centre, no player marker.

- **Bands.** Three concentric distance bands of equal width. Band 2 is drawn as a slightly brighter ring; the hollow centre implies the player position.
- **Directions.** Eight compass sectors of 45°.
- **Cells.** A cell is (sector, band). Marks snap to their cell and stack there.
- **Marks.** One shape per source type (square, circle, triangle up, triangle down, diamond, plus). A mark is one unit owed. A source type keeps its shape while it is in the log.
- **Apportionment.** For each source type, the units still owed are split across cells in proportion to the number of spawns in each cell.
- **Out of range, same zone.** Spawns beyond band 3 are placed flush against the field edge in their direction.
- **Key.** Below the field, one line per source type: shape and full name.

Reading rule: the same shape in two places means either place will do; different shapes mean both are needed.

```
-- pseudocode — illustrative only
function Apportion(owed, spawnsPerCell)      -- spawnsPerCell: cell -> count
    total = sum(spawnsPerCell)
    for cell, n in spawnsPerCell do
        share[cell] = owed * n / total
        marks[cell] = floor(share[cell])
    end
    leftover = owed - sum(marks)
    give one extra mark to the `leftover` cells with the largest fractional share
    return marks                              -- sums exactly to owed
end

function CellFor(playerPos, spawnPos, bandWidth)
    dx, dy = spawnPos - playerPos             -- world yards, north = +y
    dist   = sqrt(dx*dx + dy*dy)
    sector = round(atan2(dx, dy) / 45°) mod 8 -- 0 = N, 2 = E, 4 = S, 6 = W
    band   = floor(dist / bandWidth) + 1      -- 1..3, or EDGE if > 3
    return sector, band
end
```

#### Line view

One line per source type: shape, full name (truncated with an ellipsis, never wrapped), and a 60 px line with one 4 px marker per unit owed, placed by distance from the player in any direction. The left end is the player. Units beyond band 3 sit at the right end.

#### View tabs

On hover of the panel, two small tab buttons (map, lines) appear to the left of this section. If the panel is docked at the left screen edge they appear on the right.

### Part 4: other-zone line

One line per other zone with open quests: `+N in Zone` and one 6 px square per quest, coloured by difficulty.

## Data and events

### Layers

```
 Quest log adapter (per client)  ──┐
 Location layer (QuestieDB, POIs) ─┼──► Model ──► View (blocks, field, lines)
 Position sampler (while moving)  ─┘
```

- **Quest log adapter.** One thin module per client exposing the same shape: quests, objectives, counts, difficulty, completion. Classic Era uses the index-based quest log calls; Forever uses `C_QuestLog`. The view is shared.
- **Location layer.** Answers two questions: where are the spawns for this objective, and where is this quest handed in.
- **Position sampler.** Supplies the player's world position and current cell boundaries.

### Location sources

| Question | Source |
|---|---|
| Mob, object and item-source spawns | Always QuestieDB |
| Turn-in location | Forever quest POI when the client provides one; otherwise QuestieDB (the quest's finisher NPC or object) |

On Classic Era the client does not provide usable quest POIs, so QuestieDB answers both questions there.

```
-- pseudocode — illustrative only
function TurnInFor(questID)
    if client == FOREVER then
        poi = ForeverPOI(questID)             -- only meaningful once the quest is complete
        if poi then return poi.mapID, poi.x, poi.y end
    end
    return QuestieFinisher(questID)           -- first spawn of the finisher NPC/object
end
```

### Update triggers

All quest state is event-driven. Events mark the model dirty and it rebuilds once on the next frame, since quest-log events arrive in bursts.

| Trigger | Effect |
|---|---|
| Quest accepted / removed / turned in | Rebuild quests; add or drop source types |
| Objective count changed | Diff against last known counts; the changed unit pops; promote the objective if not yet actionable |
| Zone changed | Recompute which quests are nearby and which are other-zone |
| Player crossed a cell boundary | Recompute cells and apportionment for the map and line views |
| Hold timer fired | Start the segment's fade |

Player position has no change event. The sampler runs only between the client's started-moving and stopped-moving events, at a low rate, and reports only when a boundary is crossed, so the views redraw on crossings and not on samples. Category changes are deferred until out of combat.

## API surface

### WoW client

Events to register (verify names and payloads on both clients before fixing the adapter):

- `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`
- `QUEST_LOG_UPDATE` (bursty; coalesce), `QUEST_WATCH_UPDATE`, `UNIT_QUEST_LOG_CHANGED`
- `QUEST_POI_UPDATE` (Forever)
- `ZONE_CHANGED`, `ZONE_CHANGED_NEW_AREA`
- `PLAYER_STARTED_MOVING`, `PLAYER_STOPPED_MOVING`
- `PLAYER_REGEN_ENABLED` (left combat)

Quest POIs (Forever):

```
quests = C_QuestLog.GetQuestsOnMap(uiMapID)   -- QuestPOIMapInfo[]
-- fields used: questID, mapID, x, y, inProgress, numObjectives, isQuestStart
```

- Reference: https://warcraft.wiki.gg/wiki/API_C_QuestLog.GetQuestsOnMap
- The function is listed for both clients (added 1.15.0 on the vanilla client, 1.60.1 on Forever). It returns one point per quest, not spawn points.
- To confirm in game: `/dump C_QuestLog.GetQuestsOnMap(C_Map.GetBestMapForUnit("player"))` with an open quest and again with a completed one.

Position and maps: `C_Map.GetBestMapForUnit`, `C_Map.GetPlayerMapPosition`, and a map-to-world conversion (`C_Map.GetWorldPosFromMapPos`) to turn per-zone map coordinates into yards.

### QuestieDB

- Repository: https://github.com/Questie/QuestieDB
- CurseForge: https://www.curseforge.com/wow/addons/questiedb
- Licence: GPLv3. Supports Classic Era and Forever. Since Questie 12.0.0 it is a separate addon from Questie.
- Declared in the TOC as a required dependency: `## RequiredDeps: QuestieDB`. The tracker reads it at run time and bundles none of its data.

Consumer calls shown in the QuestieDB README:

```
QuestDB.name(questID)                  --> "Sharptalon's Claw"
QuestDB.Get(questID, "requiredLevel")  --> 20
NpcDB.spawns(npcID)                    --> { [zoneID] = { {x, y}, ... } }
LibQuestieDB.GetRegistrar("MyAddon")
```

Needed from it (field names follow Questie's schema; verify against the QuestieDB source):

| Need | Expected source |
|---|---|
| Objective to NPC, object or item IDs | Quest `objectives` field |
| Item objective to drop sources | Item `npcDrops`, `objectDrops` |
| Spawn points | NPC and object `spawns`: zone ID to list of `{x, y}` in zone-map percent |
| Turn-in NPC or object | Quest `finishedBy` |
| Quest level for difficulty colour | Quest `questLevel` |

Spawn coordinates are per-zone map positions. They are converted to world yards once per source type per zone and cached.

### Inter-addon

The tracker exposes an optional focus input: a set of quest IDs supplied by another addon. When a focus set is present, only those quests are shown. Velocity Split Tracker can publish its current step this way through a callback; neither addon requires the other. Quest IDs are the only shared contract.

## Settings

- Promotion mode: on action (default), by proximity
- Nearby view: map (default), lines
- Hold and fade durations
- Band width in yards
- Tone colours, block wash colour and alpha
- Panel width and position

## Open Questions

- **Leaving the block.** How an actionable objective returns to nearby work: no progress for some minutes, distance from last progress, displacement when the block is full, or never until complete. Current lean: idle time, with displacement as a cap.
- **Band width.** The yard distance of each band. Needs a playtest; it also sets how much wider than the minimap the field sees.
- **Shape budget.** About six shapes stay distinct at 7 px. Fallback when more source types are in range: a second tone, or shapes for the nearest six and plain dots for the rest.
- **Large counts.** Segment bars above about 7 units, and map stacks above about 10 marks.
- **Objectives with no count.** "Speak with" and "Explore" objectives finish in one step and would go from nearby work straight to the turn-in line.
- **Count text.** Whether to show remaining ("1") in place of done over total ("6/7").
- **One difficulty scale** for the turn-in and other-zone squares.
- **Field size.** Whether the map shrinks while actionable blocks are present.
- **QuestieDB gaps.** New Forever quests missing from QuestieDB have no spawns; decide what the tracker shows for them.
- **Turn-in POI on Forever.** Confirm in game that a completed quest's POI sits on the turn-in NPC.
- **Many turn-in places or many other zones.** Whether lines cap and fold.

## Alternatives Considered

- **Bundling a data set** (pfQuest's MIT-licensed data, or ForeverDB). Removes the dependency but adds data upkeep to the addon. QuestieDB covers both clients and is already installed for most players.
- **Recording locations during play.** Always available and fully owned, but empty on first contact with a quest. It remains a candidate for filling QuestieDB gaps.
- **Forever POIs for objectives.** They give one point per quest, which is not enough for the proportional spawn split, so they are used for turn-ins only.
- **Tracker picks where each objective is done** (planned marks plus alternative marks). It breaks down when objectives share locations, and it issues an instruction. A shape per source type lets the player make the call.
- **Field that rotates with the player's facing.** More literal left and right, but every mark moves on every turn.
- **Wide elliptical field, or an east-west strip.** Smaller, but distorts or drops north and south. The square field with a true circle was preferred.
- **Ordering by most recent progress.** It reorders on kills. The yellow segment already shows recency.
- **Promotion by proximity as the default.** It fills the block with objectives the player is only passing. It remains available as a setting.
