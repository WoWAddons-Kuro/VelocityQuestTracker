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

local function Tick()
  local p = Sample()
  current = p
  if not p then return end
  local moved = not lastReported or lastReported.instanceID ~= p.instanceID
  if not moved then
    local dx, dy = p.x - lastReported.x, p.y - lastReported.y
    moved = (dx * dx + dy * dy) >= REPORT_STEP_YARDS * REPORT_STEP_YARDS
  end
  if moved then
    lastReported = p
    for _, fn in ipairs(listeners) do
      local ok, err = pcall(fn, p)
      if not ok then Util.WarnOnce("position-listener", err) end
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