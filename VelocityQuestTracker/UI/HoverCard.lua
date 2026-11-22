-- Velocity Quest Tracker: the shared hover card. One frame, shown beside the panel next to a hovered
-- row, on the side away from the nearer screen edge. It stays while the mouse is on it and hides
-- HOVER_GRACE_SECONDS after the mouse has left BOTH the row and the card, so the player can travel
-- from the row across to the card. Two content modes:
--   "list"  (place lines)   : one row per quest -- difficulty square + title
--   "block" (nearby rows)   : looks like an active block -- quest title, then objective rows
--                              (name | segmented bar | count), middle tone
-- Quest titles in either mode: left-click opens the quest log, right-click toggles tracked.
--
-- VQT_HoverCard_Anchor = the row frame the card is shown for (row.hover is its wash texture, optional).
local ADDON_NAME, NS = ...
local T, Util = NS.Theme, NS.Util

local HoverCard = {}
NS.HoverCard = HoverCard

local HOVER_GRACE_SECONDS = 0.35
local PAD = 8
local MIN_W = 120
local LIST_ROW_H = 14
local BLOCK_TITLE_H = T.LabelSize + 6
local BLOCK_ROW_H = 16

local card
local hideTimer

-- Both gates live in Core\Interact: Shift settings, and never in combat.
function HoverCard.HoverAllowed() return NS.Interact.HoverAllowed() end
local function ClickAllowed() return NS.Interact.ClickAllowed() end

-- Timers ------------------------------------------------------------------------------------
local function CancelHide() if hideTimer then hideTimer:Cancel(); hideTimer = nil end end

local function SetRowWash(row, on) if row and row.hover then row.hover:SetShown(on and true or false) end end

function HoverCard.HideNow()
  CancelHide()
  if card then SetRowWash(card.row, false); card:Hide() end
end

function HoverCard.ScheduleHide()
  CancelHide()
  hideTimer = C_Timer.NewTimer(HOVER_GRACE_SECONDS, function()
    hideTimer = nil
    if not card or not card:IsShown() then return end
    local row = card.row
    if card:IsMouseOver() or (row and row:IsShown() and row:IsMouseOver()) then return end
    SetRowWash(row, false)
    card:Hide()
  end)
end

-- Quest title actions --------------------------------------------------------------------------
local function OnTitleClick(self, button)
  if not ClickAllowed() or not self.questID then return end
  if button == "RightButton" then
    local q = self.quest
    local want = not (q and q.isWatched)
    if NS.Client.SetWatched(self.questID, want) then
      if q then q.isWatched = want end
      NS.Model.MarkDirty("toggle-watch")
      Util.Print("%s %s", want and "tracking" or "untracked", q and q.title or self.questID)
    elseif InCombatLockdown() then Util.Print("cannot change tracking in combat") end
    return
  end
  local ok = NS.Client.OpenQuestLog(self.questID)
  if not ok and InCombatLockdown() then Util.Print("cannot open the quest log in combat") end
  HoverCard.HideNow()
end

local function MakeTitleButton(parent, size, tone)
  local b = CreateFrame("Button", nil, parent)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.text = T.Text(b, size, tone)
  b.text:SetAllPoints()
  b.restTone = tone
  b:SetScript("OnEnter", function(self) CancelHide(); T.SetColour(self.text, T.Tone.Recent) end)
  b:SetScript("OnLeave", function(self) T.SetColour(self.text, self.restTone); HoverCard.ScheduleHide() end)
  b:SetScript("OnClick", OnTitleClick)
  return b
end

-- Frame ---------------------------------------------------------------------------------------
-- Watchdog. OnLeave is not guaranteed: a row re-rendered or hidden under the cursor, a panel
-- re-layout, or a child button taking the mouse all drop the event, and the card then stays up until
-- the next hover (owner 2026-11-20: "sometimes stuck open"). So while the card is shown, poll each
-- frame: if the mouse is on neither the card nor its row for VQT_HoverCard_AwaySeconds, hide.
local AWAY_SECONDS = HOVER_GRACE_SECONDS
local awaySince = nil
local function Watchdog(self)
  local row = self.row
  local over = self:IsMouseOver() or (row and row:IsShown() and row:IsMouseOver())
  if over then awaySince = nil; return end
  local now = GetTime()
  awaySince = awaySince or now
  if now - awaySince >= AWAY_SECONDS then
    awaySince = nil
    CancelHide()
    SetRowWash(row, false)
    self:Hide()
  end
end

