-- Velocity Quest Tracker: the panel in Edit Mode, through vendored LibEditMode.
-- Pattern: KondoBags/UI/EditMode.lua. A UIParent-parented placeholder is what the library moves;
-- the live panel follows it. Placement is saved per character in VelocityQuestTrackerCharDB.panel.
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

-- VQT_PanelPlacement = { point, x, y, placed }
local function Placement()
  local db = VelocityQuestTrackerCharDB
  db.panel = db.panel or {}
  local p = db.panel
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
function EditMode.IsPositionLocked() return NS.db.settings.LockPosition ~= false end

function EditMode.ApplyToPanel()
  local f = Panel.Frame()
  if not f then return end
  local p = Placement()
  f:ClearAllPoints()
  f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
end

function EditMode.OnPanelMoved()
  local f = Panel.Frame()
  if not f then return end
  local point, _, _, x, y = f:GetPoint(1)
  local p = Placement()
  p.point, p.x, p.y = point or p.point, x or p.x, y or p.y
end

function EditMode.OnPanelResized(w, h)
  if placeholder and editing then placeholder:SetSize(w, math.max(40, h)) end
end

local function OnPlaceholderMoved(frame)
  local point, _, _, x, y = frame:GetPoint(1)
  local p = Placement()
  p.point, p.x, p.y = point or "TOPRIGHT", x or 0, y or 0
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
    if f then f:ClearAllPoints(); f:SetPoint(point, UIParent, point, x, y) end
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
      set = function(_, value) NS.db.settings.LockPosition = value and true or false; if NS.Options and NS.Options.Refresh then NS.Options.Refresh() end end,
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
  if f then f:EnableMouse(not EditMode.IsPositionLocked()) end
end

function EditMode.ResetPosition()
  VelocityQuestTrackerCharDB.panel = nil
  EditMode.ApplyToPanel()
end

function EditMode.Status()
  if not lib then return "LibEditMode not found; panel moves by drag only" end
  return "LibEditMode minor " .. tostring(lib.hookVersion or "?") .. (editing and " (editing now)" or "")
end