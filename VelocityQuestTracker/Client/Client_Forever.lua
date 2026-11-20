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
function impl.CurrentZoneName() return GetRealZoneText() or "" end
function impl.StockTrackerFrame() return ObjectiveTrackerFrame end

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

local function Objectives(questID)
  local out = {}
  local objs = C_QuestLog.GetQuestObjectives(questID) or {}
  for j, o in ipairs(objs) do
    local name, have, need, textComplete = Client.ParseObjectiveText(o.text)
    local finished = o.finished or textComplete
    if o.numRequired and o.numRequired > 0 then have, need = o.numFulfilled or 0, o.numRequired end
    if not need or need < 1 then need = 1; have = finished and 1 or 0 end
    out[j] = { index = j, text = o.text or "", name = name, type = o.type or "log", have = have or 0, need = need, done = finished and true or false, counted = (o.numRequired or 0) > 0 }
  end
  return out
end

function impl.Quests()
  local quests = {}
  local numEntries = C_QuestLog.GetNumQuestLogEntries() or 0
  local header
  for i = 1, numEntries do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        header = info.title
      elseif info.questID and info.questID > 0 and not info.isHidden then
        local qid = info.questID
        local objectives = Objectives(qid)
        quests[#quests + 1] = {
          questID = qid, title = info.title or ("quest " .. qid), level = info.level or 0,
          isComplete = Client.DeriveComplete(C_QuestLog.IsComplete(qid), objectives),
          isFailed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(qid) and true or false,
          isWatched = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(qid) ~= nil or false,
          zoneName = header,
          objectives = objectives,
        }
      end
    end
  end
  return quests
end