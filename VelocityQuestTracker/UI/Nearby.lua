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

-- Spark-line scale: the left end is the player, the right end is Position.NearbyRangeYards() --
-- max(600, farthest nearby spawn), fixed between objective-set changes. Distance is mapped with a
-- square root by default (near half of the line = near quarter of the range) so the differences that
-- matter -- the close ones -- get the pixels; the "LinearSparkScale" setting restores d / range.
local function Settings() return NS.db and NS.db.settings or {} end

function Nearby.ScaleDistance(d, range)
  local f = math.min(1, d / range)
  if Settings().LinearSparkScale then return f end
  return math.sqrt(f)
end

-- fn(quest, objective, owed) -> array of 0..1 fractions (one per unit owed), or nil for "unknown".
-- Default: QuestieDB spawns via Location + Position. Each unit owed is placed at the distance of the
-- n-th nearest spawn (units beyond the spawn count repeat the farthest), so five owed with two
-- spawns near and one far reads as "mostly near".
function Nearby.DistanceProvider(quest, objective, owed)
  local Location, Position = NS.Location, NS.Position
  if not (Location and Location.IsAvailable() and Position and Position.Current()) then return nil end
  local spawns = Location.SpawnsForObjective(quest, objective)
  if not spawns or #spawns == 0 then return nil end
  local dists = Position.DistancesTo(spawns)
  if #dists == 0 then return nil end
  local range = Position.NearbyRangeYards()
  local out = {}
  for u = 1, owed do
    local d = dists[math.min(u, #dists)]
    out[u] = Nearby.ScaleDistance(d, range)
  end
  return out
end

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
  -- Hover: the shared card in block mode for the quest this objective belongs to (row.quest).
  row:EnableMouse(true)
  row.hover = row:CreateTexture(nil, "BACKGROUND")
  row.hover:SetPoint("TOPLEFT", -T.PadX, 2); row.hover:SetPoint("BOTTOMRIGHT", T.PadX, -2)
  T.SetColour(row.hover, T.Tone.Wash, T.WashAlpha * 2)
  row.hover:Hide()
  row:SetScript("OnEnter", function(self) if self.quest then NS.HoverCard.ShowBlock(self, self.quest) end end)
  row:SetScript("OnLeave", function() NS.HoverCard.ScheduleHide() end)
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
  -- range is per objective SET, so it is stable while walking (see Position.UpdateNearbyRange)
  if NS.Position and NS.Position.UpdateNearbyRange then NS.Position.UpdateNearbyRange(snap) end
  for _, q in ipairs(snap.byCategory.nearby) do
    for _, o in ipairs(q.objectives) do
      local owed = o.need - o.have
      if owed > 0 then
        i = i + 1
        local row = AcquireLine(i)
        row.quest = q
        T.ApplyWash(row.hover, 2)                    -- terrain band may have changed
        if NS.HoverCard.IsShownFor(row) then NS.HoverCard.ShowBlock(row, q) end   -- live refresh under the cursor
        SetShape(row, ShapeFor(o.name))
        seenNames[o.name] = true
        row.name:SetText((function() local c = T.CountText(o.have, o.need); local n = T.CountlessName(o.name); return c ~= "" and (c .. " " .. n) or n end)())
        local fr = Nearby.DistanceProvider and Nearby.DistanceProvider(q, o, owed)
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