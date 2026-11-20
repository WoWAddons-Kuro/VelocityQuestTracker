-- Velocity Quest Tracker: the Location layer over QuestieDB (LibQuestieDB contract 4).
-- Answers two questions: where are the spawns for this objective, and where is this quest handed in.
-- API notes: AddonManagement\_EXTERNAL_APIS\questiedb_contract_4.md. Everything here degrades to nil
-- when QuestieDB is absent or does not know the quest; callers draw the M1 placeholder in that case.
--
-- Terms:
--   VQT_Source     = { kind = "npc"|"object", id, name }  one thing in the world the player looks for
--   VQT_SpawnYards = { x, y, instanceID, areaID }          one spawn point in world yards
--   areaID         = Questie/DBC AreaId (zone or sub-zone); uiMapID = Blizzard C_Map id
local ADDON_NAME, NS = ...
local Util = NS.Util

local Location = {}
NS.Location = Location

local REQUIRED_CONTRACT = 4
local available = false
local unavailableReason = "not checked"

-- zone tables decoded from LibQuestieDB.Support.Get("ZoneDB").private
local areaIdToUiMapId = {}
local uiMapIdToAreaId = {}
local subZoneToParentZone = {}

-- caches (cleared on Location.Reset)
local spawnCache = {}           -- "npc:123" | "object:456" -> { VQT_SpawnYards... }
local objectiveSourceCache = {} -- questID -> { [objIndex] = { VQT_Source... } }
local finisherCache = {}        -- questID -> { source = VQT_Source, spawn = VQT_SpawnYards } | false

local function DecodeTable(src)
  if type(src) == "table" then return src end
  if type(src) ~= "string" then return {} end
  local chunk = loadstring(src)
  if not chunk then return {} end
  local ok, t = pcall(chunk)
  return (ok and type(t) == "table") and t or {}
end

local function Merge(base, override) for k, v in pairs(override) do base[k] = v end; return base end

function Location.Init()
  if not LibQuestieDB then unavailableReason = "QuestieDB not loaded"; return false end
  local ok, msg = LibQuestieDB.RequireContract(REQUIRED_CONTRACT)
  if not ok then unavailableReason = msg or "contract mismatch"; Util.WarnOnce("questiedb", unavailableReason); return false end
  local zone = LibQuestieDB.Support and LibQuestieDB.Support.Get and LibQuestieDB.Support.Get("ZoneDB")
  local p = zone and zone.private
  if p then
    areaIdToUiMapId = Merge(DecodeTable(p.areaIdToUiMapId), DecodeTable(p.areaIdToUiMapIdOverride))
    uiMapIdToAreaId = Merge(DecodeTable(p.uiMapIdToAreaId), DecodeTable(p.uiMapIdToAreaIdOverride))
    subZoneToParentZone = Merge(DecodeTable(p.subZoneToParentZone), DecodeTable(p.subZoneToParentZoneOverride))
  else
    Util.WarnOnce("questiedb-zones", "QuestieDB zone tables not found; distances disabled")
  end
  available = true
  unavailableReason = nil
  return true
end

function Location.IsAvailable() return available end
function Location.Status()
  if available then return string.format("QuestieDB contract %s (%s), %d zones", tostring(LibQuestieDB.contractVersion), tostring(LibQuestieDB.readMode), (function() local n = 0 for _ in pairs(areaIdToUiMapId) do n = n + 1 end return n end)()) end
  return "QuestieDB unavailable: " .. tostring(unavailableReason)
end

function Location.Reset() wipe(spawnCache); wipe(objectiveSourceCache); wipe(finisherCache) end

-- Zones --------------------------------------------------------------------------------
function Location.UiMapForArea(areaID) return areaIdToUiMapId[areaID] end
function Location.AreaForUiMap(uiMapID) return uiMapIdToAreaId[uiMapID] end
function Location.ParentZone(areaID) return subZoneToParentZone[areaID] or areaID end

-- Localised zone name for an AreaId, via its parent zone's UiMap.
function Location.ZoneNameForArea(areaID)
  local parent = Location.ParentZone(areaID)
  local uiMap = areaIdToUiMapId[parent] or areaIdToUiMapId[areaID]
  if uiMap and uiMap > 0 and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(uiMap)
    if info and info.name then return info.name end
  end
  if C_Map.GetAreaInfo then return C_Map.GetAreaInfo(parent) or C_Map.GetAreaInfo(areaID) end
  return nil
end

-- Sub-zone (settlement) name for an AreaId: the area's own name when it is a sub-zone, else the zone.
function Location.PlaceNameForArea(areaID)
  if C_Map.GetAreaInfo then
    local n = C_Map.GetAreaInfo(areaID)
    if n and n ~= "" then return n end
  end
  return Location.ZoneNameForArea(areaID)
