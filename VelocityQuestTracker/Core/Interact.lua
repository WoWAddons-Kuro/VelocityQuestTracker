-- Velocity Quest Tracker: the single gate for mouse interaction with the panel.
--
-- Two rules, applied everywhere a row / block / card / tab takes the mouse:
--   * the "Require Shift" settings (RequireShiftToInteract for clicks, RequireShiftForHover for hover)
--   * IN COMBAT THE PANEL IS NOT INTERACTIVE (owner 2026-11-21). Every registered frame has its mouse
--     DISABLED for the duration, so clicks fall through to the world instead of being swallowed by a
--     row that then does nothing; the hover card is taken down at the first hit. The quest ITEM
--     buttons are not registered: they are secure action buttons and are exactly what you do want in
--     combat.
--
-- Frames that take the mouse call Interact.Register(frame) once at creation (rows are created lazily,
-- so a registry beats a one-shot sweep). Register applies the current state at once.
local ADDON_NAME, NS = ...

local Interact = {}
NS.Interact = Interact

local function Settings() return NS.db and NS.db.settings or {} end

local inCombat = false
local registered = {}        -- frame -> true

function Interact.InCombat() return inCombat end

-- Belt and braces on top of EnableMouse(false): a click can still land in the frame between the
-- combat event and the mouse flip, and the gates are cheap.
function Interact.ClickAllowed()
  if inCombat then return false end
  return not Settings().RequireShiftToInteract or IsShiftKeyDown()
end

function Interact.HoverAllowed()
  if inCombat then return false end
  return not Settings().RequireShiftForHover or IsShiftKeyDown()
end

function Interact.Register(frame)
  if not frame or registered[frame] then return end
  registered[frame] = true
  frame:EnableMouse(not inCombat)
end

local function Apply()
  for frame in pairs(registered) do frame:EnableMouse(not inCombat) end
  -- the panel's own drag surface is owned by the lock setting; it re-reads InCombat()
  if NS.EditMode and NS.EditMode.ApplyLock then NS.EditMode.ApplyLock() end
end

-- Called from the bootstrap on PLAYER_REGEN_DISABLED (true) / PLAYER_REGEN_ENABLED (false).
function Interact.SetInCombat(flag)
  flag = flag and true or false
  if flag == inCombat then return end
  inCombat = flag
  if inCombat and NS.HoverCard then NS.HoverCard.HideNow() end
  Apply()
end

function Interact.Status()
  local n = 0
  for _ in pairs(registered) do n = n + 1 end
  return string.format("%d mouse frames, %s", n, inCombat and "combat: mouse off" or "mouse on")
end