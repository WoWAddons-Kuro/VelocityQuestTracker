-- Velocity Quest Tracker: the panel. 250 px wide, four parts stacked, each omitted when empty.
-- No chrome at rest. Re-rendered when the model changes; while any segment animates it also
-- re-renders every frame (cheap: only colours change).
--
-- Part 3 (nearby work) has two views, "map" (UI\MapView.lua) and "lines" (UI\Nearby.lua), chosen per
-- character (VelocityQuestTrackerCharDB.nearbyView). Two small tab buttons appear beside part 3 while
-- the panel is hovered, on the side away from the screen edge (same test as the place-line card).
local ADDON_NAME, NS = ...
local T, Model, Blocks, Lines, Nearby, MapView = NS.Theme, NS.Model, NS.Blocks, NS.Lines, NS.Nearby, NS.MapView

local Panel = {}
NS.Panel = Panel

local frame
local parts = {}
local tabs                    -- VQT_NearbyViewTabs frame: two buttons, map | lines
local TAB_PX = 20

local function Settings() return NS.db and NS.db.settings or {} end

function Panel.NearbyView() return (NS.chardb and NS.chardb.nearbyView) or "lines" end

function Panel.SetNearbyView(view)
  if NS.chardb then NS.chardb.nearbyView = view end
  Panel.Render()
end

-- Tabs -------------------------------------------------------------------------------------
local function HoverAllowed() return not Settings().RequireShiftForHover or IsShiftKeyDown() end

local function BuildTabs()
  tabs = CreateFrame("Frame", nil, frame)
  tabs:SetSize(TAB_PX, TAB_PX * 2 + 4)
  tabs:Hide()
  local function Tab(label, view, yOff)
    local b = CreateFrame("Button", nil, tabs)
    b:SetSize(TAB_PX, TAB_PX)
    b:SetPoint("TOP", 0, yOff)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.text = T.Text(b, T.LabelSize, T.Tone.Label); b.text:SetPoint("CENTER"); b.text:SetJustifyH("CENTER"); b.text:SetText(label)
    b.view = view
    b:SetScript("OnClick", function(self)
      if Settings().RequireShiftToInteract and not IsShiftKeyDown() then return end
      Panel.SetNearbyView(self.view)
    end)
    b:SetScript("OnEnter", function(self) if HoverAllowed() then T.SetColour(self.text, T.Tone.Todo) end end)
    b:SetScript("OnLeave", function(self) Panel.RefreshTabs() end)
    return b
  end
  tabs.map = Tab("\226\151\142", "map", 0)          -- ◎  (circle with dot) stands for the field
  tabs.lines = Tab("\226\137\161", "lines", -(TAB_PX + 4))   -- ≡  three lines
end

function Panel.RefreshTabs()
  if not tabs then return end
  local cur = Panel.NearbyView()
  for _, b in ipairs({ tabs.map, tabs.lines }) do
    local on = b.view == cur
    b.bg:SetColorTexture(1, 1, 1, on and 0.14 or 0)
    T.SetColour(b.text, on and T.Tone.Todo or T.Tone.Label)
  end
end

-- Show tabs beside part 3 while the panel is hovered; side = away from the nearer screen edge.
local function PositionTabs()
  if not tabs or not parts.nearby then return end
  local cx = frame:GetCenter()
  local openLeft = cx and cx >= (UIParent:GetWidth() or 0) / 2
  tabs:ClearAllPoints()
  if openLeft then tabs:SetPoint("TOPRIGHT", parts.nearbyHolder, "TOPLEFT", -4, 0)
  else tabs:SetPoint("TOPLEFT", parts.nearbyHolder, "TOPRIGHT", 4, 0) end
end

function Panel.Frame() return frame end

local function Layout(snap)
  local y = 0
  local function Place(part, h)
    if h and h > 0 then
      part:ClearAllPoints(); part:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y); part:Show()
      y = y + h + T.PartGap
    else
      part:Hide()
    end
  end
  Place(parts.turnin, Lines.RenderTurnIn(snap))
  Place(parts.blocks, Blocks.Render(snap))
  -- part 3: one of two views; the other is hidden. nearbyHolder is whichever is live, for the tabs.
  local view = Panel.NearbyView()
  local nearbyH
  if view == "map" then
    parts.lines:Hide()
    nearbyH = MapView.Render(snap)
    parts.nearbyHolder = parts.map
    Place(parts.map, nearbyH)
  else
    parts.map:Hide()
    nearbyH = Nearby.Render(snap)
    parts.nearbyHolder = parts.lines
    Place(parts.lines, nearbyH)
  end
  Place(parts.other, Lines.RenderOtherZones(snap))
  if y > 0 then y = y - T.PartGap end
  frame:SetHeight(math.max(1, y))
  if tabs and tabs:IsShown() then PositionTabs(); Panel.RefreshTabs() end
  if NS.EditMode and NS.EditMode.OnPanelResized then NS.EditMode.OnPanelResized(T.PanelWidth, frame:GetHeight()) end
end

function Panel.Render()
  if not frame then return end
  Layout(Model.Current())
end

local function OnUpdate()
  if Blocks.animating or Lines.highlighting or MapView.easing then Panel.Render() end
end

function Panel.Create()
  if frame then return frame end
  frame = CreateFrame("Frame", "VelocityQuestTrackerPanel", UIParent)
  frame:SetSize(T.PanelWidth, 1)
  frame:SetFrameStrata("LOW")
  frame:SetClampedToScreen(true)
  parts.turnin = Lines.AttachTurnIn(frame)
  parts.blocks = Blocks.Attach(frame)
  parts.lines = Nearby.Attach(frame)
  parts.map = MapView.Attach(frame)
  parts.nearby = parts.lines          -- legacy alias; nearbyHolder tracks the live view
  parts.nearbyHolder = parts.lines
  parts.other = Lines.AttachOtherZones(frame)
  BuildTabs()
  -- Tabs show while the mouse is over the panel or the tabs themselves. The panel does not take
  -- the mouse at rest (click-through), so hover is read on OnUpdate via IsMouseOver.
  frame:HookScript("OnUpdate", function(self)
    local over = HoverAllowed() and (self:IsMouseOver() or tabs:IsMouseOver()) and parts.nearbyHolder:IsShown()
    if over and not tabs:IsShown() then PositionTabs(); Panel.RefreshTabs(); tabs:Show()
    elseif not over and tabs:IsShown() then tabs:Hide() end
  end)
  frame:SetScript("OnUpdate", OnUpdate)
  Model.OnChanged(function() Panel.Render() end)
  return frame
end

function Panel.SetShown(shown)
  if not frame then return end
  frame:SetShown(shown)
  if shown then Panel.Render() end
end

function Panel.IsShown() return frame and frame:IsShown() or false end