-- Velocity Quest Tracker: the model. Derived entirely from the client's quest snapshot plus
-- a little memory (last counts, activity timestamps, insertion order). Rebuilt once per frame
-- when dirty; the view reads Model.Current() and never touches the client.
--
-- Categories (PLAN "Actionable vs nearby"):
--   turnin   : quest.isComplete                          -> part 1, grouped by zoneName (M1) / finisher place (M3)
--   active   : not complete AND GetTime() - lastActivityAt < ActiveWindowSeconds  -> part 2 block
--   nearby   : not complete, not active, zoneName == current zone                   -> part 3 line view
--   other    : not complete, not active, zoneName ~= current zone                   -> part 4, grouped by zoneName
--
-- Slot stability: VQT_Model_Order keeps the questID insertion order across rebuilds; a quest
-- first seen is appended. Objective order is Blizzard's index order and never changes.
local ADDON_NAME, NS = ...
local Util, Client = NS.Util, NS.Client

local Model = {}
NS.Model = Model

local current = nil                 -- VQT_Model_Snapshot (see Build)
local lastCounts = {}               -- questID -> { [objIndex] = have }
local lastActivityAt = {}           -- questID -> GetTime()
local recentUnits = {}              -- questID -> objIndex -> { [unitIndex] = GetTime() }  (units that popped recently)
local order = {}                    -- questID -> insertion rank
local nextRank = 1
local knownQuestIDs = {}            -- questID -> true  (quests seen in a previous snapshot)
local primed = false                -- first snapshot taken (so a login full-log is not "all new")
local dirtyState = {}
local listeners = {}                -- fn(snapshot, changes)
local focusSet = nil                -- questID -> true | nil (inter-addon focus input)

