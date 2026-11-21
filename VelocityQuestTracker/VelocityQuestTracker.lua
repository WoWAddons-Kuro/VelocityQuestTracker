-- Velocity Quest Tracker: bootstrap. Saved variables, slash commands, event wiring, staged init.
local ADDON_NAME, NS = ...
local Util, Client, Model = NS.Util, NS.Client, NS.Model

_G.VelocityQuestTracker = NS     -- public: VelocityQuestTracker.SetFocus(ids|nil)

local DB_VERSION = 1

-- VQT_Settings (account-wide, VelocityQuestTrackerDB.settings)
local DEFAULT_SETTINGS = {
  Enabled = true,
  LockPosition = true,
  RequireShiftToInteract = false,
  RequireShiftForHover = false,
  ActiveWindowSeconds = 300,
  ErrandGraceSeconds = 120,              -- a just-completed quest is a hand-in card even out of zone for this long
  HoldSeconds = 4,
  FadeSeconds = 1,
  HideCompletedSegments = false,
  HideCompletedRows = false,
  AutoUntrackInactive = true,
  LinearSparkScale = false,
  ObjectiveCountMode = "remaining",     -- "remaining" | "completed"  (Options: "Show objectives as")
  ExperimentalMapMode = false,          -- map view + Map|Range strip; off = Range list only
}

local function InitDB()
  VelocityQuestTrackerDB = type(VelocityQuestTrackerDB) == "table" and VelocityQuestTrackerDB or {}
  VelocityQuestTrackerCharDB = type(VelocityQuestTrackerCharDB) == "table" and VelocityQuestTrackerCharDB or {}
  local db = VelocityQuestTrackerDB
  db.version = db.version or DB_VERSION
  db.settings = Util.ApplyDefaults(db.settings or {}, DEFAULT_SETTINGS)
  VelocityQuestTrackerCharDB.version = VelocityQuestTrackerCharDB.version or DB_VERSION
  VelocityQuestTrackerCharDB.nearbyView = VelocityQuestTrackerCharDB.nearbyView or "range"
  NS.db = db
  NS.chardb = VelocityQuestTrackerCharDB
end

-- Public inter-addon API --------------------------------------------------------------
function NS.SetFocus(ids) Model.SetFocus(ids) end

-- Settings reactions ------------------------------------------------------------------
local function ApplyEnabled()
  local on = NS.db.settings.Enabled
  NS.StockTracker.Apply(on)
  NS.Panel.SetShown(on)
end

function NS.OnSettingChanged(key)
  if key == "Enabled" then ApplyEnabled()
  elseif key == "LockPosition" then NS.EditMode.ApplyLock()
  else Model.MarkDirty(key) end
end

