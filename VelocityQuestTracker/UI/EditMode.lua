-- Velocity Quest Tracker: the panel in Edit Mode, through vendored LibEditMode.
-- Pattern: KondoBags/UI/EditMode.lua. A UIParent-parented placeholder is what the library moves;
-- the live panel follows it. Placement and the lock flag are saved PER LAYOUT PROFILE
-- (NS.Profiles:Current(), LibEditModeProfileExtension): on Forever the profile is the active Edit Mode
-- layout, so switching layouts -- in the game's dropdown or by VelocitySettingsSync at login -- moves the
-- panel to where it was saved for that layout; on Era the profile comes from the Options block.
--
-- First run: anchor to where the STOCK tracker sits (its TOPRIGHT in UIParent coordinates), read
-- once before it is swallowed, so the first look lands where the player expects a tracker.
--
-- "Lock position" (options checkbox, default ON): when locked the panel moves only in Edit Mode;
-- unlocked it can also be dragged by its own frame.
local ADDON_NAME, NS = ...
local Panel, Theme, Client = NS.Panel, NS.Theme, NS.Client

local EditMode = {}
NS.EditMode = EditMode

local lib
local placeholder
local editing = false
local defaultPos = { point = "TOPRIGHT", x = -90, y = -250 }

-- VQT_PanelPlacement = { point, x, y, placed }, stored as VQT_LayoutProfile.panel
local function Placement()
  local profile = NS.Profiles:Current()
  profile.panel = profile.panel or {}
  local p = profile.panel
  if p.point then p.placed = true end
  if not p.placed then
    local stock = Client.StockTrackerFrame()
    local point, x, y = "TOPRIGHT", -90, -250
    if stock and stock:GetRight() and stock:GetTop() then
      local scale = stock:GetEffectiveScale() / UIParent:GetEffectiveScale()
      local right = stock:GetRight() * scale - UIParent:GetWidth()
      local top = stock:GetTop() * scale - UIParent:GetHeight()
      x, y = math.floor(right + 0.5), math.floor(top + 0.5)
    end
    p.point, p.x, p.y, p.placed = point, x, y, true
  end
  return p
end

function EditMode.IsActive() return editing end
function EditMode.IsPositionLocked() return NS.Profiles:Current().lockPosition ~= false end
function EditMode.SetPositionLocked(locked)
  NS.Profiles:Current().lockPosition = locked and true or false
  EditMode.ApplyLock()
  if NS.Options and NS.Options.Refresh then NS.Options.Refresh() end
end

