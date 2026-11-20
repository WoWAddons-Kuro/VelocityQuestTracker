-- Velocity Quest Tracker: parts 1 and 4, the place lines.
--   Turn-in line : check glyph, place name, one difficulty square per completed quest there.
--   Other-zone   : "+N in Zone", one difficulty square per quest.
-- One frame per place, reused by key; lines keep first-seen order (the model groups that way).
local ADDON_NAME, NS = ...
local T = NS.Theme

local Lines = {}
NS.Lines = Lines

local LINE_H = 14

local function Settings() return NS.db and NS.db.settings or {} end

-- Hover feedback is gated by the "Hold Shift for hover feedback" setting (default off = always).
local function HoverAllowed() return not Settings().RequireShiftForHover or IsShiftKeyDown() end

-- Hover card ---------------------------------------------------------------------------
-- VQT_PlaceHoverCard: one shared frame, abutting the panel's LEFT edge beside a hovered place line,
-- listing the quests folded into that line: a difficulty square and the quest title per row. Each
-- row is a button that opens the quest log. The card is interactive: it stays while the mouse is
-- on it, and only hides HOVER_GRACE_SECONDS after the mouse has left BOTH the line and the card,
-- so the player can travel from the line across the gap onto the card.
local hoverCard
local CARD_ROW_H = 14
local CARD_PAD = 8
local CARD_MIN_W = 120
local HOVER_GRACE_SECONDS = 0.35
local hideTimer                     -- C_Timer handle for the pending hide

local function CancelHide() if hideTimer then hideTimer:Cancel(); hideTimer = nil end end

local function SetLineHighlight(row, on)
  if row and row.hover then row.hover:SetShown(on and true or false) end
end

local function HideHoverCardNow()
  CancelHide()
  if hoverCard then SetLineHighlight(hoverCard.row, false); hoverCard:Hide() end
end

-- Leaving the line or the card: hide (card + line wash) after a grace period unless the mouse is on
-- either by then. The line wash shares the grace, so crossing the gap does not flicker it.
local function ScheduleHide()
  CancelHide()
  hideTimer = C_Timer.NewTimer(HOVER_GRACE_SECONDS, function()
    hideTimer = nil
    if not hoverCard or not hoverCard:IsShown() then return end
    local row = hoverCard.row
    if hoverCard:IsMouseOver() or (row and row:IsShown() and row:IsMouseOver()) then return end
    SetLineHighlight(row, false)
    hoverCard:Hide()
  end)
end

local function AcquireHoverCard()
  if hoverCard then return hoverCard end
  hoverCard = CreateFrame("Frame", "VelocityQuestTrackerPlaceCard", UIParent)
  hoverCard:SetFrameStrata("TOOLTIP")
  hoverCard:EnableMouse(true)
  hoverCard:SetScript("OnEnter", CancelHide)
  hoverCard:SetScript("OnLeave", ScheduleHide)
  hoverCard:Hide()
  hoverCard.bg = hoverCard:CreateTexture(nil, "BACKGROUND")
  hoverCard.bg:SetAllPoints()
  hoverCard.bg:SetColorTexture(0.11, 0.14, 0.11, 0.92)          -- the mockup's dark world tone, nearly opaque
  hoverCard.rows = {}
  return hoverCard
end

local function AcquireCardRow(i)
  local card = AcquireHoverCard()
  local r = card.rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, card)
  r:SetHeight(CARD_ROW_H)
  r.square = r:CreateTexture(nil, "ARTWORK")
  r.square:SetSize(T.Square, T.Square); r.square:SetPoint("LEFT", 0, 0)
  r.title = T.Text(r, T.LabelSize, T.Tone.Todo)
  r.title:SetPoint("LEFT", r.square, "RIGHT", 6, 0)
  -- Child buttons swallow the card's OnEnter/OnLeave, so they forward hover state themselves.
  r:SetScript("OnEnter", function(self)
    CancelHide()
    T.SetColour(self.title, T.Tone.Recent)
  end)
  r:SetScript("OnLeave", function(self)
    T.SetColour(self.title, T.Tone.Todo)
    ScheduleHide()
  end)
  r:SetScript("OnClick", function(self)
    if Settings().RequireShiftToInteract and not IsShiftKeyDown() then return end
    if not self.questID then return end
    local ok = NS.Client.OpenQuestLog(self.questID)
    if not ok and InCombatLockdown() then NS.Util.Print("cannot open the quest log in combat") end
    HideHoverCardNow()
  end)
  card.rows[i] = r
  return r
end

-- Show the card for a place line: quests from the group the row currently carries.
local function ShowHoverCard(row)
  if not HoverAllowed() then return end
  local g = row.group
  if not g or #g.quests == 0 then return end
  CancelHide()
  local card = AcquireHoverCard()
  -- a different line took over: drop the old line's wash
  if card.row and card.row ~= row then SetLineHighlight(card.row, false) end
  card.row = row
  SetLineHighlight(row, true)
  local width = CARD_MIN_W
  for i, q in ipairs(g.quests) do
    local r = AcquireCardRow(i)
    r.questID = q.questID
    T.SetColour(r.square, T.DifficultyColour(q.level))
    r.title:SetText(q.title)
    width = math.max(width, T.Square + 6 + r.title:GetStringWidth() + 2 * CARD_PAD)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD, -(CARD_PAD + (i - 1) * CARD_ROW_H))
    r:SetPoint("RIGHT", card, "RIGHT", -CARD_PAD, 0)
    r:Show()
  end
  for i = #g.quests + 1, #card.rows do card.rows[i]:Hide() end
  card:SetSize(width, 2 * CARD_PAD + #g.quests * CARD_ROW_H)
  card:ClearAllPoints()
  -- Abut the PANEL's left edge (not the row's, which is inset by PadX) so there is no gap to cross.
  local panel = NS.Panel and NS.Panel.Frame()
  local anchor = panel or row
  card:SetPoint("TOPRIGHT", anchor, "TOPLEFT", 0, 0)
  card:SetPoint("TOP", row, "TOP", 0, 4)
  card:Show()
