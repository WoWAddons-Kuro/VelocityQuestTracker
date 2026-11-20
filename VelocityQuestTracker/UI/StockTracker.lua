-- Velocity Quest Tracker: hides the Blizzard quest tracker while we are enabled.
-- KondoBags sink pattern: the stock frame is re-parented into a hidden frame, so its events keep
-- firing and nothing it owns breaks; nothing is unregistered or replaced. Disable re-parents it back.
-- Fallback (if the sink misbehaves on a client, PLAN "Stock tracker"): Hide() + HookScript("OnShow").
local ADDON_NAME, NS = ...
local Client, Util = NS.Client, NS.Util

local StockTracker = {}
NS.StockTracker = StockTracker

local sink
local originalParent
local swallowed = false

local function Stock() return Client.StockTrackerFrame() end

function StockTracker.Swallow()
  local f = Stock()
  if not f or swallowed then return end
  if InCombatLockdown() then NS.deferToOutOfCombat = NS.deferToOutOfCombat or {}; NS.deferToOutOfCombat.swallow = true; return end
  if not sink then
    sink = CreateFrame("Frame", "VelocityQuestTrackerStockSink", UIParent)
    sink:Hide()
  end
  originalParent = originalParent or f:GetParent() or UIParent
  f:SetParent(sink)
  swallowed = true
end

function StockTracker.Release()
  local f = Stock()
  if not f or not swallowed then return end
  if InCombatLockdown() then NS.deferToOutOfCombat = NS.deferToOutOfCombat or {}; NS.deferToOutOfCombat.release = true; return end
  f:SetParent(originalParent or UIParent)
  swallowed = false
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
  local f = Stock()
  if not f then return "stock tracker frame not found" end
  return swallowed and ("stock tracker swallowed (" .. (f:GetName() or "?") .. ")") or "stock tracker visible"
end