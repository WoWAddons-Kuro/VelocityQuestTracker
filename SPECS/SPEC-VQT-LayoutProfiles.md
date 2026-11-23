# SPEC-VQT-LayoutProfiles: panel placement saved per layout profile

- **Status:** Implemented 2026-11-22 (M1); in-game tests M2/M3 pending. Library extracted to its own repo `LibEditModeProfileExtension\` (top level), VQT declares it as a RequiredDep.
- **Parent:** `PLAN-VelocityQuestTracker.md` (Positioning row), `UI\EditMode.lua`, `UI\ItemButtons.lua`
- **Driver:** VelocitySettingsSync (today `ChatSync`) switches the Edit Mode HUD layout at login
  (`ChatSync.lua` ~L451, `C_EditMode.SetActiveLayout` / `EditModeManagerFrame:SelectLayout`). When that
  happens the tracker must land where it was saved **for that layout**, on any character.

## Decisions (owner, 2026-11-22)

| Topic | Decision |
|---|---|
| Profile contents | `panel` placement and `LockPosition` only. Map/Range view stays per-character view state. |
| Migration | First login under a layout donates the character's existing `CharDB.panel` to that profile; `CharDB.panel` is then nil'd. `settings.LockPosition` seeds every profile's `lockPosition` once (then the setting is retired). |
| New profile | Always inherits a copy of the current profile (Edit Mode "new layout" and the Era "New profile" button alike). |
| Options | Era micro-profile block at the BOTTOM of the options page, above a new **Reset** section with **Reset layout** (current profile's panel position) and **Reset all data** (confirmation; wipes both SavedVariables and reloads). |
| Library | Vendored **`LibEditModeProfileExtension-1.0`** (LibStub). Owns the storage shape + both providers; VQT is its first consumer, KondoBags next. Lives in `VelocityQuestTracker\VelocityQuestTracker\Libs\LibEditModeProfileExtension\` for now; promoted to its own repo when a second consumer appears. |
| API shape | **Identical to Blizzard's `C_EditMode` layouts surface, vended at `inst.C_EditMode`** (never `_G.C_EditMode` -- addons sniff that for "is Retail"). `GetLayouts / SetActiveLayout / SaveLayouts / OnLayoutAdded / OnLayoutDeleted / IsValidLayoutName`, `EditModeLayoutInfo { layoutName, layoutType, systems }`. Forwards to the real API on modern clients; legacy store in the consumer's SV otherwise, `EDIT_MODE_LAYOUTS_UPDATED` delivered via `EventRegistry:TriggerEvent`. Long-term goal: a separate "Edit Mode for legacy clients" addon registers one shared legacy provider (`lib:SetLegacyProvider`) and runs LibEditMode on top. Ground truth: `AddonManagement\_EXTERNAL_APIS\wow_edit_mode_layouts_api.md`. |
| Legacy presets | None by default (index space == saved list, first entry `"Default"`). `lib.LegacyPresets` reserved for the future addon. |
| Active layout on legacy | Stored as a NAME per character (`CharDB.editModeActiveLayout`), not an index: another character deleting a layout would shift indices. |
| Create | Legacy and modern alike: the new record is a deep copy of the current one (`Instance:Current()` falls back to `lastName`'s record, then defaults). |
| Delete (manual) | Refuses `"Default"` and the profile this character is on. |
| Placeholder record | On Forever the layout name may arrive after `PLAYER_LOGIN`; until then the instance reports `"Default"` unresolved and `ApplyToPanel` may create a throwaway `profiles["Default"]`. Harmless; migration waits for `IsResolved()`. |

## Goal

Placement is **always** read from and written to a profile record keyed by a profile name, stored
account-wide. The only flavour difference is *who tells us the current profile name and when it changes*:

| Client | Profile name source | Change event | UI |
|---|---|---|---|
| Forever (has Edit Mode) | active Edit Mode layout name | `EDIT_MODE_LAYOUTS_UPDATED` + `EditMode.SavedLayouts` (the lib listens itself; it does NOT depend on LibEditMode) | none of ours; the game's layout dropdown IS the profile picker |
| Classic Era (no Edit Mode) | per-character selection, default `"Default"` | the lib's own `Select()` | Options block: dropdown + New + Delete |

## Library: `LibEditModeProfileExtension-1.0`

A profile *name* provider plus a storage helper. The consumer hands it two SavedVariables tables; the lib
owns `account.profiles` and `char.profile`. Everything else in those tables is left alone.

```lua
local LCEEMP = LibStub("LibEditModeProfileExtension-1.0")
local profiles = LCEEMP:New({
  account   = VelocityQuestTrackerDB,      -- gets .profiles = { [LCEEMP_ProfileName] = LCEEMP_ProfileRecord }
  char      = VelocityQuestTrackerCharDB,  -- gets .profile = LCEEMP_ProfileName (manual provider only)
  defaults  = { ... },                     -- deep-copied into a brand-new record (when no copy source)
  onChanged = function(newName, oldName) end,   -- after the current record may have changed identity
})