-- Profile switched (layout change, create, rename, reset): place the panel where THIS profile says.
-- If Edit Mode is open (the game's layout dropdown switches layouts live), the placeholder the library
-- moves must follow too, or the overlay stays on the old layout's spot while the panel has moved.
function EditMode.OnProfileChanged()
  if not Panel.Frame() then return end
  EditMode.ApplyToPanel(); EditMode.ApplyLock()
  if editing and placeholder then
    local p = Placement()
    placeholder:ClearAllPoints(); placeholder:SetPoint(p.point, UIParent, p.point, p.x, p.y)
  end
end

-- The panel's height changes with its content (map view, blocks arriving). It must grow DOWN from a
-- fixed top edge, never shift up, so the saved anchor is always normalised to a TOP* point. A point
-- captured as BOTTOM*/CENTER (Edit Mode drops with the mouse at whatever point it chose, drag
-- StopMovingOrSizing likewise) is converted to the equivalent TOPLEFT/TOPRIGHT offset from the
-- frame's current on-screen rectangle before it is stored.
local function NormaliseToTop(f, p)
  if not f or not p.point then return end
  if p.point:sub(1, 3) == "TOP" then return end
  local left, top, right = f:GetLeft(), f:GetTop(), f:GetRight()
  if not (left and top and right) then return end
  local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
  -- keep the horizontal side the player chose (left half -> TOPLEFT, right half -> TOPRIGHT)
  if (left + right) / 2 >= sw / 2 then
    p.point, p.x, p.y = "TOPRIGHT", right - sw, top - sh
  else
    p.point, p.x, p.y = "TOPLEFT", left, top - sh
  end
end

-- The secure quest-item buttons live on their own UIParent-parented layer that only MIRRORS the panel
-- rect (see UI\ItemButtons.lua header); nothing anchors it to the panel, so every time the panel is
-- re-placed here the layer must be told to follow. Safe in combat (returns false, no-op).
local function SyncItemButtons()
  if NS.ItemButtons and NS.ItemButtons.SyncToPanel then NS.ItemButtons.SyncToPanel() end
end

function EditMode.ApplyToPanel()
  local f = Panel.Frame()
  if not f then return end
  local p = Placement()
  if p.point:sub(1, 3) ~= "TOP" then
    -- place with the saved point once so GetLeft/GetTop are meaningful, then normalise and re-place
    f:ClearAllPoints(); f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
    NormaliseToTop(f, p)
  end
  f:ClearAllPoints()
  f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
  SyncItemButtons()
end

function EditMode.OnPanelMoved()
  local f = Panel.Frame()
  if not f then return end
  local point, _, _, x, y = f:GetPoint(1)
  local p = Placement()
  p.point, p.x, p.y = point or p.point, x or p.x, y or p.y
  NormaliseToTop(f, p)
  EditMode.ApplyToPanel()
end

function EditMode.OnPanelResized(w, h)
  if placeholder and editing then placeholder:SetSize(w, math.max(40, h)) end
end

local function OnPlaceholderMoved(frame)
  local point, _, _, x, y = frame:GetPoint(1)
  local p = Placement()
  p.point, p.x, p.y = point or "TOPRIGHT", x or 0, y or 0
  NormaliseToTop(frame, p)
  EditMode.ApplyToPanel()
end

local function CreatePlaceholder()
  if placeholder then return placeholder end
  placeholder = CreateFrame("Frame", "VelocityQuestTrackerEditModePlaceholder", UIParent)
  placeholder:SetFrameStrata("HIGH")
  placeholder:SetClampedToScreen(true)
  placeholder:SetMovable(true)
  placeholder:SetSize(Theme.PanelWidth, 120)
  placeholder:Hide()
  local bg = placeholder:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.5)
  local label = placeholder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetPoint("CENTER"); label:SetText("Velocity Quest Tracker")
  lib:AddFrame(placeholder, OnPlaceholderMoved, defaultPos, "Velocity Quest Tracker")
  -- live follow while dragging
  local selection = lib.frameSelections and lib.frameSelections[placeholder]
  local function FollowStart() placeholder:SetScript("OnUpdate", function(self)
    local point, _, _, x, y = self:GetPoint(1)
    if not point then return end
    local f = Panel.Frame()
    if f then
      f:ClearAllPoints(); f:SetPoint(point, UIParent, point, x, y)
      SyncItemButtons()   -- the secure button layer mirrors the panel rect; it does not follow by itself
    end
  end) end
  local function FollowStop() placeholder:SetScript("OnUpdate", nil) end
  if selection then
    selection:HookScript("OnDragStart", FollowStart)
    selection:HookScript("OnDragStop", FollowStop)
  end
  lib:AddFrameSettings(placeholder, {
    {
      kind = lib.SettingType.Checkbox,
      name = "Lock position",
      default = true,
      get = function() return EditMode.IsPositionLocked() end,
      set = function(_, value) EditMode.SetPositionLocked(value) end,
    },
  })
  return placeholder
end

local function OnEnter()
  editing = true
  CreatePlaceholder()
  local p = Placement()
  local f = Panel.Frame()
  local h = f and f:GetHeight() or 120
  placeholder:SetSize(Theme.PanelWidth, math.max(40, h))
  placeholder:ClearAllPoints()
  placeholder:SetPoint(p.point, UIParent, p.point, p.x, p.y)
  placeholder:Show()
end

local function OnExit()
  editing = false
  if placeholder then placeholder:Hide() end
  EditMode.ApplyToPanel()
end

function EditMode.Setup()
  if lib then return true end
  local found = LibStub and LibStub("LibEditMode", true)
  if not found or type(found.AddFrame) ~= "function" or type(found.RegisterCallback) ~= "function" then return false end
  lib = found
  lib:RegisterCallback("enter", OnEnter)
  lib:RegisterCallback("exit", OnExit)
  return true
end

-- Plain drag on the panel itself when unlocked.
function EditMode.WirePanelDrag()
  local f = Panel.Frame()
  if not f then return end
  f:SetMovable(true)
  f:EnableMouse(false)   -- no chrome at rest: the panel does not eat clicks unless unlocked
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) if not editing and not EditMode.IsPositionLocked() then self:StartMoving() end end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); EditMode.OnPanelMoved() end)
  EditMode.ApplyLock()
end

function EditMode.ApplyLock()
  local f = Panel.Frame()
  -- the unlocked drag surface is interaction too: off in combat (Core\Interact re-calls this on the flip)
  if f then f:EnableMouse(not EditMode.IsPositionLocked() and not NS.Interact.InCombat()) end
end

function EditMode.ResetPosition()
  NS.Profiles:Current().panel = nil
  EditMode.ApplyToPanel()
end

function EditMode.Status()
  local P = NS.Profiles
  local profile = string.format("profile %q (%s)", P:Name(), P:Source() == "editmode" and "Edit Mode layout" or "manual")
  if not lib then return "LibEditMode not found; panel moves by drag only | " .. profile end
  return "LibEditMode minor " .. tostring(lib.hookVersion or "?") .. (editing and " (editing now)" or "") .. " | " .. profile
end