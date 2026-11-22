-- Velocity Quest Tracker: part 3, nearby work -- the map view (SPEC "Map view", PLAN "Nearby-work scale
-- and marks"). A square field as wide as the panel, north up, player at the centre (no marker), three
-- bands of range/3 yards, band 2 drawn as a brighter ring. One mark per (source type, sector), sized by
-- that sector's share of the type's spawns; the mark sits at the sector's mean spawn distance. Marks ease
-- to new positions over MARK_EASE_SECONDS. Key below: shape + full source name.
--
-- Terms: VQT_SourceType = objective name (what the player looks for); VQT_MapMark = Position.MarksFor output.
local ADDON_NAME, NS = ...
local T, Util = NS.Theme, NS.Util

local MapView = {}
NS.MapView = MapView

local FIELD_PX = T.PanelWidth / 2          -- owner 2026-11-20: full width was far too big; half for now, layout to follow
local RING_BAND = 2
local MARK_BASE_PX = 7
local MARK_MIN_PX, MARK_MAX_PX = 5, 9
local MARK_EASE_SECONDS = 0.4
local KEY_ROW_H = 14

local container, field, key
local marksByType = {}        -- sourceType -> { [sector] = texture }
local sectorMemory = {}       -- sourceType -> { [spawnKey] = sector }  (hysteresis state)
local shapeByName = {}        -- shared with Nearby: same names -> same shapes
local shapesUsed = 0

local function ShapeFor(name)
  local s = shapeByName[name]
  if s then return s end
  shapesUsed = shapesUsed + 1
  s = T.Shapes[shapesUsed] or "square"
  shapeByName[name] = s
  return s
end
MapView.ShapeFor = ShapeFor

-- Field ------------------------------------------------------------------------------------
local function BuildField(parent)
  field = CreateFrame("Frame", nil, parent)
  field:SetSize(FIELD_PX, FIELD_PX)
  field.bg = field:CreateTexture(nil, "BACKGROUND")
  field.bg:SetAllPoints()
  T.SetColour(field.bg, T.Tone.Surface, 0.9)
  -- band-2 ring: outer disc minus inner disc, two circle masks of the field's own tone
  local half = FIELD_PX / 2
  local bandPx = half / 3
  field.ringOuter = field:CreateTexture(nil, "BORDER")
  field.ringOuter:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
  field.ringOuter:SetSize(bandPx * 2 * RING_BAND, bandPx * 2 * RING_BAND)
  field.ringOuter:SetPoint("CENTER")
  field.ringOuter:SetVertexColor(0.17, 0.20, 0.18, 1)      -- #2c342d
  field.ringInner = field:CreateTexture(nil, "ARTWORK")
  field.ringInner:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
  field.ringInner:SetSize(bandPx * 2 * (RING_BAND - 1), bandPx * 2 * (RING_BAND - 1))
  field.ringInner:SetPoint("CENTER")
  field.ringInner:SetVertexColor(0.13, 0.16, 0.14, 1)
  field.ringInner:SetDrawLayer("ARTWORK", -1)
  return field
end

-- Marks ------------------------------------------------------------------------------------
local function MarkSizePx(share)
  return Util.Clamp(MARK_BASE_PX * (0.75 + 0.5 * math.sqrt(share)), MARK_MIN_PX, MARK_MAX_PX)
end

local function AcquireMark(sourceType, sector, kind)
  local byType = marksByType[sourceType]
  if not byType then byType = {}; marksByType[sourceType] = byType end
  local m = byType[sector]
  if m and m.kind ~= kind then m:Hide(); if m.extra then m.extra:Hide() end; m = nil end
  if not m then
    m = T.Shape(field, kind, T.Tone.Near)
    m.kind = kind
    m:SetDrawLayer("OVERLAY")
    if m.extra then m.extra:SetDrawLayer("OVERLAY") end
    byType[sector] = m
  end
  return m
end

-- Eased placement: a mark keeps its current (x, y) and tweens to the target.
local function PlaceMark(m, tx, ty, sizePx, now)
  if m.tx ~= tx or m.ty ~= ty then
    m.fx, m.fy = m.x or tx, m.y or ty      -- from
    m.tx, m.ty = tx, ty
    m.t0 = now
  end
  local t = m.t0 and Util.Clamp((now - m.t0) / MARK_EASE_SECONDS, 0, 1) or 1
  local e = t * (2 - t)                     -- ease-out
  m.x = (m.fx or tx) + (tx - (m.fx or tx)) * e
  m.y = (m.fy or ty) + (ty - (m.fy or ty)) * e
  m:ClearAllPoints()
  m:SetPoint("CENTER", field, "CENTER", m.x, m.y)
  local w = m.kind == "diamond" and sizePx * 0.75 or sizePx
  if m.kind == "plus" then m:SetSize(sizePx, sizePx * 0.4); if m.extra then m.extra:SetSize(sizePx * 0.4, sizePx) end
  else m:SetSize(w, w) end
  m:Show(); if m.extra then m.extra:Show() end
  return t < 1
end

-- Key ---------------------------------------------------------------------------------------
local function BuildKey(parent)
  key = CreateFrame("Frame", nil, parent)
  key:SetWidth(T.PanelWidth); key:SetHeight(1)
  key.rows = {}
  return key
end

local function AcquireKeyRow(i)
  local r = key.rows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, key)
  r:SetHeight(KEY_ROW_H)
  r.holder = CreateFrame("Frame", nil, r); r.holder:SetSize(10, KEY_ROW_H); r.holder:SetPoint("LEFT", 0, 0)
  r.name = T.Text(r, T.LabelSize, T.Tone.Near)
  r.name:SetPoint("LEFT", r.holder, "RIGHT", T.ColGap, 0); r.name:SetPoint("RIGHT", 0, 0)
  key.rows[i] = r
  return r
