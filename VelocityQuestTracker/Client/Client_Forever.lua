-- Velocity Quest Tracker: WoW Forever client (Mainline-shaped C_QuestLog).
--   C_QuestLog.GetNumQuestLogEntries() -> numShownEntries, numQuests
--   C_QuestLog.GetInfo(i) -> QuestInfo { questID, title, level, isHeader, isCollapsed, ... }
--   C_QuestLog.GetQuestObjectives(questID) -> { { text, type, finished, numFulfilled, numRequired } }
--   C_QuestLog.IsComplete / IsFailed / GetQuestWatchType
local ADDON_NAME, NS = ...
local Client = NS.Client

local impl = {}
NS.ClientFlavours.forever = impl

function impl.PlayerKey() return UnitGUID("player") end
function impl.PlayerDisplayName()
  local name, surname = UnitNameUnmodified("player")
  return Client.DisplayNameFromParts(name, surname)
end
function impl.PlayerFirstName() return UnitName("player") end

-- The ZONE, never the sub-zone. GetRealZoneText() returns the interior area while the player is in
-- one ("Gol'Bolar Quarry Mine", a mine in Dun Morogh), and the model compares that string with the
-- quests' work / hand-in zone names ("Dun Morogh") -> nothing was in-zone: no active block for the
-- quest being worked, the finished one filed under "+4 in Dun Morogh" (owner 2026-11-21). Walk up
-- the map tree from the player's best map to the Zone-type ancestor and use its name; the text API is
-- only a fallback when the map is unknown (instances).
local ZONE_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
function impl.CurrentZoneName()
  if C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(C_Map.GetBestMapForUnit("player") or 0)
    local guard = 0
    while info and info.mapType > ZONE_TYPE and info.parentMapID and info.parentMapID > 0 and guard < 10 do
      info = C_Map.GetMapInfo(info.parentMapID); guard = guard + 1
    end
    if info and info.mapType == ZONE_TYPE and info.name and info.name ~= "" then return info.name end
  end
  return GetRealZoneText() or ""
end
function impl.StockTrackerFrame() return ObjectiveTrackerFrame end
function impl.QuestTimerFrame() return QuestTimerFrame end   -- Blizzard's standalone countdown; swallowed with the tracker

-- Modern quest log (map frame) takes a quest ID. Opening it from addon code is protected in combat.
-- QuestMapFrame_OpenToQuestDetails lives in Blizzard_WorldMap, a LOAD-ON-DEMAND addon: it is nil until
-- the player has opened the map/log once (pressing L loads it). Seen 2026-11-20: clicks did nothing
-- until L had been pressed. Load it ourselves, then call; fall back to OpenQuestLog / ToggleQuestLog.
local function EnsureMapUI()
  if QuestMapFrame_OpenToQuestDetails then return true end
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if load then pcall(load, "Blizzard_WorldMap") end
  if not QuestMapFrame_OpenToQuestDetails and UIParentLoadAddOn then pcall(UIParentLoadAddOn, "Blizzard_WorldMap") end
  return QuestMapFrame_OpenToQuestDetails ~= nil
end

function impl.OpenQuestLog(questID)
  if InCombatLockdown() then return false end
  if EnsureMapUI() then QuestMapFrame_OpenToQuestDetails(questID); return true end
  -- Fallbacks: the generic openers also live in the map addon but are defined in Blizzard_WorldMap.lua,
  -- which may be present when QuestMapFrame.lua's function is not.
  if OpenQuestLog then OpenQuestLog(); return true end
  if ToggleQuestLog then ToggleQuestLog(); return true end
  NS.Util.WarnOnce("openquestlog", "quest log UI not available (Blizzard_WorldMap not loaded)")
  return false
end

function impl.SetWatched(questID, watched)
  if InCombatLockdown() then return false end
  if watched then
    if C_QuestLog.AddQuestWatch then return C_QuestLog.AddQuestWatch(questID, Enum.QuestWatchType and Enum.QuestWatchType.Manual) and true or false end
  else
    if C_QuestLog.RemoveQuestWatch then return C_QuestLog.RemoveQuestWatch(questID) and true or false end
  end
  return false
end

