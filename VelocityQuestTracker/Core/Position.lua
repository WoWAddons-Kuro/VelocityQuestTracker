-- Velocity Quest Tracker: the position sampler. Supplies the player's world position in yards and
-- distances to spawns. Player position has no change event, so this samples on a low-rate ticker
-- only while the player is moving (PLAYER_STARTED_MOVING / PLAYER_STOPPED_MOVING), and reports a
-- change only when the player has moved more than VQT_Position_ReportStepYards, so the views redraw
-- on real movement and not on every sample.
--
-- VQT_PlayerWorldPos = { x, y, instanceID, uiMapID }  (yards; nil when the map is unknown, e.g. in an instance)
local ADDON_NAME, NS = ...
local Util = NS.Util

local Position = {}
NS.Position = Position

local SAMPLE_SECONDS = 0.5
local REPORT_STEP_YARDS = 15        -- VQT_Position_ReportStepYards: movement below this is not reported

local current = nil                 -- VQT_PlayerWorldPos
local lastReported = nil
local ticker = nil
local listeners = {}
local vec = CreateVector2D and CreateVector2D(0, 0)

function Position.OnMoved(fn) listeners[#listeners + 1] = fn end

function Position.Current() return current end

local function Sample()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return nil end
  local uiMapID = C_Map.GetBestMapForUnit("player")
  if not uiMapID then return nil end
  local mp = C_Map.GetPlayerMapPosition(uiMapID, "player")
  if not mp then return nil end
  local x, y = mp:GetXY()
  if not x or not y then return nil end
  if vec then vec:SetXY(x, y) else vec = { x = x, y = y } end
  local instanceID, world = C_Map.GetWorldPosFromMapPos(uiMapID, vec)
  if not world then return nil end
  return { x = world.x, y = world.y, instanceID = instanceID, uiMapID = uiMapID }
end

-- Fine-grained watch points (owner 2026-11-22). The 15 yd report step is right for the spark lines
-- but wrong for ARRIVAL: walk back to a hand-in NPC by a path under 15 yd and no report fires, so the
-- card never re-lights. Consumers register the world points they care about (hand-in spawns); a tick
-- that CROSSES a watch radius around any of them -- in either direction -- is reported regardless of
-- the step. Set wholesale per model build (Position.SetWatchPoints), so it tracks the live cards.
local watchPoints = {}              -- { { x, y, instanceID, radius } ... }
local watchInside = {}              -- index -> bool  (inside the radius at the last tick)
function Position.SetWatchPoints(points) watchPoints = points or {}; wipe(watchInside) end

local function CrossedWatch(p)
  local crossed = false
  for i, w in ipairs(watchPoints) do
    local inside = false
    if w.instanceID == p.instanceID then
      local dx, dy = w.x - p.x, w.y - p.y
      inside = (dx * dx + dy * dy) <= w.radius * w.radius
    end
    if watchInside[i] ~= nil and watchInside[i] ~= inside then crossed = true end
    watchInside[i] = inside
  end
  return crossed
end

local function Tick()
  local p = Sample()
  current = p
  if not p then return end
  local moved = not lastReported or lastReported.instanceID ~= p.instanceID
  if not moved then
    local dx, dy = p.x - lastReported.x, p.y - lastReported.y
    moved = (dx * dx + dy * dy) >= REPORT_STEP_YARDS * REPORT_STEP_YARDS
  end
  if CrossedWatch(p) then moved = true end
  if moved then
    lastReported = p
    for _, fn in ipairs(listeners) do
      local ok, err = pcall(fn, p)
      if not ok then Util.Raise("position listener", err) end
    end
  end
end

local function StartTicker()
  if ticker then return end
  Tick()
  ticker = C_Timer.NewTicker(SAMPLE_SECONDS, Tick)
end

local function StopTicker()
  if ticker then ticker:Cancel(); ticker = nil end
  Tick()   -- final sample at rest
end

-- Distance in yards from the player to a VQT_SpawnYards; nil when on another instance/continent
-- or when the player position is unknown.
function Position.DistanceTo(spawn)
  local p = current
  if not p or not spawn or spawn.instanceID ~= p.instanceID then return nil end
  local dx, dy = spawn.x - p.x, spawn.y - p.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Sorted ascending distances to a list of spawns (same instance only).
function Position.DistancesTo(spawns)
  local out = {}
  for _, s in ipairs(spawns or {}) do
    local d = Position.DistanceTo(s)
    if d then out[#out + 1] = d end
  end
  table.sort(out)
  return out
end

-- Nearby range -------------------------------------------------------------------------
-- VQT_Nearby_RangeYards = max(MIN_RANGE_YARDS, farthest spawn among the nearby objectives), the yardage
-- at the right end of the spark line and the outer edge of the map field (band width = range / 3).
-- Recomputed only when the SET of nearby objectives changes (PLAN "Range stability"): walking slides
-- markers along a steady scale instead of rescaling the whole line with every step.
local MIN_RANGE_YARDS = 600
local rangeYards = MIN_RANGE_YARDS
local rangeKey = nil                -- fingerprint of the objective set the range was computed for

local function ObjectiveSetKey(snap)
  local parts = {}
  for _, q in ipairs(snap.byCategory.nearby) do
    for _, o in ipairs(q.objectives) do if o.have < o.need then parts[#parts + 1] = q.questID .. ":" .. o.index end end
  end
  table.sort(parts)
  return table.concat(parts, ",") .. "@" .. (current and current.instanceID or "?")
end

-- Call once per model build. Returns the current range in yards.
function Position.UpdateNearbyRange(snap)
  local key = ObjectiveSetKey(snap)
  if key == rangeKey then return rangeYards end
  rangeKey = key
  local Location = NS.Location
  local farthest = 0
  if Location and Location.IsAvailable() and current then
    for _, q in ipairs(snap.byCategory.nearby) do
      for _, o in ipairs(q.objectives) do
        if o.have < o.need then
          for _, s in ipairs(Location.SpawnsForObjective(q, o) or {}) do
            local d = Position.DistanceTo(s)
            if d and d > farthest then farthest = d end
          end
        end
      end
    end
  end
  rangeYards = math.max(MIN_RANGE_YARDS, farthest)
  return rangeYards
end

function Position.NearbyRangeYards() return rangeYards end

-- Cells ----------------------------------------------------------------------------------
-- VQT_Sector: compass octant 0..7, 0 = N, 2 = E, 4 = S, 6 = W (clockwise), each 45 deg wide and
-- CENTRED on its direction (N spans -22.5..+22.5 deg).  VQT_Band: 1..3, radial third of the range.
-- World axes: GetWorldPosFromMapPos returns x = north-south (increasing north), y = east-west
-- (increasing WEST) -- WoW's world frame. dx_east = -(s.y - p.y), dy_north = s.x - p.x.
local SECTOR_DEG = 45
local ENTER_HYST_DEG = 7.5          -- a spawn must cross a sector boundary by this much to change sector
local LEAVE_HYST_DEG = 2.5          -- ...and sit back inside its old sector by this much to be sure it left

-- Bearing in degrees clockwise from north, 0..360, and distance in yards, from the player to a spawn.
function Position.BearingTo(spawn)
  local p = current
  if not p or not spawn or spawn.instanceID ~= p.instanceID then return nil, nil end
  local north = spawn.x - p.x
  local east = -(spawn.y - p.y)
  local deg = math.deg(math.atan2(east, north))
  if deg < 0 then deg = deg + 360 end
  return deg, math.sqrt(north * north + east * east)
end

-- Nearest sector for a bearing, no hysteresis.
local function RawSector(deg) return math.floor(((deg + SECTOR_DEG / 2) % 360) / SECTOR_DEG) end

-- Sector with hysteresis against a previous sector: stays in `prev` unless the bearing is more than
-- ENTER_HYST_DEG past prev's boundary (asymmetric: cheap to stay, dear to move).
function Position.SectorFor(deg, prev)
  local raw = RawSector(deg)
  if prev == nil or raw == prev then return raw end
  local centre = prev * SECTOR_DEG
  local off = (deg - centre + 540) % 360 - 180      -- signed offset from prev's centre, -180..180
  if math.abs(off) <= SECTOR_DEG / 2 + ENTER_HYST_DEG then return prev end
  return raw
end

function Position.BandFor(dist, range)
  if not dist then return nil end
  local bandWidth = range / 3
  local b = math.floor(dist / bandWidth) + 1
  if b > 3 then return 4 end              -- 4 = beyond the field: pinned to the edge
  return b
end

-- Marks -------------------------------------------------------------------------------------
-- VQT_MapMark = { sector, radiusFrac (0..1 of range), share (0..1), count }
-- One mark per (source type, sector): "there are spiders to the NE". radiusFrac is the spawn-weighted
-- mean distance in that sector over the range (clamped to 1); share is this sector's part of the
-- type's spawns in range, which drives mark SIZE in the view. prevSectors (optional, spawn -> sector)
-- carries hysteresis state across calls.
function Position.MarksFor(spawns, range, prevSectors)
  local bySector = {}
  local total = 0
  local newSectors = {}
  for i, s in ipairs(spawns or {}) do
    local deg, dist = Position.BearingTo(s)
    if deg then
      local key = s.x .. "," .. s.y
      local sector = Position.SectorFor(deg, prevSectors and prevSectors[key])
      newSectors[key] = sector
      local b = bySector[sector]
      if not b then b = { n = 0, sumDist = 0 }; bySector[sector] = b end
      b.n = b.n + 1
      b.sumDist = b.sumDist + math.min(dist, range)
      total = total + 1
    end
  end
  local marks = {}
  if total == 0 then return marks, newSectors end
  for sector, b in pairs(bySector) do
    marks[#marks + 1] = {
      sector = sector,
      radiusFrac = math.min(1, (b.sumDist / b.n) / range),
      share = b.n / total,
      count = b.n,
    }
  end
  table.sort(marks, function(a, c) return a.sector < c.sector end)
  return marks, newSectors
end

-- Field coordinates for a mark: offset in px from the field centre, north up, given half-size px.
function Position.MarkOffset(mark, halfPx)
  local rad = math.rad(mark.sector * SECTOR_DEG)
  local r = mark.radiusFrac * halfPx
  return math.sin(rad) * r, math.cos(rad) * r       -- x east, y north
end

function Position.Init()
  local f = CreateFrame("Frame")
  local haveMoveEvents = pcall(f.RegisterEvent, f, "PLAYER_STARTED_MOVING")
  if haveMoveEvents then
    f:RegisterEvent("PLAYER_STOPPED_MOVING")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:SetScript("OnEvent", function(_, event)
      if event == "PLAYER_STARTED_MOVING" then StartTicker()
      elseif event == "PLAYER_STOPPED_MOVING" then StopTicker()
      else Tick() end
    end)
    -- already moving at login / reload
    if GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0 then StartTicker() else Tick() end
  else
    -- client without movement events: sample continuously but only while speed > 0
    C_Timer.NewTicker(SAMPLE_SECONDS, function()
      if GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0 then Tick() elseif not current then Tick() end
    end)
    Tick()
  end
  Position.usingMoveEvents = haveMoveEvents
end

function Position.Status()
  local p = current
  if not p then return "position unknown" end
  return string.format("pos %.0f, %.0f (instance %d, map %d)%s", p.x, p.y, p.instanceID, p.uiMapID, Position.usingMoveEvents and "" or " [polling]")
end