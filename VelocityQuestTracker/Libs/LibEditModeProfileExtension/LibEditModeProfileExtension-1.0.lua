-- LibEditModeProfileExtension-1.0
--
-- "Edit Mode layouts as the profile system", on every client.
--
-- Modern clients (Retail, WoW Forever) have C_EditMode and a per-character ACTIVE layout chosen from an
-- account-wide list. An addon that keys its positions by layout name gets profile switching for free, and
-- anything that switches the layout (the game's dropdown, VelocitySettingsSync at login) moves the addon
-- too. Legacy clients (Classic Era, MoP Classic) have no Edit Mode at all.
--
-- This library vends the SAME API shape as Blizzard's C_EditMode layouts surface, under its own name:
--
--   inst.C_EditMode.GetLayouts()            -> EditModeLayouts { layouts = { EditModeLayoutInfo }, activeLayout }
--   inst.C_EditMode.SetActiveLayout(index)
--   inst.C_EditMode.SaveLayouts(layouts)
--   inst.C_EditMode.OnLayoutAdded(index, activateNewLayout, isLayoutImported)
--   inst.C_EditMode.OnLayoutDeleted(index)
--   inst.C_EditMode.IsValidLayoutName(name) -> bool
--   EditModeLayoutInfo = { layoutName, layoutType = Enum.EditModeLayoutType.*, systems = {} }
--
-- On a modern client every call forwards to the real C_EditMode. On a legacy client it runs against a store
-- in the consumer's SavedVariables, and EDIT_MODE_LAYOUTS_UPDATED is delivered through EventRegistry
-- (EventRegistry:TriggerEvent("EDIT_MODE_LAYOUTS_UPDATED", layoutInfo, false)) -- the same channel the real
-- event arrives on via EventRegistry:RegisterFrameEventAndCallback. Ground truth for the shape:
-- AddonManagement\_EXTERNAL_APIS\wow_edit_mode_layouts_api.md.
--
-- The library NEVER installs _G.C_EditMode or EditModeManagerFrame: addons sniff those for "is this Retail".
-- A future "Edit Mode for legacy clients" addon can register a shared legacy provider (lib:SetLegacyProvider)
-- so every consumer shares one layout list; until then each consumer has its own list in its own SV.
--
-- Layered on top is the small profile helper most consumers actually want:
--
--   local inst = lib:New({
--     account   = MyAddonDB,          -- gets .profiles[layoutName] = record, and (legacy) .editModeLayouts
--     char      = MyAddonCharDB,      -- gets (legacy) .editModeActiveLayout = layoutName
--     defaults  = { ... },            -- deep-copied into a record that has no copy source
--     onChanged = function(newName, oldName) end,
--   })
--   inst:Source() -> "editmode" | "manual"      inst:IsResolved() -> bool (editmode: has the real name arrived)
--   inst:Name()   inst:Current()   inst:List()  inst:Select(name)  inst:Create(name)  inst:Rename(old, new)
--   inst:Delete(name)   inst:ResetCurrent()
--
-- Records follow the layout list: a layout created in the game (always a copy of the active one) gets a copy
-- of the active record; rename moves the record; delete drops it.

local MAJOR, MINOR = "LibEditModeProfileExtension-1.0", 1
assert(LibStub, MAJOR .. " requires LibStub")
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.instances = lib.instances or {}
lib.LegacyLayoutType = { Preset = 0, Account = 1, Character = 2 }    -- == Enum.EditModeLayoutType
lib.LEGACY_DEFAULT_LAYOUT_NAME = lib.LEGACY_DEFAULT_LAYOUT_NAME or "Default"
lib.LEGACY_MAX_NAME_LENGTH = 32

local LayoutType = (Enum and Enum.EditModeLayoutType) or lib.LegacyLayoutType

local function HasRealEditMode()
  return type(C_EditMode) == "table" and type(C_EditMode.GetLayouts) == "function"
end

local function DeepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = DeepCopy(v) end
  return out
end

local function Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Merged layout list in the activeLayout index space (presets first), as EditModeManagerFrame holds it.
-- Real client only. Returns list, activeIndex or nil when the manager has not received layouts yet.
local function RealMergedLayouts()
  local mgr = EditModeManagerFrame
  if mgr and mgr.layoutInfo and mgr.layoutInfo.layouts and mgr.layoutInfo.activeLayout then
    return mgr.layoutInfo.layouts, mgr.layoutInfo.activeLayout
  end
  local ok, info = pcall(C_EditMode.GetLayouts)
  if not ok or type(info) ~= "table" or not info.layouts or not info.activeLayout then return nil end
  local list = {}
  local okp, presets = pcall(function() return EditModePresetLayoutManager:GetCopyOfPresetLayouts() end)
  if okp and type(presets) == "table" then
    for _, l in ipairs(presets) do list[#list + 1] = l end
  else
    list[1] = { layoutName = HUD_EDIT_MODE_PRESET_LAYOUT_MODERN or "Modern", layoutType = LayoutType.Preset, systems = {} }
    list[2] = { layoutName = HUD_EDIT_MODE_PRESET_LAYOUT_CLASSIC or "Classic", layoutType = LayoutType.Preset, systems = {} }
  end
  for _, l in ipairs(info.layouts) do list[#list + 1] = l end
  return list, info.activeLayout
end

-- Legacy store -----------------------------------------------------------------------------------
-- store = account.editModeLayouts = { layouts = { EditModeLayoutInfo (saved, non-preset) ... } }
-- char.editModeActiveLayout = layoutName (a name, not an index: indices shift when another character
-- deletes a layout; the game stores an index server-side but can reconcile, we cannot).
-- Legacy has NO presets by default: index space == saved list. (lib.LegacyPresets may add some later.)

local LegacyProvider = {}
LegacyProvider.__index = LegacyProvider

function LegacyProvider.New(account, char)
  local self = setmetatable({}, LegacyProvider)
  self.account, self.char = account, char
  account.editModeLayouts = type(account.editModeLayouts) == "table" and account.editModeLayouts or {}
  local store = account.editModeLayouts
  store.layouts = type(store.layouts) == "table" and store.layouts or {}
  self.store = store
  self:EnsureDefault()
  return self
end

function LegacyProvider:EnsureDefault()
  if #self.store.layouts == 0 then
    self.store.layouts[1] = { layoutName = lib.LEGACY_DEFAULT_LAYOUT_NAME, layoutType = LayoutType.Account, systems = {} }
  end
end

function LegacyProvider:Presets() return lib.LegacyPresets or {} end

function LegacyProvider:Merged()
  local list = {}
  for _, p in ipairs(self:Presets()) do list[#list + 1] = p end
  for _, l in ipairs(self.store.layouts) do list[#list + 1] = l end
  return list
end

function LegacyProvider:ActiveIndex()
  local merged = self:Merged()
  local want = self.char.editModeActiveLayout
  for i, l in ipairs(merged) do if l.layoutName == want then return i end end
  return #self:Presets() + 1     -- first saved layout ("Default")
end

function LegacyProvider:FireUpdated()
  local info = self:GetLayouts()
  if EventRegistry and EventRegistry.TriggerEvent then
    EventRegistry:TriggerEvent("EDIT_MODE_LAYOUTS_UPDATED", info, false)
  end
  if self.onUpdated then self.onUpdated(info) end
end

-- C_EditMode-shaped surface
function LegacyProvider:GetLayouts()
  -- like the real API: SAVED layouts only; activeLayout in the merged index space
  return { layouts = DeepCopy(self.store.layouts), activeLayout = self:ActiveIndex() }
end

function LegacyProvider:SetActiveLayout(index)
  local merged = self:Merged()
  local l = merged[index]
  if not l then return false end
  if self.char.editModeActiveLayout == l.layoutName then return true end
  self.char.editModeActiveLayout = l.layoutName
  self:FireUpdated()
  return true
end

function LegacyProvider:SaveLayouts(saveInfo)
  -- the manager passes its MERGED list; strip presets, keep the rest
  if type(saveInfo) ~= "table" or type(saveInfo.layouts) ~= "table" then return end
  local saved = {}
  for _, l in ipairs(saveInfo.layouts) do
    if l.layoutType ~= LayoutType.Preset then
      saved[#saved + 1] = { layoutName = l.layoutName, layoutType = l.layoutType or LayoutType.Account, systems = DeepCopy(l.systems or {}) }
    end
  end
  self.store.layouts = saved
  self:EnsureDefault()
  if EventRegistry and EventRegistry.TriggerEvent then EventRegistry:TriggerEvent("EditMode.SavedLayouts") end
  if self.onSaved then self.onSaved() end
end

function LegacyProvider:OnLayoutAdded(index, activateNewLayout)
  if activateNewLayout then
    local merged = self:Merged()
    if merged[index] then self.char.editModeActiveLayout = merged[index].layoutName end
  end
  self:FireUpdated()
end

function LegacyProvider:OnLayoutDeleted(index)
  -- the game falls back to the first layout when the active one is gone
  local merged = self:Merged()
  local found = false
  for _, l in ipairs(merged) do if l.layoutName == self.char.editModeActiveLayout then found = true end end
  if not found then self.char.editModeActiveLayout = merged[#self:Presets() + 1] and merged[#self:Presets() + 1].layoutName end
  self:FireUpdated()
end

function LegacyProvider:IsValidLayoutName(name)
  name = Trim(name)
  return name ~= "" and #name <= lib.LEGACY_MAX_NAME_LENGTH
end

function LegacyProvider:Surface()
  local p = self
  return {
    GetLayouts        = function() return p:GetLayouts() end,
    SetActiveLayout   = function(i) return p:SetActiveLayout(i) end,
    SaveLayouts       = function(info) return p:SaveLayouts(info) end,
    OnLayoutAdded     = function(i, a, imp) return p:OnLayoutAdded(i, a, imp) end,
    OnLayoutDeleted   = function(i) return p:OnLayoutDeleted(i) end,
    IsValidLayoutName = function(n) return p:IsValidLayoutName(n) end,
  }
end

-- A future shared legacy Edit Mode addon registers here (object with the LegacyProvider method set) so
-- every consumer sees one layout list. Must be called before consumers call lib:New().
function lib:SetLegacyProvider(provider) lib.sharedLegacyProvider = provider end

-- Profile helper instance ------------------------------------------------------------------------
local Instance = {}
Instance.__index = Instance

function lib:New(opts)
  assert(type(opts) == "table" and type(opts.account) == "table" and type(opts.char) == "table", MAJOR .. ": New needs account and char tables")
  local self = setmetatable({}, Instance)
  self.account, self.char = opts.account, opts.char
  self.defaults = opts.defaults or {}
  self.onChanged = opts.onChanged
  self.profilesKey = opts.profilesKey or "profiles"
  self.account[self.profilesKey] = type(self.account[self.profilesKey]) == "table" and self.account[self.profilesKey] or {}
  self.resolved = false
  self.name = lib.LEGACY_DEFAULT_LAYOUT_NAME

  if HasRealEditMode() then
    self.source = "editmode"
    self.C_EditMode = C_EditMode
    self:InitEditModeSource()
  else
    self.source = "manual"
    self.provider = lib.sharedLegacyProvider or LegacyProvider.New(self.account, self.char)
    self.C_EditMode = self.provider:Surface()
    self:InitManualSource()
  end
  lib.instances[#lib.instances + 1] = self
  return self
end

function Instance:Source() return self.source end
function Instance:IsResolved() return self.resolved end
function Instance:Name() return self.name end

function Instance:Records() return self.account[self.profilesKey] end

-- The record for the current name; created on demand as a copy of the previous current record (a
-- freshly created layout always inherits), else from defaults.
function Instance:Current()
  local recs = self:Records()
  local r = recs[self.name]
  if not r then
    local src = self.lastName and recs[self.lastName]
    r = DeepCopy(src or self.defaults)
    recs[self.name] = r
  end
  return r
end

function Instance:ResetCurrent()
  self:Records()[self.name] = DeepCopy(self.defaults)
  self:Fire(self.name, self.name)
end

function Instance:Fire(newName, oldName)
  if self.onChanged then
    local ok, err = pcall(self.onChanged, newName, oldName)
    if not ok then geterrorhandler()(err) end
  end
end

function Instance:SetName(name)
  if not name or name == "" then return end
  local old = self.name
  local wasResolved = self.resolved
  self.resolved = true
  if name == old and wasResolved then return end
  self.lastName = wasResolved and old or nil      -- an unresolved placeholder is not a copy source
  self.name = name
  self:Fire(name, wasResolved and old or nil)
end

-- Merged list (presets first) and active index, both sources.
function Instance:GetLayoutInfo()
  if self.source == "editmode" then return RealMergedLayouts() end
  return self.provider:Merged(), self.provider:ActiveIndex()
end

function Instance:List()
  local out = {}
  local list = self:GetLayoutInfo()
  for _, l in ipairs(list or {}) do out[#out + 1] = l.layoutName end
  return out
end

-- Follow the saved-layout list: create (copy active record), rename (move), delete (drop).
function Instance:ReconcileSavedNames(newSaved)
  local oldSaved = self.savedNamesCache
  self.savedNamesCache = newSaved
  if not oldSaved then return end
  local recs = self:Records()
  if #newSaved > #oldSaved then
    local known = {}
    for _, n in ipairs(oldSaved) do known[n] = true end
    for _, n in ipairs(newSaved) do
      if not known[n] and not recs[n] then recs[n] = DeepCopy(recs[self.name] or self.defaults) end
    end
  elseif #newSaved < #oldSaved then
    local keep = {}
    for _, n in ipairs(newSaved) do keep[n] = true end
    local merged = self:GetLayoutInfo() or {}
    for _, l in ipairs(merged) do keep[l.layoutName] = true end     -- never drop a preset's record
    for _, n in ipairs(oldSaved) do if not keep[n] then recs[n] = nil end end
  else
    for i, n in ipairs(newSaved) do
      local o = oldSaved[i]
      if o ~= n then
        if recs[o] and not recs[n] then recs[n] = recs[o]; recs[o] = nil end
        if self.name == o then self.name = n; self:Fire(n, o) end
      end
    end
  end
end

function Instance:SavedNamesNow()
  local ok, info = pcall(self.C_EditMode.GetLayouts)
  local names = {}
  if ok and type(info) == "table" then for _, l in ipairs(info.layouts or {}) do names[#names + 1] = l.layoutName end end
  return names
end

function Instance:ResolveFromLayouts()
  local list, active = self:GetLayoutInfo()
  local l = list and active and list[active]
  if l and l.layoutName then self:SetName(l.layoutName) end
end

-- editmode source
function Instance:InitEditModeSource()
  self.savedNamesCache = self:SavedNamesNow()
  self:ResolveFromLayouts()
  if EventRegistry then
    pcall(EventRegistry.RegisterFrameEventAndCallback, EventRegistry, "EDIT_MODE_LAYOUTS_UPDATED", function()
      -- the manager rebuilds its merged layoutInfo in its own handler; read after it (next frame)
      C_Timer.After(0, function() self:ReconcileSavedNames(self:SavedNamesNow()); self:ResolveFromLayouts() end)
    end, self)
    pcall(EventRegistry.RegisterCallback, EventRegistry, "EditMode.SavedLayouts", function()
      self:ReconcileSavedNames(self:SavedNamesNow())
    end, self)
  end
end

-- manual source
function Instance:InitManualSource()
  self.savedNamesCache = self:SavedNamesNow()
  self.provider.onUpdated = function() self:ResolveFromLayouts() end
  self.provider.onSaved = function() self:ReconcileSavedNames(self:SavedNamesNow()) end
  self:ResolveFromLayouts()
end

-- Manual-source mutators (the game owns the list on a modern client; these return false there).
function Instance:IndexOf(name)
  local list = self:GetLayoutInfo()
  for i, l in ipairs(list or {}) do if l.layoutName == name then return i end end
  return nil
end

function Instance:Select(name)
  if self.source ~= "manual" then return false end
  local i = self:IndexOf(name)
  if not i then return false end
  return self.C_EditMode.SetActiveLayout(i)
end

function Instance:Create(name)
  if self.source ~= "manual" then return false end
  name = Trim(name)
  if not self.C_EditMode.IsValidLayoutName(name) or self:IndexOf(name) then return false end
  local info = { layouts = self:GetLayoutInfo() }
  info.layouts[#info.layouts + 1] = { layoutName = name, layoutType = LayoutType.Account, systems = {} }
  self.C_EditMode.SaveLayouts(info)                -- ReconcileSavedNames copies the active record
  self.C_EditMode.OnLayoutAdded(self:IndexOf(name), true, false)
  return true
end

function Instance:Rename(oldName, newName)
  if self.source ~= "manual" then return false end
  newName = Trim(newName)
  local i = self:IndexOf(oldName)
  if not i or not self.C_EditMode.IsValidLayoutName(newName) or self:IndexOf(newName) then return false end
  local info = { layouts = self:GetLayoutInfo() }
  if info.layouts[i].layoutType == LayoutType.Preset then return false end
  info.layouts[i].layoutName = newName
  if self.char.editModeActiveLayout == oldName then self.char.editModeActiveLayout = newName end
  self.C_EditMode.SaveLayouts(info)
  return true
end

function Instance:Delete(name)
  if self.source ~= "manual" then return false end
  if name == lib.LEGACY_DEFAULT_LAYOUT_NAME or name == self.name then return false end
  local i = self:IndexOf(name)
  if not i then return false end
  local info = { layouts = self:GetLayoutInfo() }
  if info.layouts[i].layoutType == LayoutType.Preset then return false end
  table.remove(info.layouts, i)
  self.C_EditMode.SaveLayouts(info)
  self.C_EditMode.OnLayoutDeleted(i)
  return true
end