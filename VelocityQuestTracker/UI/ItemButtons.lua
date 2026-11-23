-- Velocity Quest Tracker: usable quest item buttons (PLAN "Quest item buttons").
-- One VQT_QuestItemButton per quest whose log entry carries a usable item, shown beside that quest's
-- active block or hand-in card. Each is a SecureActionButtonTemplate with type1=item / item1=item:<ID>,
-- so the click is a hardware event the client allows to use the item -- addon code never calls the
-- protected UseQuestLogSpecialItem. Reference: Questie TrackerItemButton.lua; API notes in
-- AddonManagement\_EXTERNAL_APIS\wow_quest_item_buttons.md.
--
-- Secure-frame rules honoured here:
--   * NEVER anchored to, or parented under, anything the panel lays out. A secure frame anchored to a
--     block makes the block -- and through it the panel -- protected: every SetHeight / SetPoint /
--     Show the panel did in combat was [Blocked] (1460 x SetHeight in one fight, owner 2026-11-22).
--     Instead all buttons live on ONE secure overlay, VQT_ItemButtonLayer, parented to UIParent and
--     sized/placed to mirror the panel rect; buttons are positioned INSIDE the layer at the block's
--     offset within the panel. The panel is then an ordinary frame and animates freely in combat.
--   * SetAttribute / Show / Hide / SetPoint on a secure frame are refused in combat, so every change goes
--     through VQT_ItemButtonQueue and is applied on PLAYER_REGEN_ENABLED when InCombatLockdown()
--     (the layer keeps its last out-of-combat geometry for the duration; the buttons stay clickable
--     where they were)
--   * a retired button has RegisterForClicks() cleared and attributes nil'd, so it cannot fire stale
local ADDON_NAME, NS = ...
local T, Util, Client = NS.Theme, NS.Util, NS.Client

local ItemButtons = {}
NS.ItemButtons = ItemButtons

local SIZE_PX = 24
local GAP_PX = 6                 -- between panel edge and button
local RANGE_POLL_SECONDS = 0.3

local layer                      -- VQT_ItemButtonLayer: the secure overlay mirroring the panel rect
local pool = {}                  -- free buttons
local byQuest = {}               -- questID -> button (live)
local queue = {}                 -- VQT_ItemButtonQueue: questID -> { itemID, anchor } | false (= hide)
local queued = false

-- API aliases, resolved in Questie's verified order (QuestieCompat.lua). `C_Item and C_Item.X or X` is
-- WRONG when C_Item exists but lacks X: it yields nil, and the nil call inside Blocks.Render aborted the
-- whole panel layout so only the turn-in line (rendered first) survived -- owner 2026-11-20 "only
-- shows completed quests". Each alias falls through every known home and ends in a safe stub.
local function Pick(...)
  for i = 1, select("#", ...) do local f = select(i, ...); if type(f) == "function" then return f end end
  return function() return nil end
end
local GetItemCount   = Pick(C_Item and C_Item.GetItemCount, _G.GetItemCount)
local GetItemCooldown = Pick(C_Container and C_Container.GetItemCooldown, C_Item and C_Item.GetItemCooldown, _G.GetItemCooldown)
local GetItemIcon    = Pick(C_Item and C_Item.GetItemIconByID, _G.GetItemIcon)
local IsItemInRange  = Pick(C_Item and C_Item.IsItemInRange, _G.IsItemInRange)

-- Button lifecycle ---------------------------------------------------------------------------
local function UpdateCooldown(btn)
  if not btn.itemID then return end
  local start, duration, enable = GetItemCooldown(btn.itemID)
  if start and duration and duration > 0 and (enable == 1 or enable == true) then
    btn.cooldown:SetCooldown(start, duration); btn.cooldown:Show()
  else
    btn.cooldown:Hide()
  end
end

local function UpdateCharges(btn)
  if not btn.itemID then return end
  local n = GetItemCount(btn.itemID, nil, true) or 0
  btn.charges = n
  if n > 1 then btn.count:SetText(n); btn.count:Show() else btn.count:Hide() end
  if n == 0 then
    -- the item is gone (used up / handed in); the next model build drops the button
    if NS.Model then NS.Model.MarkDirty("item-gone") end
  end
end

local function OnUpdate(btn, elapsed)
  if not btn.itemID or not UnitExists("target") then return end
  btn.rangeTimer = (btn.rangeTimer or 0) - elapsed
  if btn.rangeTimer > 0 then return end
  btn.rangeTimer = RANGE_POLL_SECONDS
  -- IsItemInRange refuses friendly targets in combat (returns nil); only draw when it answers
  if UnitIsFriend("player", "target") and InCombatLockdown() then btn.range:Hide(); return end
  local inRange = IsItemInRange(btn.itemID, "target")
  if inRange == false then btn.range:SetVertexColor(1, 0.1, 0.1); btn.range:Show()
  elseif inRange == true then btn.range:SetVertexColor(0.6, 0.6, 0.6); btn.range:Show()
  else btn.range:Hide() end
