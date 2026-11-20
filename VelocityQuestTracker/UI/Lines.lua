-- Velocity Quest Tracker: parts 1 and 4, the place lines.
--   Turn-in line : check glyph, place name, one difficulty square per completed quest there.
--   Other-zone   : "+N in Zone", one difficulty square per quest.
-- One frame per place, reused by key; lines keep first-seen order (the model groups that way).
local ADDON_NAME, NS = ...
local T = NS.Theme

local Lines = {}
NS.Lines = Lines

local LINE_H = 14

local function NewList(parent, withCheck)
  local list = CreateFrame("Frame", nil, parent)
  list:SetWidth(T.PanelWidth); list:SetHeight(1)
  list.rows = {}
  list.withCheck = withCheck
  return list
end

local function AcquireLine(list, i)
  local row = list.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, list)
  row:SetHeight(LINE_H); row:SetPoint("LEFT", T.PadX, 0); row:SetPoint("RIGHT", -T.PadX, 0)
  local x = 0
  if list.withCheck then
    row.check = row:CreateTexture(nil, "ARTWORK")
    row.check:SetSize(12, 12); row.check:SetPoint("LEFT", 0, 0)
    local atlasOk = row.check.SetAtlas and pcall(row.check.SetAtlas, row.check, "common-icon-checkmark")
    if not (atlasOk and row.check:GetAtlas()) then row.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    row.check:SetVertexColor(T.Tone.Label[1], T.Tone.Label[2], T.Tone.Label[3])
    x = 12 + 8
  end
  row.label = T.Text(row, T.LabelSize, T.Tone.Label)
  row.label:SetPoint("LEFT", x, 0)
  row.squares = T.Squares(row)
  row.squares:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
  list.rows[i] = row
  return row
end

local function Render(list, groups, labelFn)
  local y = 0
  for i, g in ipairs(groups) do
    local row = AcquireLine(list, i)
    row.label:SetText(labelFn(g))
    local colours = {}
    for _, q in ipairs(g.quests) do colours[#colours + 1] = T.DifficultyColour(q.level) end
    row.squares:Set(colours)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", list, "TOPLEFT", T.PadX, -y)
    row:SetPoint("RIGHT", list, "RIGHT", -T.PadX, 0)
    row:Show()
    y = y + LINE_H + 2
  end
  for i = #groups + 1, #list.rows do list.rows[i]:Hide() end
  if y > 0 then y = y - 2 end
  list:SetHeight(math.max(1, y))
  return y
end

function Lines.AttachTurnIn(parent)
  if not Lines.turnin then Lines.turnin = NewList(parent, true) end
  return Lines.turnin
end

function Lines.AttachOtherZones(parent)
  if not Lines.other then Lines.other = NewList(parent, false) end
  return Lines.other
end

function Lines.RenderTurnIn(snap)
  return Render(Lines.turnin, snap.turninPlaces, function(g) return g.place end)
end

function Lines.RenderOtherZones(snap)
  return Render(Lines.other, snap.otherZones, function(g) return string.format("+%d in %s", #g.quests, g.zone) end)
end