function Model.OnChanged(fn) listeners[#listeners + 1] = fn end

local function Settings() return NS.db and NS.db.settings or {} end

-- Inter-addon: nil clears the focus; a table of questIDs (array or set) restricts the view.
function Model.SetFocus(ids)
  if ids == nil then focusSet = nil
  else
    focusSet = {}
    for k, v in pairs(ids) do
      if type(v) == "number" then focusSet[v] = true elseif v == true then focusSet[k] = true end
    end
  end
  Model.MarkDirty("focus")
end

function Model.HasFocus() return focusSet ~= nil end

local function Rank(questID)
  if not order[questID] then order[questID] = nextRank; nextRank = nextRank + 1 end
  return order[questID]
end

local function Touch(questID, now) lastActivityAt[questID] = now end

-- Compare snapshot counts to the last build. Returns changes = { { questID, objIndex, from, to }, ... }
local function DiffCounts(quests, now)
  local changes = {}
  local seen = {}
  for _, q in ipairs(quests) do
    seen[q.questID] = true
    local prev = lastCounts[q.questID]
    local isNew = not knownQuestIDs[q.questID]
    if isNew and primed then Touch(q.questID, now) end      -- accepted during play -> active
    local cur = {}
    for _, o in ipairs(q.objectives) do
      cur[o.index] = o.have
      local before = prev and prev[o.index]
      if before ~= nil and o.have > before then
        changes[#changes + 1] = { questID = q.questID, objIndex = o.index, from = before, to = o.have }
        Touch(q.questID, now)
        recentUnits[q.questID] = recentUnits[q.questID] or {}
        recentUnits[q.questID][o.index] = recentUnits[q.questID][o.index] or {}
        for u = before + 1, o.have do recentUnits[q.questID][o.index][u] = now end
      end
    end
    lastCounts[q.questID] = cur
    knownQuestIDs[q.questID] = true
  end
  -- forget quests that left the log
  for qid in pairs(knownQuestIDs) do
    if not seen[qid] then
      knownQuestIDs[qid] = nil; lastCounts[qid] = nil; lastActivityAt[qid] = nil; recentUnits[qid] = nil; order[qid] = nil
    end
  end
  primed = true
  return changes
end

local function Categorise(q, now, zone)
  if q.isComplete then return "turnin" end
  local at = lastActivityAt[q.questID]
  local window = Settings().ActiveWindowSeconds or 300
  if at and (now - at) < window then return "active" end
  if q.zoneName == zone then return "nearby" end
  return "other"
end

-- Build VQT_Model_Snapshot:
--   { quests = { VQT_Quest + rank + category + recent }, byCategory = { turnin = {...}, active = {...}, nearby = {...}, other = {...} },
--     turninPlaces = { { place, quests } ... }, otherZones = { { zone, quests } ... }, zone = string, now = number }
function Model.Build()
  local now = GetTime()
  local zone = Client.CurrentZoneName() or ""
  local quests = Client.Quests() or {}
  local changes = DiffCounts(quests, now)

  local snap = { quests = {}, byCategory = { turnin = {}, active = {}, nearby = {}, other = {} }, turninPlaces = {}, otherZones = {}, zone = zone, now = now, changes = changes }
  for _, q in ipairs(quests) do
    if not focusSet or focusSet[q.questID] then
      q.rank = Rank(q.questID)
      q.category = Categorise(q, now, zone)
      q.lastActivityAt = lastActivityAt[q.questID]
      q.recent = recentUnits[q.questID]
      snap.quests[#snap.quests + 1] = q
      local bucket = snap.byCategory[q.category]
      bucket[#bucket + 1] = q
    end
  end
  for _, bucket in pairs(snap.byCategory) do
    table.sort(bucket, function(a, b) return a.rank < b.rank end)
  end

  -- group turn-ins by place (M1: header zone), other-zone by zone; groups keep first-seen order
  local function Group(list, keyFn, out, keyName)
    local idx = {}
    for _, q in ipairs(list) do
      local key = keyFn(q) or "?"
      local g = idx[key]
      if not g then g = { [keyName] = key, quests = {} }; idx[key] = g; out[#out + 1] = g end
      g.quests[#g.quests + 1] = q
    end
  end
  Group(snap.byCategory.turnin, function(q) return q.zoneName end, snap.turninPlaces, "place")
  Group(snap.byCategory.other, function(q) return q.zoneName end, snap.otherZones, "zone")

  current = snap
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, snap, changes)
    if not ok then Util.WarnOnce("listener:" .. tostring(err), err) end
  end
  return snap
end

function Model.Current() return current or Model.Build() end

function Model.MarkDirty(reason)
  Util.NextFrameOnce(dirtyState, "rebuild", Model.Build)
end

-- Timer-driven re-categorisation: a quest ages out of "active" with no event. Called by a ticker.
function Model.Tick()
  if not current then return end
  local now = GetTime()
  local window = Settings().ActiveWindowSeconds or 300
  for _, q in ipairs(current.byCategory.active) do
    local at = lastActivityAt[q.questID]
    if not at or (now - at) >= window then Model.MarkDirty("aged"); return end
  end
end

-- Dev helper: force a quest active (e.g. /vqt touch <id>)
function Model.TouchQuest(questID) Touch(questID, GetTime()); Model.MarkDirty("touch") end

function Model.Dump()
  local s = Model.Current()
  Util.Print("zone %s | %d quests | turnin %d, active %d, nearby %d, other %d%s", s.zone, #s.quests,
    #s.byCategory.turnin, #s.byCategory.active, #s.byCategory.nearby, #s.byCategory.other, focusSet and " | FOCUS" or "")
  for _, q in ipairs(s.quests) do
    print(string.format("  [%s] %d %s (L%d)%s%s zone=%s", q.category, q.questID, q.title, q.level,
      q.isComplete and " COMPLETE" or "", q.isWatched and " watched" or "", tostring(q.zoneName)))
    for _, o in ipairs(q.objectives) do
      print(string.format("      %d. %s  %d/%d %s%s", o.index, o.name, o.have, o.need, o.type, o.done and " done" or ""))
    end
  end
end