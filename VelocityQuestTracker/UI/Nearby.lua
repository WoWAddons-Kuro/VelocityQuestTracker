-- Velocity Quest Tracker: part 3, nearby work -- the line view.
-- One line per objective of each in-zone, not-active quest: shape, full name (ellipsised, never
-- wrapped), and a 60 px spark line with one 4 px marker per unit still owed, placed by distance.
-- M1 has no location data: every marker sits at the same placeholder distance (mid-line).
-- M2 (QuestieDB) supplies real distances through Nearby.DistanceProvider.
--
-- Shape assignment: the first six source names seen get the six shapes in order and keep them
-- while in the log (VQT_Nearby_ShapeByName); the rest draw as squares.
local ADDON_NAME, NS = ...
local T = NS.Theme

local Nearby = {}
NS.Nearby = Nearby

local LINE_H = 14
local list
local shapeByName = {}       -- objective name -> shape kind
local shapesUsed = 0

-- fn(quest, objective) -> array of 0..1 fractions (one per unit owed), or nil for "unknown"
Nearby.DistanceProvider = nil

local function ShapeFor(name)
  local s = shapeByName[name]
  if s then return s end
  shapesUsed = shapesUsed + 1
  s = T.Shapes[shapesUsed] or "square"
  shapeByName[name] = s
  return s
end

local function AcquireLine(i)
  local row = list.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, list)
  row:SetHeight(LINE_H)
  row.shapeHolder = CreateFrame("Frame", nil, row); row.shapeHolder:SetSize(10, LINE_H); row.shapeHolder:SetPoint("LEFT", 0, 0)
  row.name = T.Text(row, T.LabelSize, T.Tone.Near)
  row.name:SetPoint("LEFT", row.shapeHolder, "RIGHT", T.ColGap, 0)
  row.spark = CreateFrame("Frame", nil, row)
  row.spark:SetSize(T.SparkWidth, 8); row.spark:SetPoint("RIGHT", 0, 0)
  row.spark.base = row.spark:CreateTexture(nil, "BACKGROUND")
  row.spark.base:SetHeight(1); row.spark.base:SetPoint("LEFT", 0, 0); row.spark.base:SetPoint("RIGHT", 0, 0)
  row.spark.base:SetColorTexture(1, 1, 1, 0.15)
  row.spark.marks = {}
  row.name:SetPoint("RIGHT", row.spark, "LEFT", -T.ColGap, 0)
  list.rows[i] = row
  return row
end

local function SetShape(row, kind)
  if row.shapeKind == kind then return end
  row.shapeKind = kind
  if row.shape then row.shape:Hide(); if row.shape.extra then row.shape.extra:Hide() end end
  row.shape = T.Shape(row.shapeHolder, kind, T.Tone.Near)
  row.shape:SetPoint("CENTER")
end

local function SetMarks(row, fractions)
  local marks = row.spark.marks
  local usable = T.SparkWidth - T.SparkMark
  for i, f in ipairs(fractions) do
    local m = marks[i]
    if not m then
      m = row.spark:CreateTexture(nil, "ARTWORK"); m:SetSize(T.SparkMark, T.SparkMark)
      T.SetColour(m, T.Tone.Near)
      marks[i] = m
    end
    m:ClearAllPoints(); m:SetPoint("LEFT", row.spark, "LEFT", math.floor(f * usable + 0.5), 0); m:Show()
  end
  for i = #fractions + 1, #marks do marks[i]:Hide() end
end

function Nearby.Attach(parent)
  if list then return list end
  list = CreateFrame("Frame", nil, parent)
  list:SetWidth(T.PanelWidth); list:SetHeight(1)
  list.rows = {}
  return list
end

function Nearby.Render(snap)
  local y = 0
  local i = 0
  local seenNames = {}
  for _, q in ipairs(snap.byCategory.nearby) do
    for _, o in ipairs(q.objectives) do
      local owed = o.need - o.have
      if owed > 0 then
        i = i + 1
        local row = AcquireLine(i)
        SetShape(row, ShapeFor(o.name))
        seenNames[o.name] = true
        row.name:SetText(o.name)
        local fr = Nearby.DistanceProvider and Nearby.DistanceProvider(q, o)
        if not fr then fr = {}; for u = 1, owed do fr[u] = 0.5 end end
        SetMarks(row, fr)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", list, "TOPLEFT", T.PadX, -y)
        row:SetPoint("RIGHT", list, "RIGHT", -T.PadX, 0)
        row:Show()
        y = y + LINE_H + 2
      end
    end
  end
  for k = i + 1, #list.rows do list.rows[k]:Hide() end
  -- release shapes of names no longer anywhere in the log
  local inLog = {}
  for _, q in ipairs(snap.quests) do for _, o in ipairs(q.objectives) do inLog[o.name] = true end end
  for name in pairs(shapeByName) do if not inLog[name] then shapeByName[name] = nil end end
  if next(shapeByName) == nil then shapesUsed = 0 end
  if y > 0 then y = y - 2 end
  list:SetHeight(math.max(1, y))
  return y
end