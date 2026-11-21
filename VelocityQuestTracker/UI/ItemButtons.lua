-- Velocity Quest Tracker: usable quest item buttons (PLAN "Quest item buttons").
-- One VQT_QuestItemButton per quest whose log entry carries a usable item, shown beside that quest's
-- active block or hand-in card. Each is a SecureActionButtonTemplate with type1=item / item1=item:<ID>,
-- so the click is a hardware event the client allows to use the item -- addon code never calls the
-- protected UseQuestLogSpecialItem. Reference: Questie TrackerItemButton.lua; API notes in
-- AddonManagement\_EXTERNAL_APIS\wow_quest_item_buttons.md.
--
-- Secure-frame rules honoured here:
--   * parented to UIParent, only ANCHORED to a block (SetParent is protected in combat)
--   * SetAttribute / Show / Hide / SetPoint on a secure frame are refused in combat, so every change goes
--     through VQT_ItemButtonQueue and is applied on PLAYER_REGEN_ENABLED when InCombatLockdown()
--   * a retired button has RegisterForClicks() cleared and attributes nil'd, so it cannot fire stale
local ADDON_NAME, NS = ...
local T, Util, Client = NS.Theme, NS.Util, NS.Client

local ItemButtons = {}
NS.ItemButtons = ItemButtons

local SIZE_PX = 24
local GAP_PX = 6                 -- between panel edge and button
local RANGE_POLL_SECONDS = 0.3

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

local nextIndex = 0
local function Create()
  nextIndex = nextIndex + 1
  local btn = CreateFrame("Button", "VelocityQuestTrackerItemButton" .. nextIndex, UIParent, "SecureActionButtonTemplate")
  btn:SetSize(SIZE_PX, SIZE_PX)
  btn:SetFrameStrata("TOOLTIP")      -- above the hover card (also TOOLTIP, created earlier -> lower level); a clickable item must never sit under a passive card
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

-- Anchor beside a block on the side away from the nearer screen edge (hover-card rule), centred on
-- the title row. SetPoint on a secure frame is protected in combat; callers come through Apply.
local function Place(btn, anchor)
  local panel = NS.Panel and NS.Panel.Frame()
  local ref = panel or anchor
  local cx = ref:GetCenter()
  local openLeft = cx and cx >= (UIParent:GetWidth() or 0) / 2
  local titleY = -(6 + T.LabelSize / 2 + 2)
  btn:ClearAllPoints()
  if openLeft then btn:SetPoint("RIGHT", ref, "LEFT", -GAP_PX, 0)
  else btn:SetPoint("LEFT", ref, "RIGHT", GAP_PX, 0) end
  btn:SetPoint("TOP", anchor, "TOP", 0, titleY + SIZE_PX / 2)
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

-- Called by Blocks after a render: every live questID not in `keep` is dropped.
function ItemButtons.Reconcile(keep)
  for questID in pairs(byQuest) do if not keep[questID] then ItemButtons.Drop(questID) end end
  for questID, want in pairs(queue) do if want and not keep[questID] then queue[questID] = false end end
end

function ItemButtons.OnLeaveCombat() if queued then Flush() end end

function ItemButtons.Status()
  local n = 0; for _ in pairs(byQuest) do n = n + 1 end
  return string.format("%d item button(s)%s", n, queued and " (changes queued for after combat)" or "")
end