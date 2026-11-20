-- Velocity Quest Tracker: the panel. 250 px wide, four parts stacked, each omitted when empty.
-- No chrome at rest. Re-rendered when the model changes; while any segment animates it also
-- re-renders every frame (cheap: only colours change).
--
-- Part 3 (nearby work) has two views, "map" (UI\MapView.lua) and "range" (UI\Nearby.lua), chosen per
-- character (VelocityQuestTrackerCharDB.nearbyView). While the mouse is anywhere over the panel a
-- VQT_HoverStrip appears ABOVE it (one row, panel width) carrying the view toggle: "Map | Range".
-- It is the home for any future view/option control, so the panel body stays chrome-free.
local ADDON_NAME, NS = ...
local T, Model, Blocks, Lines, Nearby, MapView = NS.Theme, NS.Model, NS.Blocks, NS.Lines, NS.Nearby, NS.MapView

local Panel = {}
NS.Panel = Panel

local frame
local parts = {}
local strip                    -- VQT_HoverStrip frame: a row above the panel with the view toggle
local STRIP_H = 18
local STRIP_GAP = 4           -- between strip bottom and panel top

local function Settings() return NS.db and NS.db.settings or {} end

-- VQT_NearbyView = "map" | "range". "range" is the spark-line list (markers by distance); it was
-- called "lines" until 2026-11-20 and old saved values are read as "range".
function Panel.NearbyView()
  local v = NS.chardb and NS.chardb.nearbyView
  if v == "map" then return "map" end
  return "range"
end

function Panel.SetNearbyView(view)
  if NS.chardb then NS.chardb.nearbyView = view end
  Panel.Render()
end

-- Tabs -------------------------------------------------------------------------------------
local function HoverAllowed() return not Settings().RequireShiftForHover or IsShiftKeyDown() end

local function BuildTabs()
  strip = CreateFrame("Frame", nil, frame)
  strip:SetSize(T.PanelWidth, STRIP_H)
  strip:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, STRIP_GAP)
  strip:Hide()
  strip.bg = strip:CreateTexture(nil, "BACKGROUND"); strip.bg:SetAllPoints()
  T.SetColour(strip.bg, T.Tone.Wash, T.WashAlpha)
  -- Segmented toggle, left-aligned: [ ◎ Map ] [ ≡ Lines ]. Each tab is a text button with its own wash.
  local x = T.PadX
  local function Tab(glyph, label, view)
    local b = CreateFrame("Button", nil, strip)
    b:SetHeight(STRIP_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.text = T.Text(b, T.LabelSize, T.Tone.Label); b.text:SetPoint("LEFT", 6, 0); b.text:SetPoint("RIGHT", -6, 0); b.text:SetJustifyH("CENTER")
    b.text:SetText(glyph .. " " .. label)
    b:SetWidth(b.text:GetStringWidth() + 12)
    b:SetPoint("LEFT", strip, "LEFT", x, 0)
    x = x + b:GetWidth() + 2
    b.view = view
    b:SetScript("OnClick", function(self)
      if Settings().RequireShiftToInteract and not IsShiftKeyDown() then return end
      Panel.SetNearbyView(self.view)
    end)
    b:SetScript("OnEnter", function(self) if HoverAllowed() then T.SetColour(self.text, T.Tone.Todo) end end)
    b:SetScript("OnLeave", function(self) Panel.RefreshTabs() end)
    return b
  end
  strip.map = Tab("\226\151\142", "Map", "map")          -- ◎
  strip.range = Tab("\226\137\161", "Range", "range")    -- ≡
end

function Panel.RefreshTabs()
  if not strip then return end
  local cur = Panel.NearbyView()
  for _, b in ipairs({ strip.map, strip.range }) do
    local on = b.view == cur
    b.bg:SetColorTexture(1, 1, 1, on and 0.14 or 0)
    T.SetColour(b.text, on and T.Tone.Todo or T.Tone.Label)
  end
end

-- The strip is anchored once (above the panel's top edge); nothing to reposition.
local function PositionTabs() end

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
  -- part 3: one of two views; the other is hidden. nearbyHolder is whichever is live, for the strip.
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
  if strip and strip:IsShown() then PositionTabs(); Panel.RefreshTabs() end
  if NS.EditMode and NS.EditMode.OnPanelResized then NS.EditMode.OnPanelResized(T.PanelWidth, frame:GetHeight()) end
end

function Panel.Render()
  if not frame then return end
  Layout(Model.Current())
end

local function OnUpdate()
  if Blocks.animating or Lines.highlighting or MapView.easing then Panel.Render() end
  -- Hover strip. The panel does not take the mouse at rest (click-through), so hover is read here
  -- via IsMouseOver; the panel rect is given a top margin so the gap to the strip does not flicker.
  -- (This USED to be a HookScript("OnUpdate") installed BEFORE SetScript("OnUpdate", OnUpdate), which
  -- replaced it -- the hook never ran and the strip/strip never appeared. Owner 2026-11-20.)
  if not strip then return end
  local over = HoverAllowed() and (frame:IsMouseOver(STRIP_H + STRIP_GAP, 0, 0, 0) or strip:IsMouseOver())
  if over and not strip:IsShown() then Panel.RefreshTabs(); strip:Show()
  elseif not over and strip:IsShown() then strip:Hide() end
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