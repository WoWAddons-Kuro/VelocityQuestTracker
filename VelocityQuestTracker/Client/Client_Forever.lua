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
function impl.OpenQuestLog(questID)
  if InCombatLockdown() then return false end
  if QuestMapFrame_OpenToQuestDetails then QuestMapFrame_OpenToQuestDetails(questID); return true end
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

-- GetQuestLogQuestText([logIndex]) is present on Forever (1.60.1+); index from GetLogIndexForQuestID.
function impl.QuestText(questID)
  local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
  if not index or not GetQuestLogQuestText then return nil end
  return GetQuestLogQuestText(index)
end

local function Objectives(questID)
  local out = {}
  local objs = C_QuestLog.GetQuestObjectives(questID) or {}
  for j, o in ipairs(objs) do
    local name, have, need = Client.ParseObjectiveText(o.text)
    if o.numRequired and o.numRequired > 0 then have, need = o.numFulfilled or 0, o.numRequired end
    if not need or need < 1 then need = 1; have = o.finished and 1 or 0 end
    out[j] = { index = j, text = o.text or "", name = name, type = o.type or "log", have = have or 0, need = need, done = o.finished and true or false }
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