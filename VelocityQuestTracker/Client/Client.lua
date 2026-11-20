-- Velocity Quest Tracker: the client interface. Flavour files (Client_*.lua) each implement
-- every method listed in Client.INTERFACE; Client_Select.lua binds the right one onto NS.Client.
-- No use site may call UnitName / C_QuestLog / GetQuestLogTitle directly: it goes through here.
--
-- Snapshot shape returned by Client.Quests():
--   VQT_Quest = {
--     questID   = number,
--     title     = string,
--     level     = number,            -- quest level for difficulty colour
--     isComplete = boolean,          -- every objective done (or the log says complete)
--     isFailed  = boolean,
--     isWatched = boolean,           -- stock tracker flag; read, not yet used
--     zoneName  = string|nil,        -- the quest log header this quest sits under
--     objectives = { VQT_Objective, ... }
--   }
--   VQT_Objective = {
--     index = number,                -- 1-based, Blizzard order
--     text  = string,                -- "Young Nightsaber slain: 6/7"
--     name  = string,                -- text with the trailing count removed
--     type  = string,                -- "monster" | "item" | "object" | "event" | "reputation" | "log" | ...
--     have  = number,
--     need  = number,                -- >= 1 (no-count objectives report need = 1)
--     done  = boolean,
--   }
local ADDON_NAME, NS = ...

local Client = {}
NS.Client = Client
NS.ClientFlavours = {}

Client.INTERFACE = {
  "PlayerKey",          -- -> UnitGUID("player")  (the only per-character key)
  "PlayerDisplayName",  -- -> "Kuro" (Era) | "Kuro Oakheart" (Forever)
  "PlayerFirstName",    -- -> UnitName("player")
  "Quests",             -- -> { VQT_Quest, ... } for the whole log
  "StockTrackerFrame",  -- -> Frame|nil  the Blizzard quest tracker to hide
  "CurrentZoneName",    -- -> string      GetRealZoneText()
  "OpenQuestLog",       -- (questID)      open the game's quest log to this quest; no-op in combat
  "SetWatched",         -- (questID, bool) set the stock "tracked" flag (the model keeps tracked == active)
}

-- Shared helpers for the flavour files ------------------------------------------------

-- "Young Nightsaber slain: 6/7" -> "Young Nightsaber slain", 6, 7
-- "Speak with Melithar"         -> "Speak with Melithar", nil, nil
function Client.ParseObjectiveText(text)
  text = text or ""
  local name, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)%s*$")
  if name then return name, tonumber(have), tonumber(need) end
  return text, nil, nil
end

function Client.DisplayNameFromParts(name, surname)
  if surname and surname ~= "" then return name .. " " .. surname end
  return name
end

-- Complete means every objective is done. The log's own flag (C_QuestLog.IsComplete / the
-- GetQuestLogTitle isComplete field) is the authority ONLY when there are no counted objectives
-- (errand / "speak with" quests, which can arrive complete). Seen on Forever: IsComplete(399) true
-- while "0/1 A Simple Compass" was outstanding, which put the quest on the turn-in line.
function Client.DeriveComplete(logSaysComplete, objectives)
  if #objectives == 0 then return logSaysComplete and true or false end
  for _, o in ipairs(objectives) do
    if not o.done and o.have < o.need then return false end
  end
  return true
end