end

local function OnEvent(btn, event)
  if event == "PLAYER_TARGET_CHANGED" then btn.rangeTimer = 0; btn.range:Hide()
  elseif event == "BAG_UPDATE_COOLDOWN" then UpdateCooldown(btn)
  elseif event == "BAG_UPDATE" then UpdateCharges(btn) end
end

local function OnEnter(btn)
  if not btn.itemID then return end
  local cx = btn:GetCenter() or 0
  if cx < (UIParent:GetWidth() or 0) / 2 then GameTooltip:SetOwner(btn, "ANCHOR_RIGHT") else GameTooltip:SetOwner(btn, "ANCHOR_LEFT") end
  GameTooltip:SetHyperlink("item:" .. btn.itemID)
  GameTooltip:Show()
end

local function OnLeave() GameTooltip:Hide() end

-- The overlay. One plain frame under UIParent, no children of the panel; sized and placed to the
-- panel's rect out of combat (SyncLayer). It is the only thing the secure buttons are parented to.
local function Layer()
  if layer then return layer end
  layer = CreateFrame("Frame", "VelocityQuestTrackerItemButtonLayer", UIParent)
  -- MEDIUM, same strata as the hover card; buttons are level 50 so they sit ABOVE the card (level 20)
  -- when the two overlap, but a toplevel window (bags) clicked on top still covers them.
  layer:SetFrameStrata("MEDIUM")
  layer:SetSize(T.PanelWidth, 1)
  layer:EnableMouse(false)
  return layer
end

-- Mirror the panel's rect onto the layer (out of combat only -- the layer owns secure children,
-- so its own geometry is protected in combat too). Idempotent; cheap.
local function SyncLayer()
  local panel = NS.Panel and NS.Panel.Frame()
  if not panel or InCombatLockdown() then return false end
  local L = Layer()
  L:ClearAllPoints()
  L:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", panel:GetLeft() or 0, panel:GetTop() or 0)
  L:SetSize(math.max(1, panel:GetWidth() or T.PanelWidth), math.max(1, panel:GetHeight() or 1))
  return true
end

local nextIndex = 0
local function Create()
  nextIndex = nextIndex + 1
  local btn = CreateFrame("Button", "VelocityQuestTrackerItemButton" .. nextIndex, Layer(), "SecureActionButtonTemplate")
  btn:SetSize(SIZE_PX, SIZE_PX)
  btn:SetFrameLevel(50)
  btn:Hide()
  btn.icon = btn:CreateTexture(nil, "ARTWORK"); btn.icon:SetAllPoints(); btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  btn.border = btn:CreateTexture(nil, "BORDER"); btn.border:SetPoint("TOPLEFT", -1, 1); btn.border:SetPoint("BOTTOMRIGHT", 1, -1)
  T.SetColour(btn.border, T.Tone.Label, 0.6)
  btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
  btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
  btn.cooldown:SetAllPoints(btn.icon); btn.cooldown:Hide()
  btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  btn.count:SetPoint("BOTTOMRIGHT", -2, 2); btn.count:Hide()
  btn.range = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
  btn.range:SetText("\226\151\143"); btn.range:SetPoint("TOPRIGHT", 2, 1); btn.range:Hide()   -- ●
  btn:SetScript("OnEvent", OnEvent)
  btn:SetScript("OnUpdate", OnUpdate)
  btn:SetScript("OnEnter", OnEnter)
  btn:SetScript("OnLeave", OnLeave)
  btn:SetScript("OnShow", function(self)
    self:RegisterEvent("PLAYER_TARGET_CHANGED"); self:RegisterEvent("BAG_UPDATE_COOLDOWN"); self:RegisterEvent("BAG_UPDATE")
    UpdateCooldown(self); UpdateCharges(self)
  end)
  btn:SetScript("OnHide", function(self) self:UnregisterAllEvents() end)
  return btn
end

-- Out-of-combat only: give a button its item and show it.
local function Assign(btn, itemID)
  btn:SetAttribute("type1", nil); btn:SetAttribute("item1", nil)
  btn.itemID = itemID
  btn.icon:SetTexture(GetItemIcon(itemID) or "Interface\\Icons\\INV_Misc_QuestionMark")
  btn:RegisterForClicks("AnyUp", "AnyDown")
  btn:SetAttribute("type1", "item")
  btn:SetAttribute("item1", "item:" .. itemID)
  btn:Show()