-- Slash -------------------------------------------------------------------------------
local function Slash(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  if cmd == "" then
    NS.db.settings.Enabled = not NS.db.settings.Enabled; ApplyEnabled(); NS.Options.Refresh()
    Util.Print("tracker %s", NS.db.settings.Enabled and "enabled" or "disabled")
  elseif cmd == "options" or cmd == "config" or cmd == "settings" then NS.Options.Open()
  elseif cmd == "dump" then Model.Dump()
  elseif cmd == "view" then
    if rest == "map" and not NS.Panel.MapModeEnabled() then Util.Print("map view is off: tick \"Experimental map mode\" in /vqt options")
    elseif rest == "map" or rest == "range" then NS.Panel.SetNearbyView(rest) end
    Util.Print("nearby view: %s  (range %d yd)", NS.Panel.NearbyView(), NS.Position.NearbyRangeYards())
  elseif cmd == "probe" then
    -- Raw client API for one quest, unfiltered: what the game says vs what our adapter derived.
    local id = tonumber(rest)
    if not id then Util.Print("usage: /vqt probe <questID>") return end
    Util.DumpHeader("/vqt probe " .. id)
    local function P(fmt, ...) print(string.format(fmt, ...)) end
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
      local idx = C_QuestLog.GetLogIndexForQuestID(id)
      P("  C_QuestLog.GetLogIndexForQuestID = %s", tostring(idx))
      P("  C_QuestLog.IsComplete = %s   IsFailed = %s   ReadyForTurnIn = %s", tostring(C_QuestLog.IsComplete and C_QuestLog.IsComplete(id)),
        tostring(C_QuestLog.IsFailed and C_QuestLog.IsFailed(id)), tostring(C_QuestLog.ReadyForTurnIn and C_QuestLog.ReadyForTurnIn(id)))
      P("  IsQuestComplete(global) = %s", tostring(IsQuestComplete and IsQuestComplete(id)))
      if idx and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(idx)
        if info then P("  GetInfo: isComplete=%s isAutoComplete=%s startEvent=%s", tostring(info.isComplete), tostring(info.isAutoComplete), tostring(info.startEvent)) end
      end
      local objs = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
      P("  GetQuestObjectives: %d entries", objs and #objs or -1)
      for j, o in ipairs(objs or {}) do
        P("    [%d] text=%q type=%s finished=%s numFulfilled=%s numRequired=%s", j, tostring(o.text), tostring(o.type), tostring(o.finished), tostring(o.numFulfilled), tostring(o.numRequired))
      end
      if idx then
        P("  GetNumQuestLeaderBoards(idx) = %s", tostring(GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(idx)))
        for j = 1, (GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(idx)) or 0 do
          local t, ty, fin = GetQuestLogLeaderBoard(j, idx)
          P("    LB[%d] text=%q type=%s finished=%s", j, tostring(t), tostring(ty), tostring(fin))
        end
      end
    else
      P("  (Era) GetQuestLogIndexByID = %s", tostring(GetQuestLogIndexByID and GetQuestLogIndexByID(id)))
    end
    for _, q in ipairs(Model.Current().quests) do
      if q.questID == id then
        P("  VQT: category=%s isComplete=%s", q.category, tostring(q.isComplete))
        for _, o in ipairs(q.objectives) do P("    obj %d: %s %d/%d counted=%s done=%s", o.index, o.name, o.have, o.need, tostring(o.counted), tostring(o.done)) end
      end
    end
    Util.DumpFooter("/vqt probe " .. id)
  elseif cmd == "loc" then
    local id = tonumber(rest)
    local found
    for _, q in ipairs(Model.Current().quests) do if q.questID == id then found = q end end
    if found then NS.Location.Dump(found) else Util.Print("usage: /vqt loc <questID in log>  (%s)", NS.Location.Status()) end
  elseif cmd == "touch" then
    local id = tonumber(rest)
    if id then Model.TouchQuest(id); Util.Print("quest %d marked active", id) else Util.Print("usage: /vqt touch <questID>") end
  elseif cmd == "reset" then NS.EditMode.ResetPosition(); Util.Print("panel position reset")
  elseif cmd == "focus" then
    if rest == "" or rest == "clear" then Model.SetFocus(nil); Util.Print("focus cleared")
    else local ids = {}; for n in rest:gmatch("%d+") do ids[#ids + 1] = tonumber(n) end; Model.SetFocus(ids); Util.Print("focus set to %d quest(s)", #ids) end
  elseif cmd == "status" then
    Util.DumpHeader("/vqt status")
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON_NAME, "Version")
    local ci = Util.ClientInfo()
    Util.Print("version %s | client %s %s (build %s, interface %s, project %s) | character %s | %s | %s | %s",
      tostring(version), Client.flavour, ci.Version, ci.Build, tostring(ci.Interface), tostring(ci.Project),
      Client.PlayerDisplayName(), NS.db.settings.Enabled and "enabled" or "disabled", NS.StockTracker.Status(), NS.EditMode.Status(), NS.Location.Status(), NS.Position.Status())
  else
    Util.Print("/vqt - toggle | options | status | dump | touch <id> | focus <ids|clear> | reset")
  end
end

-- Events ------------------------------------------------------------------------------
local QUEST_EVENTS = {
  "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE",
  "UNIT_QUEST_LOG_CHANGED", "QUEST_WATCH_UPDATE", "QUEST_WATCH_LIST_CHANGED",   -- LIST_CHANGED = the track checkbox (Forever)
  "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
}

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

local function Stage(name, fn)
  local ok, err = pcall(fn)
  if not ok then Util.Print("|cffff4040%s failed:|r %s", name, tostring(err)) end
end

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON_NAME then return end
    Stage("InitDB", InitDB)
    Stage("Slash", function()
      SLASH_VELOCITYQUESTTRACKER1 = "/vqt"
      SlashCmdList.VELOCITYQUESTTRACKER = Slash
    end)
    Stage("Options", NS.Options.Create)
  elseif event == "PLAYER_LOGIN" then
    Stage("EditMode", NS.EditMode.Setup)
    Stage("Panel", function()
      NS.Panel.Create()
      NS.EditMode.ApplyToPanel()        -- reads the stock tracker position on first run, BEFORE it is swallowed
      NS.EditMode.WirePanelDrag()
    end)
    Stage("Events", function()
      for _, e in ipairs(QUEST_EVENTS) do pcall(f.RegisterEvent, f, e) end
    end)
    Stage("Location", function() NS.Location.Init() end)
    Stage("Position", function()
      NS.Position.Init()
      -- movement redraws the nearby spark lines; a full model rebuild is cheap and keeps one path
      NS.Position.OnMoved(function() Model.MarkDirty("moved") end)
    end)
    Stage("Model", function() Model.Init(); Model.Build() end)
    Stage("Enabled", ApplyEnabled)
    Stage("ZoneBrightness", function()
      local zb = LibStub and LibStub("LibZoneBrightness-1.0", true)
      if not zb then return end
      zb:RegisterCallback(function(band) NS.Theme.Retheme(band) end)
      NS.Theme.Retheme(zb:GetBand())
    end)
    Stage("Ticker", function() C_Timer.NewTicker(5, Model.Tick) end)
  elseif event == "PLAYER_REGEN_ENABLED" then
    NS.StockTracker.OnLeaveCombat()
    NS.ItemButtons.OnLeaveCombat()
  else
    Model.MarkDirty(event)
  end
end)