end

local function SetKeyShape(r, kind)
  if r.kind == kind then return end
  r.kind = kind
  if r.shape then r.shape:Hide(); if r.shape.extra then r.shape.extra:Hide() end end
  r.shape = T.Shape(r.holder, kind, T.Tone.Near)
  r.shape:SetPoint("CENTER")
end

-- Public ------------------------------------------------------------------------------------
function MapView.Attach(parent)
  if container then return container end
  container = CreateFrame("Frame", nil, parent)
  container:SetWidth(T.PanelWidth); container:SetHeight(1)
  BuildField(container); field:SetPoint("TOPLEFT", 0, 0)
  BuildKey(container); key:SetPoint("TOPLEFT", field, "BOTTOMLEFT", 0, -T.PartGap)
  return container
end

-- Collect spawns per source type across the nearby quests' unfinished objectives.
local function SpawnsByType(snap)
  local Location = NS.Location
  local byType, order = {}, {}
  if not (Location and Location.IsAvailable()) then return byType, order end
  for _, q in ipairs(snap.byCategory.nearby) do
    for _, o in ipairs(q.objectives) do
      if o.have < o.need then
        local spawns = Location.SpawnsForObjective(q, o)
        if spawns and #spawns > 0 then
          local list = byType[o.name]
          if not list then list = {}; byType[o.name] = list; order[#order + 1] = o.name end
          for _, s in ipairs(spawns) do list[#list + 1] = s end
        end
      end
    end
  end
  return byType, order
end

-- Returns height drawn and whether any mark is still easing.
function MapView.Render(snap)
  local Position = NS.Position
  local now = GetTime()          -- animation clock; snap.now is frozen per model build (see Blocks.Render)
  local range = Position.UpdateNearbyRange(snap)
  local byType, order = SpawnsByType(snap)
  local half = FIELD_PX / 2
  local anyEasing = false
  local liveTypes = {}
  for _, name in ipairs(order) do
    liveTypes[name] = true
    local kind = ShapeFor(name)
    local marks, sectors = Position.MarksFor(byType[name], range, sectorMemory[name])
    sectorMemory[name] = sectors
    local liveSectors = {}
    for _, mk in ipairs(marks) do
      liveSectors[mk.sector] = true
      local m = AcquireMark(name, mk.sector, kind)
      local ox, oy = Position.MarkOffset(mk, half - MARK_MAX_PX / 2 - 2)
      if PlaceMark(m, ox, oy, MarkSizePx(mk.share), now) then anyEasing = true end
    end
    for sector, m in pairs(marksByType[name] or {}) do
      if not liveSectors[sector] then m:Hide(); if m.extra then m.extra:Hide() end end
    end
  end
  for name, byS in pairs(marksByType) do
    if not liveTypes[name] then for _, m in pairs(byS) do m:Hide(); if m.extra then m.extra:Hide() end end end
  end
  -- key
  local ky = 0
  for i, name in ipairs(order) do
    local r = AcquireKeyRow(i)
    SetKeyShape(r, ShapeFor(name))
    r.name:SetText(name)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", key, "TOPLEFT", T.PadX, -ky); r:SetPoint("RIGHT", key, "RIGHT", -T.PadX, 0)
    r:Show()
    ky = ky + KEY_ROW_H + 2
  end
  for i = #order + 1, #key.rows do key.rows[i]:Hide() end
  if ky > 0 then ky = ky - 2 end
  key:SetHeight(math.max(1, ky))
  -- release shapes for names no longer in the log
  local inLog = {}
  for _, q in ipairs(snap.quests) do for _, o in ipairs(q.objectives) do inLog[o.name] = true end end
  for name in pairs(shapeByName) do if not inLog[name] then shapeByName[name] = nil end end
  if next(shapeByName) == nil then shapesUsed = 0 end
  if #order == 0 then container:SetHeight(1); return 0, false end
  local h = FIELD_PX + (ky > 0 and (T.PartGap + ky) or 0)
  container:SetHeight(h)
  MapView.easing = anyEasing
  return h, anyEasing
end