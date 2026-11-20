-- Velocity Quest Tracker: Classic Era client. Index-based quest log API.
--   GetNumQuestLogEntries() -> numEntries, numQuests
--   GetQuestLogTitle(i)     -> title, level, questTag, isHeader, isCollapsed, isComplete(1|-1|nil), frequency, questID
--   GetNumQuestLeaderBoards(i), GetQuestLogLeaderBoard(j, i) -> text, type, finished
--   C_QuestLog.GetQuestObjectives(questID) exists on Era too (numFulfilled / numRequired) and is
--   preferred for counts; the leaderboard text is the fallback.
--   IsQuestWatched(i)
local ADDON_NAME, NS = ...
local Client = NS.Client

local impl = {}
NS.ClientFlavours.classic_era = impl

function impl.PlayerKey() return UnitGUID("player") end
function impl.PlayerDisplayName() return UnitName("player") end
function impl.PlayerFirstName() return UnitName("player") end
function impl.CurrentZoneName() return GetRealZoneText() or "" end
function impl.StockTrackerFrame() return QuestWatchFrame end

-- Era quest log is index-based: select the entry, then show the standalone log frame.
function impl.OpenQuestLog(questID)
  if InCombatLockdown() then return false end
  local index = GetQuestLogIndexByID and GetQuestLogIndexByID(questID)
  if not index or index == 0 then return false end
  SelectQuestLogEntry(index)
  local frame = QuestLogExFrame or ClassicQuestLog or QuestLogFrame
  if frame then ShowUIPanel(frame); return true end
  return false
end

-- Era: AddQuestWatch / RemoveQuestWatch take a quest-log INDEX.
function impl.SetWatched(questID, watched)
  if InCombatLockdown() then return false end
  local index = GetQuestLogIndexByID and GetQuestLogIndexByID(questID)
  if not index or index == 0 then return false end
  if watched then if AddQuestWatch then AddQuestWatch(index); return true end
  else if RemoveQuestWatch then RemoveQuestWatch(index); return true end end
  return false
end

local function Objectives(logIndex, questID)
  local out = {}
  local rich = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  local n = GetNumQuestLeaderBoards(logIndex) or 0
  for j = 1, n do
    local text, otype, finished = GetQuestLogLeaderBoard(j, logIndex)
    local name, have, need = Client.ParseObjectiveText(text)
    local r = rich and rich[j]
    if r and r.numRequired and r.numRequired > 0 then have, need = r.numFulfilled or have or 0, r.numRequired end
    if not need or need < 1 then need = 1; have = finished and 1 or 0 end
    out[j] = { index = j, text = text or "", name = name, type = otype or "log", have = have or 0, need = need, done = finished and true or false }
  end
  return out
end

function impl.Quests()
  local quests = {}
  local numEntries = GetNumQuestLogEntries() or 0
  local header
  for i = 1, numEntries do
    local title, level, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
    if isHeader then
      header = title
    elseif questID and questID > 0 then
      local objectives = Objectives(i, questID)
      quests[#quests + 1] = {
        questID = questID, title = title or ("quest " .. questID), level = level or 0,
        isComplete = Client.DeriveComplete(isComplete == 1 or isComplete == true, objectives),
        isFailed = isComplete == -1,
        isWatched = IsQuestWatched and IsQuestWatched(i) and true or false,
        zoneName = header,
        objectives = objectives,
      }
    end
  end
  return quests
end