local function Acquire()
  if card then return card end
  card = CreateFrame("Frame", "VelocityQuestTrackerHoverCard", UIParent)
  card:SetFrameStrata("TOOLTIP")
  NS.Interact.Register(card)
  card:SetScript("OnEnter", CancelHide)
  card:SetScript("OnLeave", HoverCard.ScheduleHide)
  card:SetScript("OnUpdate", Watchdog)
  card:SetScript("OnShow", function() awaySince = nil end)
  card:Hide()
  card.bg = card:CreateTexture(nil, "BACKGROUND")
  card.bg:SetAllPoints()
  card.bg:SetColorTexture(0.13, 0.16, 0.14, 0.94)
  card.listRows = {}
  card.blockRows = {}
  return card
end

local function AcquireListRow(i)
  local c = Acquire()
  local r = c.listRows[i]
  if r then return r end
  r = MakeTitleButton(c, T.LabelSize, T.Tone.Todo)
  r:SetHeight(LIST_ROW_H)
  r.square = r:CreateTexture(nil, "ARTWORK")
  r.square:SetSize(T.Square, T.Square); r.square:SetPoint("LEFT", 0, 0)
  r.text:ClearAllPoints(); r.text:SetPoint("LEFT", r.square, "RIGHT", 6, 0); r.text:SetPoint("RIGHT", 0, 0)
  c.listRows[i] = r
  return r
end

local function AcquireBlockRow(i)
  local c = Acquire()
  local r = c.blockRows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, c)
  r:SetHeight(BLOCK_ROW_H)
  r.name = T.Text(r, T.RowSize, T.Tone.Near); r.name:SetPoint("LEFT", 0, 0)
  r.count = T.Text(r, T.RowSize, T.Tone.Near); r.count:SetPoint("RIGHT", 0, 0); r.count:SetJustifyH("RIGHT"); r.count:SetWidth(T.CountWidth)
  -- done objectives show a check in the count slot instead of "0" (owner 2026-11-22)
  r.check = r:CreateTexture(nil, "ARTWORK")
  r.check:SetSize(12, 12); r.check:SetPoint("RIGHT", r.count, "RIGHT", 0, 0)
  local atlasOk = r.check.SetAtlas and pcall(r.check.SetAtlas, r.check, "common-icon-checkmark")
  if not (atlasOk and r.check:GetAtlas()) then r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
  r.check:SetVertexColor(0.45, 0.75, 0.45); r.check:Hide()
  r.bar = CreateFrame("Frame", nil, r); r.bar:SetSize(T.BarWidth, T.SegHeight); r.bar:SetPoint("RIGHT", r.count, "LEFT", -T.ColGap, 0)
  r.name:SetPoint("RIGHT", r.bar, "LEFT", -T.ColGap, 0)
  r.segs = {}
  c.blockRows[i] = r
  return r
end

-- Static segment bar (no animation). Same tones as a live block -- done = Done, remaining = Todo -- so the
-- card reads like the block it mirrors. (Label/Near were tried: two mid greys of near-equal luminance
-- merged into one pale bar at 4/5, owner 2026-11-20. Done is visible because the card background is
-- lifted to the field tone below.) 10 per row wrapping, bar sized to the row width like Blocks.
local function FillSegments(r, have, need)
  local perRow = T.SegPerRow
  local rows = math.max(1, math.ceil(need / perRow))
  local cols = math.min(need, perRow)
  local segW = (T.BarWidth - (cols - 1) * T.SegGapFor(cols)) / cols
  for u = 1, need do
    local s = r.segs[u]
    if not s then s = r.bar:CreateTexture(nil, "ARTWORK"); r.segs[u] = s end
    local rr = math.floor((u - 1) / perRow)
    local cc = (u - 1) % perRow
    s:ClearAllPoints(); s:SetSize(segW, T.SegHeight)
    s:SetPoint("TOPLEFT", r.bar, "TOPLEFT", cc * (segW + T.SegGapFor(cols)), -rr * (T.SegHeight + T.SegGap))
    T.SetColour(s, u <= have and T.Tone.Done or T.Tone.Todo)
    s:Show()
  end
  for u = need + 1, #r.segs do r.segs[u]:Hide() end
  local h = rows * T.SegHeight + (rows - 1) * T.SegGap
  r.bar:SetHeight(h)
  return math.max(BLOCK_ROW_H, h + 6)
end

