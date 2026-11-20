# Velocity Quest Tracker

A quest tracker for Classic Era and WoW Forever that shows the **state** of your quest work and leaves every decision to you.

- Remaining work is bright; finished work recedes; the unit you just completed glows yellow for a few seconds.
- Rows keep their slot. Nothing re-sorts on a kill.
- No frame, header or buttons at rest.
- Quests you have acted on recently sit in a block at the top; the rest of the zone's work is listed as nearby; other zones fold to one line each.

`/vqt` toggles the panel, `/vqt options` opens settings, `/vqt status` prints version and client.
The panel is positioned with the game's Edit Mode.

Sibling of [Velocity Split Tracker](https://github.com/WoWAddons-Kuro/VelocitySplitTracker); neither requires the other.
Location data (spawn distances, turn-in places) comes from [QuestieDB](https://www.curseforge.com/wow/addons/questiedb) when it is installed.

Design: `SPECS/SPEC-VelocityQuestTracker.md`. Build plan: `SPECS/PLAN-VelocityQuestTracker.md`.