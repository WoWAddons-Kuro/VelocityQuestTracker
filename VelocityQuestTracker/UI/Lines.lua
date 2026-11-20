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

local HIGHLIGHT_SECONDS = 8      -- a square that just joined a place line keeps a yellow outline this long

-- Yellow 1 px outline around a square, created on demand and parked on the squares frame.
local function AcquireOutline(row, i)
  row.outlines = row.outlines or {}
  local o = row.outlines[i]
  if o then return o end
  o = row.squares:CreateTexture(nil, "BORDER")
  T.SetColour(o, T.Tone.Recent)
  row.outlines[i] = o
  return o
end

-- `arrivedFn(q)` returns the GetTime() the quest joined this line, or nil; squares whose arrival is
-- within HIGHLIGHT_SECONDS get the outline. Returns (height, anyHighlighted).
local function Render(list, groups, labelFn, arrivedFn, now)
  local y = 0
  local anyHighlight = false
  for i, g in ipairs(groups) do
    local row = AcquireLine(list, i)
    row.label:SetText(labelFn(g))
    local colours = {}
    for _, q in ipairs(g.quests) do colours[#colours + 1] = T.DifficultyColour(q.level) end
    row.squares:Set(colours)
    for j, q in ipairs(g.quests) do
      local at = arrivedFn and arrivedFn(q)
      local hot = at and now and (now - at) < HIGHLIGHT_SECONDS
      local o = row.outlines and row.outlines[j]
      if hot then
        o = AcquireOutline(row, j)
        local cell = row.squares.cells[j]
        o:ClearAllPoints(); o:SetPoint("TOPLEFT", cell, "TOPLEFT", -1, 1); o:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 1, -1)
        o:Show(); anyHighlight = true
      elseif o then o:Hide() end
    end
    if row.outlines then for j = #g.quests + 1, #row.outlines do row.outlines[j]:Hide() end end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", list, "TOPLEFT", T.PadX, -y)
    row:SetPoint("RIGHT", list, "RIGHT", -T.PadX, 0)
    row:Show()
    y = y + LINE_H + 2
  end
  for i = #groups + 1, #list.rows do list.rows[i]:Hide() end
  if y > 0 then y = y - 2 end
  list:SetHeight(math.max(1, y))
  return y, anyHighlight
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
  local h, hot = Render(Lines.turnin, snap.turninPlaces, function(g) return g.place end, function(q) return q.arrivedAt end, snap.now)
  Lines.highlighting = hot          -- Panel keeps re-rendering while an outline is live
  return h
end

function Lines.RenderOtherZones(snap)
  local h = Render(Lines.other, snap.otherZones, function(g) return string.format("+%d in %s", #g.quests, g.zone) end, nil, snap.now)
  return h
end