-- Velocity Quest Tracker: hides the Blizzard quest tracker while we are enabled.
-- KondoBags sink pattern: the stock frame is re-parented into a hidden frame, so its events keep
-- firing and nothing it owns breaks; nothing is unregistered or replaced. Disable re-parents it back.
-- Fallback (if the sink misbehaves on a client, PLAN "Stock tracker"): Hide() + HookScript("OnShow").
local ADDON_NAME, NS = ...
local Client, Util = NS.Client, NS.Util

local StockTracker = {}
NS.StockTracker = StockTracker

local sink
local originalParent = {}       -- frame -> parent it had before we swallowed it
local swallowed = false
local hooked = {}               -- frame -> true once SetParent / OnShow are hooked

-- Every Blizzard frame we take over: the objective tracker, and the standalone timed-quest countdown
-- (QuestTimerFrame; SPEC-VQT-TimedQuests draws the clock on the card instead). nil entries are skipped.
local function StockFrames()
  local list = {}
  local tracker = Client.StockTrackerFrame()
  if tracker then list[#list + 1] = tracker end
  local timer = Client.QuestTimerFrame and Client.QuestTimerFrame()
  if timer then list[#list + 1] = timer end
  return list
end

-- Edit Mode (and some layout code) re-parents the stock tracker back to UIParent when a layout is
-- applied. Hook SetParent so a foreign re-parent while we are enabled is undone next frame, and
-- re-swallow when Edit Mode exits.
local function HookOnce(f)
  if hooked[f] then return end
  hooked[f] = true
  hooksecurefunc(f, "SetParent", function(self, parent)
    if swallowed and parent ~= sink and not InCombatLockdown() then
      C_Timer.After(0, function() if swallowed and self:GetParent() ~= sink then self:SetParent(sink) end end)
    end
  end)
  f:HookScript("OnShow", function(self) if swallowed and not InCombatLockdown() then self:Hide() end end)
end

function StockTracker.Swallow()
  local frames = StockFrames()
  if #frames == 0 or swallowed then return end
  if InCombatLockdown() then NS.deferToOutOfCombat = NS.deferToOutOfCombat or {}; NS.deferToOutOfCombat.swallow = true; return end
  if not sink then
    sink = CreateFrame("Frame", "VelocityQuestTrackerStockSink", UIParent)
    sink:Hide()
  end
  for _, f in ipairs(frames) do
    originalParent[f] = originalParent[f] or f:GetParent() or UIParent
    HookOnce(f)
    f:SetParent(sink)
    f:Hide()
  end
  swallowed = true
end

function StockTracker.Release()
  local frames = StockFrames()
  if #frames == 0 or not swallowed then return end
  if InCombatLockdown() then NS.deferToOutOfCombat = NS.deferToOutOfCombat or {}; NS.deferToOutOfCombat.release = true; return end
  swallowed = false
  for _, f in ipairs(frames) do
    f:SetParent(originalParent[f] or UIParent)
    -- the tracker is always shown; the timer frame only shows itself while a timer runs (it manages
    -- that from QUEST_TIMER_UPDATE), so re-showing it empty would draw a blank header
    if f == Client.StockTrackerFrame() then f:Show() end
  end
end

function StockTracker.Apply(enabled)
  if enabled then StockTracker.Swallow() else StockTracker.Release() end
end

function StockTracker.OnLeaveCombat()
  local d = NS.deferToOutOfCombat
  if not d then return end
  if d.release then StockTracker.Release() elseif d.swallow then StockTracker.Swallow() end
  NS.deferToOutOfCombat = nil
end

function StockTracker.Status()
  local frames = StockFrames()
  if #frames == 0 then return "stock tracker frame not found" end
  local names = {}
  for _, f in ipairs(frames) do names[#names + 1] = f:GetName() or "?" end
  return swallowed and ("stock frames swallowed (" .. table.concat(names, ", ") .. ")") or "stock tracker visible"
end