local function Anchor(row)
  local panel = NS.Panel and NS.Panel.Frame()
  local anchor = panel or row
  local cx = anchor:GetCenter()
  local openLeft = cx and cx >= (UIParent:GetWidth() or 0) / 2
  card:ClearAllPoints()
  if openLeft then card:SetPoint("TOPRIGHT", anchor, "TOPLEFT", 0, 0) else card:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 0, 0) end
  card:SetPoint("TOP", row, "TOP", 0, 4)
end

local function Begin(row)
  CancelHide()
  local c = Acquire()
  if c.row and c.row ~= row then SetRowWash(c.row, false) end
  c.row = row
  SetRowWash(row, true)
  for _, r in ipairs(c.listRows) do r:Hide() end
  for _, r in ipairs(c.blockRows) do r:Hide() end
  if c.blockTitle then c.blockTitle:Hide() end
  if c.intro then c.intro:Hide() end
  return c
end

-- Public --------------------------------------------------------------------------------------
-- List mode: quests = { VQT_Quest... }
function HoverCard.ShowList(row, quests)
  if not HoverCard.HoverAllowed() or not quests or #quests == 0 then return end
  local c = Begin(row)
  local width = MIN_W
  for i, q in ipairs(quests) do
    local r = AcquireListRow(i)
    r.questID, r.quest = q.questID, q
    T.SetColour(r.square, T.DifficultyColour(q.level))
    r.text:SetText(q.title)
    width = math.max(width, T.Square + 6 + r.text:GetStringWidth() + 2 * PAD)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + (i - 1) * LIST_ROW_H)); r:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    r:Show()
  end
  c:SetSize(width, 2 * PAD + #quests * LIST_ROW_H)
  Anchor(row); c:Show()
end

-- Block mode: one VQT_Quest, drawn like an active block (middle tone, static bars).
function HoverCard.ShowBlock(row, quest)
  if not HoverCard.HoverAllowed() or not quest then return end
  local c = Begin(row)
  if not c.blockTitle then
    c.blockTitle = MakeTitleButton(c, T.LabelSize, T.Tone.Label)
    c.blockTitle:SetHeight(BLOCK_TITLE_H)
    c.blockTitle.text:SetJustifyH("CENTER")
  end
  c.blockTitle.questID, c.blockTitle.quest = quest.questID, quest
  c.blockTitle.text:SetText(quest.title)
  c.blockTitle:ClearAllPoints(); c.blockTitle:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -PAD); c.blockTitle:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
  c.blockTitle:Show()
  local width = math.max(T.PanelWidth, c.blockTitle.text:GetStringWidth() + 2 * PAD)
  local y = PAD + BLOCK_TITLE_H + 2
  -- Short intro: the quest's objectives text (the "Collect 4 Grizzled Scalps from ..." paragraph),
  -- wrapped to the card width, label tone. The long description is left to the quest log.
  if not c.intro then
    c.intro = T.Text(c, T.LabelSize, T.Tone.Label)
    c.intro:SetWordWrap(true); c.intro:SetNonSpaceWrap(false); c.intro:SetJustifyH("LEFT")
  end
  local _, objectivesText = NS.Client.QuestText(quest.questID)
  if objectivesText and objectivesText ~= "" then
    c.intro:SetWidth(width - 2 * PAD)
    c.intro:SetText(objectivesText)
    c.intro:ClearAllPoints(); c.intro:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -y)
    c.intro:Show()
    y = y + c.intro:GetStringHeight() + 6
  else
    c.intro:Hide()
  end
  for i, o in ipairs(quest.objectives) do
    local r = AcquireBlockRow(i)
    r.name:SetText(T.CountlessName(o.name))
    -- text tones mirror a live block: bright while owed, label once done. Done = the objective's own
    -- flag OR the count, OR the quest being complete (a no-count objective can lag its flag).
    local done = o.done or o.have >= o.need or quest.isComplete
    -- Count slot: units REMAINING while owed; a green check when none are (owner 2026-11-22 -- the
    -- have/need form from the day before was reverted: "6/8" next to an 8-cell bar double-counted).
    if done then r.count:SetText(""); r.check:Show()
    else r.count:SetText(tostring(o.need - o.have)); r.check:Hide() end
    local tone = done and T.Tone.Label or T.Tone.Todo
    T.SetColour(r.name, tone); T.SetColour(r.count, tone)
    local h = FillSegments(r, done and o.need or o.have, o.need)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -y); r:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    r:SetHeight(h); r:Show()
    y = y + h + 2
  end
  c:SetSize(width, y + PAD - 2)
  Anchor(row); c:Show()
end

function HoverCard.IsShownFor(row) return card and card:IsShown() and card.row == row end