# Changelog

## Unreleased

### M1 - bring-up (no location data)
- Four-part panel: turn-in lines, actionable blocks (segmented bars, 10 per row wrapping, pop/hold/fade per unit), nearby-work line view, other-zone lines.
- Stock quest tracker swallowed into a hidden sink while enabled (re-parent back on disable; re-swallowed after Edit Mode).
- Edit Mode placement via LibEditMode; first-run anchor copies the stock tracker position.
- Options: Enable, Lock position, Require Shift to interact, Hide completed segments, Hide fully completed quest objectives, Auto-untrack inactive quests, Active window, Hold, Fade.
- `/vqt`, `/vqt options|status|dump|loc <id>|touch <id>|focus <ids|clear>|reset`.

### M2 - QuestieDB
- QuestieDB (contract 4) is a required dependency. Objective -> NPC/object/item sources, spawns in world yards, finisher per quest.
- Nearby vs other-zone attribution from the zones of the REMAINING work; turn-in place is the finisher sub-zone.
- Position sampler (moves only while moving); spark-line markers placed at real distances (600 yd = right end).

### Behaviour
- Active block is IN-ZONE only: a tracked/recent quest for another zone is listed under that zone.
- Tracked == active: ticking track in the quest log makes a quest active; leaving active untracks it (setting).
- Complete quest stays as a hand-in card (check, place, square) while active, then drops to the turn-in line with a 2 s outline.
- Model memory (activity timers, slot order, counts) persists per character across /reload.
- Completion is derived from objectives, not the log's IsComplete flag (Forever reported 399 complete with 0/1 outstanding).
- Block titles: hover brightens, click opens the quest log to the quest.