profiles:Source()        -> "editmode" | "manual"     -- chosen at New(): C_EditMode and EditModeManagerFrame present -> editmode
profiles:Name()          -> LCEEMP_ProfileName          -- never nil after New()
profiles:Current()       -> LCEEMP_ProfileRecord        -- created on demand (copy of previous current, else defaults)
profiles:List()          -> { LCEEMP_ProfileName, ... } -- sorted; editmode: game layout names (presets first)
profiles:Select(name)    -- manual only; editmode -> false (the game owns it)
profiles:Create(name)    -- manual only; copies Current() then selects it; false if exists/empty
profiles:Delete(name)    -- manual only; refuses "Default" and the current one
profiles:ResetCurrent()  -- Current() := deep copy of defaults; fires onChanged(name, name)
```

### Edit Mode provider (inside the lib)

- Name = `layoutName` of `layoutInfo.layouts[activeLayout]` in the **merged** index space (presets first;
  `EditModeManagerFrame.layoutInfo` when present, else `EditModePresetLayoutManager:GetCopyOfPresetLayouts()`
  + `C_EditMode.GetLayouts()`); same resolution ChatSync uses (`EditModeLayouts()` ~L274).
- `EDIT_MODE_LAYOUTS_UPDATED(layoutInfo)` -> recompute name; if changed -> `onChanged`.
- `EventRegistry 'EditMode.SavedLayouts'` -> diff the saved list against the lib's cache: **create** (copy
  `Current()` into the new name -- the game switches to it right after, which then fires onChanged),
  **rename** (move the record), **delete** (drop the record).
- At `New()` the name is resolved immediately if the manager has layout info; otherwise stays `"Default"`
  until the first `EDIT_MODE_LAYOUTS_UPDATED` (the client fires it at login).

### Manual provider (inside the lib)

- Name = `char.profile or "Default"`. `"Default"` record always exists.

## VQT integration

```lua
-- LCEEMP_ProfileRecord for VQT
{ panel = VQT_PanelPlacement|nil,   -- { point = "TOPLEFT"|"TOPRIGHT", x, y, placed = true }
  lockPosition = boolean }           -- default true
```

- `NS.Profiles` = the lib instance, created in `InitDB` (ADDON_LOADED) with `onChanged -> EditMode.OnProfileChanged`.
- `EditMode.Placement()` -> `NS.Profiles:Current().panel`. `IsPositionLocked()` -> `Current().lockPosition ~= false`.
- `EditMode.OnProfileChanged()` -> `ApplyToPanel()` (re-syncs the secure item-button layer), `ApplyLock()`, `Options.Refresh()`.
- `LockPosition` checkbox (Options + LibEditMode dialog) writes `Current().lockPosition`; `NS.OnSettingChanged("LockPosition")` path kept.
- `ResetPosition()` -> `Current().panel = nil; ApplyToPanel()`.
- `Status()` appends `profile "<name>" (<source>)`.
- Options, Era only: **Layout profile** section (dropdown, New profile..., Delete profile). Forever: one-line
  note "Panel position and lock are saved per Edit Mode layout."
- Options, both: **Reset** section replaces the old "Panel" section: **Reset layout**, **Reset all data** (StaticPopup confirm -> wipe both SVs -> `ReloadUI()`).
- `/vqt profile [list | <name>]` (manual source only).

## Migration (one-time, in InitDB after the lib exists)

1. `CharDB.panel` present: if `Current().panel == nil` copy it in. Nil `CharDB.panel`.
2. `settings.LockPosition ~= nil`: if `Current().lockPosition == nil` copy it in. Nil `settings.LockPosition`
   (removed from `DEFAULT_SETTINGS`).
Step 1 runs on the Edit Mode source only once the real layout name is known, so it is executed inside the
first `onChanged` as well as at init (idempotent: it only fills a nil).

## Files

| File | Change |
|---|---|
| `Libs\LibEditModeProfileExtension\LibEditModeProfileExtension-1.0.lua`, `embed.xml`, `VENDORED.txt` | new |
| `UI\EditMode.lua` | Placement/lock from profile; `OnProfileChanged`; status |
| `UI\Options.lua` | Layout profile section (Era) / note (Forever); Reset section |
| `VelocityQuestTracker.lua` | create lib instance in InitDB; migration; `/vqt profile`; drop `LockPosition` default |
| TOCs | load the lib after LibStub |
| `SPECS\PLAN-VelocityQuestTracker.md` | SavedVariables / Positioning rows |

## Milestones

- [ ] M1 Library (both providers) + VQT rewire + migration + Options sections
- [ ] M2 Forever test: dropdown switch, ChatSync login switch, new-from-copy, rename, delete
- [ ] M3 Era test: create/select/delete, `/vqt profile`
- [ ] M4 PLAN/README updates