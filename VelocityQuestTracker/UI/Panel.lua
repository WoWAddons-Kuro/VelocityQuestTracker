-- Velocity Quest Tracker: the panel. 250 px wide, four parts stacked, each omitted when empty.
-- No chrome at rest. Re-rendered when the model changes; while any segment animates it also
-- re-renders every frame (cheap: only colours change).
local ADDON_NAME, NS = ...
local T, Model, Blocks, Lines, Nearby = NS.Theme, NS.Model, NS.Blocks, NS.Lines, NS.Nearby

local Panel = {}
NS.Panel = Panel

local frame
local parts = {}

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
  Place(parts.nearby, Nearby.Render(snap))
  Place(parts.other, Lines.RenderOtherZones(snap))
  if y > 0 then y = y - T.PartGap end
  frame:SetHeight(math.max(1, y))
  if NS.EditMode and NS.EditMode.OnPanelResized then NS.EditMode.OnPanelResized(T.PanelWidth, frame:GetHeight()) end
end

function Panel.Render()
  if not frame then return end
  Layout(Model.Current())
end

local function OnUpdate()
  if Blocks.animating or Lines.highlighting then Panel.Render() end
end

function Panel.Create()
  if frame then return frame end
  frame = CreateFrame("Frame", "VelocityQuestTrackerPanel", UIParent)
  frame:SetSize(T.PanelWidth, 1)
  frame:SetFrameStrata("LOW")
  frame:SetClampedToScreen(true)
  parts.turnin = Lines.AttachTurnIn(frame)
  parts.blocks = Blocks.Attach(frame)
  parts.nearby = Nearby.Attach(frame)
  parts.other = Lines.AttachOtherZones(frame)
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