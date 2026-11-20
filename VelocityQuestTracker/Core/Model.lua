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
local wasComplete = {}              -- questID -> bool  (isComplete at the last build; detects becoming complete)
local turninArrivedAt = {}          -- questID -> GetTime() when it dropped from its card onto the turn-in LINE (flash)
local lastCategory = {}             -- questID -> category at the last build (detects the card -> line transition)
local wasWatched = {}               -- questID -> bool  (stock tracked flag at the last build; a new watch = Touch)
local primed = false                -- first snapshot taken (so a login full-log is not "all new")
local dirtyState = {}
local listeners = {}                -- fn(snapshot, changes)
local focusSet = nil                -- questID -> true | nil (inter-addon focus input)

function Model.OnChanged(fn) listeners[#listeners + 1] = fn end

-- Persistence --------------------------------------------------------------------------
-- The view must come back the way it was after /reload or relog, so the activity memory lives in
-- VelocityQuestTrackerCharDB.model. GetTime() is session uptime; stored values are converted to
-- epoch seconds (time()) and back, so a 300 s window survives a reload with the right remainder.
--   VQT_ModelStore = { lastActivityAt = { [questID] = epoch }, recentUnits = { [questID] = { [objIndex] = { [unit] = epoch } } },
--                      order = { [questID] = rank }, nextRank, wasComplete = { [questID] = bool }, lastCategory = { [questID] = category },
--                      lastCounts = { [questID] = { [objIndex] = have } } }
local function EpochOffset() return time() - GetTime() end   -- epoch = GetTime() + offset

local function LoadState()
  local store = NS.chardb and NS.chardb.model
  if not store then return end
  local off = EpochOffset()
  for qid, epoch in pairs(store.lastActivityAt or {}) do lastActivityAt[qid] = epoch - off end
  for qid, objs in pairs(store.recentUnits or {}) do
    recentUnits[qid] = {}
    for oi, units in pairs(objs) do recentUnits[qid][oi] = {}; for u, epoch in pairs(units) do recentUnits[qid][oi][u] = epoch - off end end
  end
  for qid, rank in pairs(store.order or {}) do order[qid] = rank; knownQuestIDs[qid] = true end
  nextRank = store.nextRank or nextRank
  for qid, v in pairs(store.wasComplete or {}) do wasComplete[qid] = v end
  for qid, v in pairs(store.lastCategory or {}) do lastCategory[qid] = v end
  for qid, counts in pairs(store.lastCounts or {}) do lastCounts[qid] = counts end
  -- Known quests restored, so the first build after reload diffs against the saved state instead of
  -- treating the whole log as new.
  primed = next(knownQuestIDs) ~= nil
end

local function SaveState()
  if not NS.chardb then return end
  local off = EpochOffset()
  local store = { lastActivityAt = {}, recentUnits = {}, order = order, nextRank = nextRank, wasComplete = wasComplete, lastCategory = lastCategory, lastCounts = lastCounts }
  for qid, t in pairs(lastActivityAt) do store.lastActivityAt[qid] = t + off end
  for qid, objs in pairs(recentUnits) do
    store.recentUnits[qid] = {}
    for oi, units in pairs(objs) do store.recentUnits[qid][oi] = {}; for u, t in pairs(units) do store.recentUnits[qid][oi][u] = t + off end end
  end
  NS.chardb.model = store
end

function Model.Init() LoadState() end

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
    -- Became complete since the last build (last unit landed, or an errand quest that is complete on
    -- accept): that is activity too, so the quest shows as a hand-in card before it joins the line.
    if primed and q.isComplete and not wasComplete[q.questID] then Touch(q.questID, now) end
    wasComplete[q.questID] = q.isComplete and true or false
    -- Tracked == active (owner, 2026-11-20): the player ticking "track" in the quest log is activity.
    -- At login (not primed) a watched quest is also made active so the view matches the stock state.
    if q.isWatched and (not wasWatched[q.questID] or not primed) and not lastActivityAt[q.questID] then Touch(q.questID, now)
    elseif q.isWatched and primed and not wasWatched[q.questID] then Touch(q.questID, now) end
    wasWatched[q.questID] = q.isWatched and true or false
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
      knownQuestIDs[qid] = nil; lastCounts[qid] = nil; lastActivityAt[qid] = nil; recentUnits[qid] = nil; order[qid] = nil; wasComplete[qid] = nil; turninArrivedAt[qid] = nil; lastCategory[qid] = nil; wasWatched[qid] = nil
    end
  end
  primed = true
  return changes
end

-- Hand-in place name for a complete quest. QuestieDB finisher sub-zone when Location knows it
-- (M2+), else the quest-log header zone (M1 behaviour).
function Model.PlaceFor(q)
  local Location = NS.Location
  if Location and Location.IsAvailable and Location.IsAvailable() then
    local f = Location.FinisherFor(q.questID)
    if f and f.spawn then return Location.PlaceNameForArea(f.spawn.areaID) or q.zoneName end
  end
  return q.zoneName
end

-- Zone names where a quest's REMAINING work is (QuestieDB spawn zones of unfinished objectives).
-- Falls back to { q.zoneName } (the quest-log header) when QuestieDB does not know the quest.
-- "Humble Beginnings" is accepted in Stormwind, filed under Stormwind in the log, but its compass is
-- in Westfall: with QuestieDB it is a Westfall quest here.
function Model.WorkZonesFor(q)
  local Location = NS.Location
  local names = {}
  if Location and Location.IsAvailable and Location.IsAvailable() then
    for areaID in pairs(Location.WorkZonesForQuest(q)) do
      local name = Location.ZoneNameForArea(areaID)
      if name then names[#names + 1] = name end
    end
    table.sort(names)
  end
  if #names == 0 and q.zoneName then names[1] = q.zoneName end
  return names
end

local function Categorise(q, now, zone)
  local at = lastActivityAt[q.questID]
  local window = Settings().ActiveWindowSeconds or 300
  local recentlyActive = at and (now - at) < window
  -- Complete quests: a card (part 2, showing the hand-in place) while recently active, then the
  -- turn-in line. Becoming complete counts as activity (DiffCounts touches it), so a freshly
  -- finished quest -- or an errand quest accepted already complete -- always shows as a card first.
  if q.isComplete then
    if recentlyActive then return "turnin_card" end
    -- Dropped from the card onto the line just now (previous build had it as a card): stamp the
    -- arrival so the view can flash its square. Quests that were already on the line at login, or
    -- that never had a card, are not stamped.
    if lastCategory[q.questID] == "turnin_card" then turninArrivedAt[q.questID] = now end
    return "turnin"
  end
  if recentlyActive then return "active" end
  for _, name in ipairs(q.workZones) do if name == zone then return "nearby" end end
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

  local snap = { quests = {}, byCategory = { turnin = {}, turnin_card = {}, active = {}, nearby = {}, other = {} }, turninPlaces = {}, otherZones = {}, zone = zone, now = now, changes = changes }
  for _, q in ipairs(quests) do
    if not focusSet or focusSet[q.questID] then
      q.rank = Rank(q.questID)
      q.workZones = Model.WorkZonesFor(q)             -- zone names of the remaining work (1..n)
      q.category = Categorise(q, now, zone)
      -- Tracked == active, the other direction: a quest that just left active (or the hand-in card)
      -- is untracked in the stock log when "Auto-untrack inactive quests" is on. Only on the
      -- transition, so a player re-tracking it by hand is honoured (that re-track is a Touch above).
      if Settings().AutoUntrackInactive ~= false and q.isWatched then
        local was = lastCategory[q.questID]
        local nowActive = q.category == "active" or q.category == "turnin_card"
        if (was == "active" or was == "turnin_card") and not nowActive then
          if Client.SetWatched(q.questID, false) then q.isWatched = false; wasWatched[q.questID] = false end
        end
      end
      lastCategory[q.questID] = q.category
      q.lastActivityAt = lastActivityAt[q.questID]
      q.recent = recentUnits[q.questID]
      q.arrivedAt = turninArrivedAt[q.questID]       -- when it landed on the turn-in line (nil until then)
      if q.isComplete then q.turninPlace = Model.PlaceFor(q) end
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
  Group(snap.byCategory.turnin, function(q) return q.turninPlace end, snap.turninPlaces, "place")
  Group(snap.byCategory.other, function(q) return q.zoneName end, snap.otherZones, "zone")

  current = snap
  SaveState()
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