end

local function HideHoverCard() ScheduleHide() end

local function NewList(parent, withCheck)
  local list = CreateFrame("Frame", nil, parent)
  list:SetWidth(T.PanelWidth); list:SetHeight(1)
  list.rows = {}
  list.withCheck = withCheck
  return list
end

local function AcquireLine(list, i)
  local row = list.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, list)
  row:SetHeight(LINE_H); row:SetPoint("LEFT", T.PadX, 0); row:SetPoint("RIGHT", -T.PadX, 0)
  row:EnableMouse(true)
  -- hover wash: the block wash tone, a touch stronger, full line width, hidden at rest (no chrome)
  row.hover = row:CreateTexture(nil, "BACKGROUND")
  row.hover:SetPoint("TOPLEFT", -T.PadX, 2); row.hover:SetPoint("BOTTOMRIGHT", T.PadX, -2)
  T.SetColour(row.hover, T.Tone.Wash, T.WashAlpha * 2)
  row.hover:Hide()
  row:SetScript("OnEnter", ShowHoverCard)
  row:SetScript("OnLeave", HideHoverCard)
  local x = 0
  if list.withCheck then
    row.check = row:CreateTexture(nil, "ARTWORK")
    row.check:SetSize(12, 12); row.check:SetPoint("LEFT", 0, 0)
    local atlasOk = row.check.SetAtlas and pcall(row.check.SetAtlas, row.check, "common-icon-checkmark")
    if not (atlasOk and row.check:GetAtlas()) then row.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    row.check:SetVertexColor(T.Tone.Label[1], T.Tone.Label[2], T.Tone.Label[3])
    x = 12 + 8
  end
  row.label = T.Text(row, T.LabelSize, T.Tone.Label)
  row.label:SetPoint("LEFT", x, 0)
  row.squares = T.Squares(row)
  row.squares:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
  list.rows[i] = row
  return row
end

local HIGHLIGHT_SECONDS = 2      -- a square that just joined a place line keeps a yellow outline this long

-- Yellow 1 px outline around a square, created on demand and parked on the squares frame.
local function AcquireOutline(row, i)
  row.outlines = row.outlines or {}
  local o = row.outlines[i]
  if o then return o end
  o = row.squares:CreateTexture(nil, "BORDER")
  T.SetColour(o, T.Tone.Recent)
  row.outlines[i] = o
  return o
end

-- `arrivedFn(q)` returns the GetTime() the quest joined this line, or nil; squares whose arrival is
-- within HIGHLIGHT_SECONDS get the outline. Returns (height, anyHighlighted).
local function Render(list, groups, labelFn, arrivedFn, now)
  local y = 0
  local anyHighlight = false
  for i, g in ipairs(groups) do
    local row = AcquireLine(list, i)
    row.group = g                                    -- the hover card reads this
    if hoverCard and hoverCard:IsShown() and row:IsMouseOver() then ShowHoverCard(row) end   -- live refresh under the cursor
    row.label:SetText(labelFn(g))
    local colours = {}
    for _, q in ipairs(g.quests) do colours[#colours + 1] = T.DifficultyColour(q.level) end
    row.squares:Set(colours)
    for j, q in ipairs(g.quests) do
      local at = arrivedFn and arrivedFn(q)
      local hot = at and now and (now - at) < HIGHLIGHT_SECONDS
      local o = row.outlines and row.outlines[j]
      if hot then
        o = AcquireOutline(row, j)
        local cell = row.squares.cells[j]
        o:ClearAllPoints(); o:SetPoint("TOPLEFT", cell, "TOPLEFT", -1, 1); o:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 1, -1)
        o:Show(); anyHighlight = true
      elseif o then o:Hide() end
    end
    if row.outlines then for j = #g.quests + 1, #row.outlines do row.outlines[j]:Hide() end end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", list, "TOPLEFT", T.PadX, -y)
    row:SetPoint("RIGHT", list, "RIGHT", -T.PadX, 0)
    row:Show()
    y = y + LINE_H + 2
  end
  for i = #groups + 1, #list.rows do list.rows[i]:Hide() end
  if y > 0 then y = y - 2 end
  list:SetHeight(math.max(1, y))
  return y, anyHighlight
end

function Lines.AttachTurnIn(parent)
  if not Lines.turnin then Lines.turnin = NewList(parent, true) end
  return Lines.turnin
end

function Lines.AttachOtherZones(parent)
  if not Lines.other then Lines.other = NewList(parent, false) end
  return Lines.other
end

function Lines.RenderTurnIn(snap)
  local h, hot = Render(Lines.turnin, snap.turninPlaces, function(g) return g.place end, function(q) return q.arrivedAt end, snap.now)
  Lines.highlighting = hot          -- Panel keeps re-rendering while an outline is live
  return h
end

function Lines.RenderOtherZones(snap)
  local h = Render(Lines.other, snap.otherZones, function(g) return string.format("+%d in %s", #g.quests, g.zone) end, nil, snap.now)
  return h
end