end

-- Spawns -------------------------------------------------------------------------------
local vec = CreateVector2D and CreateVector2D(0, 0)

-- zone-percent (0..100) on an AreaId -> VQT_SpawnYards or nil
local function ToYards(areaID, x, y)
  if x == -1 or y == -1 then return nil end
  local uiMap = areaIdToUiMapId[areaID]
  if not uiMap or uiMap == 0 or not C_Map.GetWorldPosFromMapPos then return nil end
  if vec then vec:SetXY(x / 100, y / 100) else vec = { x = x / 100, y = y / 100 } end
  local instanceID, world = C_Map.GetWorldPosFromMapPos(uiMap, vec)
  if not world then return nil end
  return { x = world.x, y = world.y, instanceID = instanceID, areaID = areaID }
end

-- All spawns of one source in yards (cached). Returns an array of VQT_SpawnYards (may be empty).
function Location.SpawnsFor(source)
  local key = source.kind .. ":" .. source.id
  local c = spawnCache[key]
  if c then return c end
  local out = {}
  if available then
    local db = source.kind == "npc" and NpcDB or ObjectDB
    local list = db and db.spawns and db.spawns(source.id)
    if list then
      for areaID, coords in pairs(list) do
        for _, xy in ipairs(coords) do
          local s = ToYards(areaID, xy[1], xy[2])
          if s then out[#out + 1] = s end
        end
      end
    end
  end
  spawnCache[key] = out
  return out
end

-- Objective -> sources ----------------------------------------------------------------
local function NameOf(kind, id)
  if kind == "npc" then return NpcDB.name(id) elseif kind == "object" then return ObjectDB.name(id) end
  return ItemDB.name(id)
end

-- Build Questie's ObjectiveData order (see _EXTERNAL_APIS note) as a flat list of
--   { type = "monster"|"object"|"item"|"reputation"|"killcredit"|"spell", id, text }
local function QuestieObjectiveList(questID)
  local objs = QuestDB.objectives(questID)
  if not objs then return nil end
  local first = LibQuestieDB.ObjectiveFirst or {}
  local list = {}
  local function add(entry, prepend) if prepend then table.insert(list, 1, entry) else list[#list + 1] = entry end end
  for _, c in ipairs(objs[1] or {}) do add({ type = "monster", id = c[1], text = c[2] }) end
  for _, o in ipairs(objs[2] or {}) do add({ type = "object", id = o[1], text = o[2] }, first.objectObjectiveFirst and first.objectObjectiveFirst[questID]) end
  for _, i in ipairs(objs[3] or {}) do add({ type = "item", id = i[1], text = i[2] }, first.itemObjectiveFirst and first.itemObjectiveFirst[questID]) end
  if objs[4] then add({ type = "reputation", id = objs[4][1] }) end
  for _, k in ipairs(objs[5] or {}) do add({ type = "killcredit", id = k[2], idList = k[1], text = k[3] }, first.killCreditObjectiveFirst and first.killCreditObjectiveFirst[questID]) end
  for _, s in ipairs(objs[6] or {}) do add({ type = "spell", id = s[1], text = s[2], itemID = s[3] }, first.spellObjectiveFirst and first.spellObjectiveFirst[questID]) end
  return list
end

-- Expand one Questie objective entry to VQT_Source list.
local function SourcesOf(entry)
  local out = {}
  if entry.type == "monster" then
    out[1] = { kind = "npc", id = entry.id, name = NpcDB.name(entry.id) }
  elseif entry.type == "killcredit" then
    for _, id in ipairs(entry.idList or {}) do out[#out + 1] = { kind = "npc", id = id, name = NpcDB.name(id) } end
    if #out == 0 and entry.id then out[1] = { kind = "npc", id = entry.id, name = NpcDB.name(entry.id) } end
  elseif entry.type == "object" then
    out[1] = { kind = "object", id = entry.id, name = ObjectDB.name(entry.id) }
  elseif entry.type == "item" or entry.type == "spell" then
    local itemID = entry.type == "item" and entry.id or entry.itemID
    if itemID then
      for _, id in ipairs(ItemDB.npcDrops(itemID) or {}) do out[#out + 1] = { kind = "npc", id = id, name = NpcDB.name(id) } end
      for _, id in ipairs(ItemDB.objectDrops(itemID) or {}) do out[#out + 1] = { kind = "object", id = id, name = ObjectDB.name(id) } end
    end
  end
  return out
end

local BLIZZ_TYPE_TO_QUESTIE = { monster = "monster", item = "item", object = "object", reputation = "reputation", spell = "spell" }

-- For a VQT_Quest from the client, return { [objIndex] = { VQT_Source... } } (cached per quest).
-- Matching: type+name first (NPC/object/item name == objective name minus count, or objective name
-- starts with it), then falls back to Questie's positional order.
function Location.SourcesForQuest(quest)
  local c = objectiveSourceCache[quest.questID]
  if c then return c end
  local result = {}
  objectiveSourceCache[quest.questID] = result
  if not available or not QuestDB.Exists(quest.questID) then return result end
  local list = QuestieObjectiveList(quest.questID)
  if not list then return result end
  local used = {}
  -- pass 1: name match
  for _, o in ipairs(quest.objectives) do
    local want = BLIZZ_TYPE_TO_QUESTIE[o.type]
    local oname = (o.name or ""):lower():gsub("%s+slain$", ""):gsub("%s+killed$", "")
    for li, e in ipairs(list) do
      if not used[li] and (not want or e.type == want or (want == "monster" and e.type == "killcredit")) then
        local ename = e.text or (e.type == "item" and ItemDB.name(e.id)) or (e.type == "object" and ObjectDB.name(e.id)) or NpcDB.name(e.id)
        ename = ename and ename:lower()
        if ename and (ename == oname or oname:find(ename, 1, true) == 1) then
          result[o.index] = SourcesOf(e); used[li] = true; break
        end
      end
    end
  end
  -- pass 2: positional fallback for anything unmatched
  local li = 1
  for _, o in ipairs(quest.objectives) do
    if not result[o.index] then
      while li <= #list and used[li] do li = li + 1 end
      if li <= #list then result[o.index] = SourcesOf(list[li]); used[li] = true; li = li + 1 else result[o.index] = {} end
    end
  end
  return result
end

-- Spawns for one objective: array of VQT_SpawnYards across all its sources.
function Location.SpawnsForObjective(quest, objective)
  local srcs = Location.SourcesForQuest(quest)[objective.index]
  if not srcs or #srcs == 0 then return nil end
  local out = {}
  for _, s in ipairs(srcs) do for _, sp in ipairs(Location.SpawnsFor(s)) do out[#out + 1] = sp end end
  return out
end

-- Zone attribution for a quest's remaining work: set of parent AreaIds with spawns of unfinished
-- objectives. Empty when unknown.
function Location.WorkZonesForQuest(quest)
  local zones = {}
  if not available then return zones end
  for _, o in ipairs(quest.objectives) do
    if not o.done then
      local spawns = Location.SpawnsForObjective(quest, o)
      for _, sp in ipairs(spawns or {}) do zones[Location.ParentZone(sp.areaID)] = true end
    end
  end
  return zones
end

-- Turn-in --------------------------------------------------------------------------
-- Returns { source = VQT_Source, spawn = VQT_SpawnYards } or nil. Forever quest POIs first (M3).
function Location.FinisherFor(questID)
  local c = finisherCache[questID]
  if c ~= nil then return c or nil end
  local found = false
  if available and QuestDB.Exists(questID) then
    local fb = QuestDB.finishedBy(questID)
    local src
    if fb and fb[1] and fb[1][1] then src = { kind = "npc", id = fb[1][1], name = NpcDB.name(fb[1][1]) }
    elseif fb and fb[2] and fb[2][1] then src = { kind = "object", id = fb[2][1], name = ObjectDB.name(fb[2][1]) } end
    if src then
      local spawns = Location.SpawnsFor(src)
      found = { source = src, spawn = spawns[1] }
    end
  end
  finisherCache[questID] = found
  return found or nil
end

-- Diagnostic: /vqt loc <questID>
function Location.Dump(quest)
  Util.DumpHeader("/vqt loc " .. quest.questID)
  Util.Print("%s | quest %d %s | known=%s", Location.Status(), quest.questID, quest.title, tostring(available and QuestDB.Exists(quest.questID)))
  local srcs = Location.SourcesForQuest(quest)
  for _, o in ipairs(quest.objectives) do
    local list = srcs[o.index] or {}
    local n = 0
    for _, s in ipairs(list) do n = n + #Location.SpawnsFor(s) end
    print(string.format("  %d. %s [%s] -> %d source(s), %d spawn(s)", o.index, o.name, o.type, #list, n))
    for _, s in ipairs(list) do print(string.format("       %s %d %s", s.kind, s.id, tostring(s.name))) end
  end
  local f = Location.FinisherFor(quest.questID)
  if f then print(string.format("  finisher: %s %d %s at area %s (%s)", f.source.kind, f.source.id, tostring(f.source.name), f.spawn and tostring(f.spawn.areaID) or "?", f.spawn and tostring(Location.PlaceNameForArea(f.spawn.areaID)) or "?")) else print("  finisher: unknown") end
  Util.DumpFooter("/vqt loc " .. quest.questID)
end