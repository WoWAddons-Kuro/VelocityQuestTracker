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
local hooked = false

local function Stock() return Client.StockTrackerFrame() end

-- Edit Mode (and some layout code) re-parents the stock tracker back to UIParent when a layout is
-- applied. Hook SetParent so a foreign re-parent while we are enabled is undone next frame, and
-- re-swallow when Edit Mode exits.
local function HookOnce(f)
  if hooked then return end
  hooked = true
  hooksecurefunc(f, "SetParent", function(self, parent)
    if swallowed and parent ~= sink and not InCombatLockdown() then
      C_Timer.After(0, function() if swallowed and self:GetParent() ~= sink then self:SetParent(sink) end end)
    end
  end)
  f:HookScript("OnShow", function(self) if swallowed and not InCombatLockdown() then self:Hide() end end)
end

function StockTracker.Swallow()
  local f = Stock()
  if not f or swallowed then return end
  if InCombatLockdown() then NS.deferToOutOfCombat = NS.deferToOutOfCombat or {}; NS.deferToOutOfCombat.swallow = true; return end
  if not sink then
    sink = CreateFrame("Frame", "VelocityQuestTrackerStockSink", UIParent)
    sink:Hide()
  end
  originalParent = originalParent or f:GetParent() or UIParent
  HookOnce(f)
  f:SetParent(sink)
  f:Hide()
  swallowed = true
end

function StockTracker.Release()
  local f = Stock()
  if not f or not swallowed then return end
  if InCombatLockdown() then NS.deferToOutOfCombat = NS.deferToOutOfCombat or {}; NS.deferToOutOfCombat.release = true; return end
  f:SetParent(originalParent or UIParent)
  f:Show()
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