end

-- Out-of-combat only: strip the item and park the button so it cannot fire.
local function Retire(btn)
  btn:RegisterForClicks()
  btn:SetAttribute("type1", nil); btn:SetAttribute("item1", nil)
  btn.itemID = nil
  btn:Hide()
  btn:ClearAllPoints()
  pool[#pool + 1] = btn
end

-- Place beside a block, on the side away from the nearer screen edge (hover-card rule), centred on
-- the title row -- expressed in LAYER coordinates from the block's offset within the panel, so the
-- button is never anchored to the block (see header). Out of combat only; callers come through Apply.
local function Place(btn, anchor)
  local panel = NS.Panel and NS.Panel.Frame()
  if not panel then return end
  SyncLayer()
  local cx = panel:GetCenter()
  local openLeft = cx and cx >= (UIParent:GetWidth() or 0) / 2
  -- block top relative to the panel top (negative = below), from screen coordinates
  local blockTopOffset = ((anchor:GetTop() or 0) - (panel:GetTop() or 0))
  local titleY = blockTopOffset - (6 + T.LabelSize / 2 + 2)       -- centre of the block's title row
  btn:ClearAllPoints()
  local L = Layer()
  if openLeft then btn:SetPoint("RIGHT", L, "TOPLEFT", -GAP_PX, titleY)
  else btn:SetPoint("LEFT", L, "TOPRIGHT", GAP_PX, titleY) end
end

-- Apply one queued entry now (caller has checked combat).
local function ApplyOne(questID, want)
  local btn = byQuest[questID]
  if want == false then
    if btn then Retire(btn); byQuest[questID] = nil end
    return
  end
  if not btn then
    btn = table.remove(pool) or Create()
    byQuest[questID] = btn
  end
  if btn.itemID ~= want.itemID then Assign(btn, want.itemID) end
  Place(btn, want.anchor)
  btn:Show()
end

local function Flush()
  if InCombatLockdown() then return end
  for questID, want in pairs(queue) do ApplyOne(questID, want) end
  wipe(queue); queued = false
end

-- Public -----------------------------------------------------------------------------------------
-- Want a button for questID beside `anchor` showing itemID. Immediate out of combat, queued in combat.
function ItemButtons.Want(questID, itemID, anchor)
  queue[questID] = { itemID = itemID, anchor = anchor }
  if InCombatLockdown() then queued = true else Flush() end
end

-- No button for questID (quest left the block, item gone, or complete without showWhenComplete).
function ItemButtons.Drop(questID)
  if not byQuest[questID] and queue[questID] == nil then return end
  queue[questID] = false
  if InCombatLockdown() then queued = true else Flush() end
end

-- Titlebar ---------------------------------------------------------------------------------------
-- A hover bar ABOVE the panel (VQT_TitleBar) that drags the whole panel and carries a lock/unlock
-- toggle at its right end. It lives on the secure layer, NOT the panel: the panel stays chrome-free
-- and click-through, and the bar inherits the layer's rule -- geometry only changes out of combat.
-- GEOMETRY RULE: the bar hangs off the layer's TOP edge (anchored BOTTOMLEFT -> layer TOPLEFT) so the
-- layer's own rect stays an exact mirror of the panel whatever the bar's visibility; the panel content
-- and the layer content (buttons) therefore line up at all times.
-- Visibility: on hover; when position is locked only if the "titlebar only when unlocked" setting is off.
local bar
local BAR_H, BAR_GAP = 18, 4
local STRIP_CLEARANCE = 22       -- Panel's Map|Range strip (18 + 4) sits in the same place; bar goes above it

local function LockTex(icon, locked)
  if locked then icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK"); icon:SetTexCoord(0, 0.71875, 0, 0.875)
  else icon:SetTexture("Interface\\Buttons\\LockButton-Unlocked-Up"); icon:SetTexCoord(0.15, 0.85, 0.15, 0.85) end
end

local function BarShouldShow()
  if InCombatLockdown() or not NS.Interact.HoverAllowed() then return false end
  if NS.EditMode.IsActive() then return false end
  if NS.EditMode.IsPositionLocked() and NS.db.settings.TitleBarOnlyWhenUnlocked ~= false then return false end
  local panel = NS.Panel.Frame()
  if not panel or not panel:IsShown() then return false end
  -- the panel rect grown upward by the strip + bar, so the mouse can travel up into the bar without a gap
  return panel:IsMouseOver(STRIP_CLEARANCE + BAR_GAP + BAR_H, 0, 0, 0) or (bar and bar:IsMouseOver())
end

local function BuildBar()
  if bar then return bar end
  local L = Layer()
  bar = CreateFrame("Frame", "VelocityQuestTrackerTitleBar", L)
  bar:SetSize(T.PanelWidth, BAR_H)
  -- above the Map|Range strip's slot (the strip only exists in experimental map mode; keep one layout)
  bar:SetPoint("BOTTOMLEFT", L, "TOPLEFT", 0, (NS.Panel.MapModeEnabled() and STRIP_CLEARANCE or 0) + BAR_GAP)
  bar:SetFrameLevel(40)
  bar:Hide()
  bar.bg = bar:CreateTexture(nil, "BACKGROUND"); bar.bg:SetAllPoints(); T.SetColour(bar.bg, T.Tone.Wash, T.WashAlpha)
  bar.title = T.Text(bar, T.LabelSize, T.Tone.Label); bar.title:SetPoint("LEFT", T.PadX, 0); bar.title:SetText("Velocity Quest Tracker")
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function(self)
    if NS.EditMode.IsActive() or NS.EditMode.IsPositionLocked() or not NS.Interact.ClickAllowed() then return end
    local panel = NS.Panel.Frame(); if not panel then return end
    panel:StartMoving()
    -- the layer (and this bar, and the buttons) is not anchored to the panel: follow it every frame
    self:SetScript("OnUpdate", function() SyncLayer() end)
  end)
  bar:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    local panel = NS.Panel.Frame(); if not panel then return end
    panel:StopMovingOrSizing()
    NS.EditMode.OnPanelMoved()        -- normalises to TOP*, saves to the layout profile, re-syncs the layer
  end)
  local lock = CreateFrame("Button", nil, bar)
  lock:SetSize(BAR_H, BAR_H); lock:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
  lock.icon = lock:CreateTexture(nil, "ARTWORK"); lock.icon:SetPoint("CENTER"); lock.icon:SetSize(12, 12)
  lock:SetScript("OnClick", function()
    if not NS.Interact.ClickAllowed() then return end
    NS.EditMode.SetPositionLocked(not NS.EditMode.IsPositionLocked())
    ItemButtons.RefreshTitleBar()
  end)
  lock:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(NS.EditMode.IsPositionLocked() and "Position locked. Click to unlock, then drag this bar to move the tracker." or "Position unlocked. Drag this bar to move the tracker; click to lock.", nil, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  lock:SetScript("OnLeave", function() GameTooltip:Hide() end)
  bar.lock = lock
  return bar
end

function ItemButtons.RefreshTitleBar()
  if not bar then return end
  T.ApplyWash(bar.bg)
  LockTex(bar.lock.icon, NS.EditMode.IsPositionLocked())
  bar:ClearAllPoints()
  bar:SetPoint("BOTTOMLEFT", Layer(), "TOPLEFT", 0, (NS.Panel.MapModeEnabled() and STRIP_CLEARANCE or 0) + BAR_GAP)
end

-- Called every frame by Panel's OnUpdate (the panel does not take the mouse at rest; hover is polled).
function ItemButtons.TickTitleBar()
  local want = BarShouldShow()
  if want and not (bar and bar:IsShown()) then
    BuildBar(); SyncLayer(); ItemButtons.RefreshTitleBar(); bar:Show()
  elseif not want and bar and bar:IsShown() and not bar:GetScript("OnUpdate") then     -- never hide mid-drag
    bar:Hide()
  end
end

-- Called by EditMode whenever it re-places the panel (Edit Mode drag, unlocked drag, reset, exit).
-- Buttons are anchored inside the layer, so re-mirroring the panel rect moves them with it. No-op in
-- combat (the layer is protected); Reconcile catches up on the next out-of-combat render.
function ItemButtons.SyncToPanel()
  return SyncLayer()
end

-- Called by Blocks after a render: every live questID not in `keep` is dropped, and -- out of combat --
-- the layer is re-synced to the panel rect and every live button re-placed, since the blocks above
-- it may have moved. In combat nothing is touched: the buttons stay where they were.
function ItemButtons.Reconcile(keep)
  for questID in pairs(byQuest) do if not keep[questID] then ItemButtons.Drop(questID) end end
  for questID, want in pairs(queue) do if want and not keep[questID] then queue[questID] = false end end
  if InCombatLockdown() then queued = true; return end
  SyncLayer()
end

function ItemButtons.OnLeaveCombat() if queued then Flush() end; if NS.Model then NS.Model.MarkDirty("combat-end") end end

function ItemButtons.Status()
  local n = 0; for _ in pairs(byQuest) do n = n + 1 end
  return string.format("%d item button(s)%s", n, queued and " (changes queued for after combat)" or "")
end