-- GetQuestLogQuestText reads the SELECTED quest on the modern client even when passed an index
-- (the index form returned empty on 1.60.1 with nothing selected), so select, read, restore.
function impl.QuestText(questID)
  local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
  if not index or not GetQuestLogQuestText then return nil end
  local prev = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
  if C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(questID) end
  local description, objectives = GetQuestLogQuestText(index)
  if (not objectives or objectives == "") and GetQuestLogQuestText then description, objectives = GetQuestLogQuestText() end
  if prev and prev ~= questID and C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(prev) end
  return description, objectives
end

function impl.QuestItem(questID)
  local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
  return Client.QuestItemByLogIndex(index)
end

-- Two objective APIs disagree on Forever (probe 2026-11-20, Therylune's Escape 945):
--   C_QuestLog.GetQuestObjectives(id)[1]  type=event finished=false numFulfilled=0 numRequired=1
--   GetQuestLogLeaderBoard(1, logIndex)   type=event finished=TRUE
-- The legacy leaderboard carries the right `finished` for event / escort / speak-with objectives; the
-- modern struct carries the right counts for kill/collect ones. Read both and merge. `counted` is
-- by TYPE (monster/item/object/reputation have real counts; event/log/spell do not), not numRequired,
-- which is 1 for an event objective.
local NO_COUNT_TYPES = { event = true, log = true, spell = true, progressbar = true }
local function Objectives(questID, logIndex)
  local out = {}
  local objs = C_QuestLog.GetQuestObjectives(questID) or {}
  for j, o in ipairs(objs) do
    local name, have, need, textComplete = Client.ParseObjectiveText(o.text)
    local lbFinished = false
    if logIndex and GetQuestLogLeaderBoard then
      local _, _, fin = GetQuestLogLeaderBoard(j, logIndex)
      lbFinished = fin and true or false
    end
    local finished = o.finished or lbFinished or textComplete
    local counted = not NO_COUNT_TYPES[o.type or "log"] and (o.numRequired or 0) > 0
    if counted then have, need = o.numFulfilled or 0, o.numRequired end
    if not need or need < 1 then need = 1; have = finished and 1 or 0 end
    if not counted and finished then have = need end
    out[j] = { index = j, text = o.text or "", name = name, type = o.type or "log", have = have or 0, need = need, done = finished and true or false, counted = counted }
  end
  return out
end

function impl.Quests()
  local quests = {}
  local numEntries = C_QuestLog.GetNumQuestLogEntries() or 0
  -- Timed quests (SPEC-VQT-TimedQuests): C_QuestLog.GetQuestTimers() lists RUNNING timers only, questTimer =
  -- seconds remaining. GetTimeAllowed(questID) adds the total (may return nothing; pcall'd).
  local timerSecondsByQuestID = {}
  if C_QuestLog.GetQuestTimers then
    local ok, list = pcall(C_QuestLog.GetQuestTimers)
    if ok and type(list) == "table" then
      for _, t in ipairs(list) do
        if t and t.questID and type(t.questTimer) == "number" then timerSecondsByQuestID[t.questID] = t.questTimer end
      end
    end
  end
  local function TimerTotal(questID)
    if not C_QuestLog.GetTimeAllowed then return nil end
    local ok, total = pcall(C_QuestLog.GetTimeAllowed, questID)
    return ok and type(total) == "number" and total > 0 and total or nil
  end
  local sampledAt = GetTime()
  local header
  for i = 1, numEntries do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        header = info.title
      elseif info.questID and info.questID > 0 and not info.isHidden then
        local qid = info.questID
        local objectives = Objectives(qid, i)
        local timerLeft = timerSecondsByQuestID[qid]
        quests[#quests + 1] = {
          questID = qid, title = info.title or ("quest " .. qid), level = info.level or 0,
          isComplete = Client.DeriveComplete(C_QuestLog.IsComplete(qid), objectives),
          isFailed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(qid) and true or false,
          isWatched = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(qid) ~= nil or false,
          zoneName = header,
          timerRemainingSeconds = timerLeft,
          timerSampledAt = timerLeft and sampledAt or nil,
          timerTotalSeconds = timerLeft and TimerTotal(qid) or nil,
          objectives = objectives,
        }
      end
    end
  end
  return quests
end