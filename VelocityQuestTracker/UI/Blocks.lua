-- Velocity Quest Tracker: part 2, the actionable blocks. One block per active quest; one row per
-- objective (name | segmented bar | count). Segments: 10 per segment row, wrapping. Each unit that
-- lands runs its own pop -> hold -> fade; the row dims with the fade of its last unit.
--
-- Rows and blocks are keyed by questID / objective index and reused, so nothing jumps.
-- Blocks.Render(snapshot) returns the total height drawn.
local ADDON_NAME, NS = ...
local T, Util = NS.Theme, NS.Util

local Blocks = {}
NS.Blocks = Blocks

local POP_SECONDS = 0.28

local container
local blocksByQuest = {}            -- questID -> block frame
local blockOrder = {}               -- questID list in slot order (append only)

local function Settings() return NS.db and NS.db.settings or {} end

-- Segment animation ---------------------------------------------------------------------
-- seg.state: "todo" | "pop" | "hold" | "fade" | "done"; seg.t0 = phase start
-- Pop (SPEC: "flashes white and swells, settles to yellow"): 0-60 % white -> pale, scale 1.15 x 3.4 ->
-- 1.05 x 1.8; 60-100 % pale -> held yellow, scale -> 1. Hold is the faint yellow; fade goes to Done.
local POP_SWELL_X, POP_SWELL_Y = 1.15, 3.4
local POP_SETTLE_X, POP_SETTLE_Y = 1.05, 1.8

local function SegColour(seg, now)
  local st = seg.state
  if st == "todo" then return T.Tone.Todo end
  if st == "done" then return T.Tone.Done end
  if st == "pop" then
    local t = Util.Clamp((now - seg.t0) / POP_SECONDS, 0, 1)
    if t < 0.6 then local r, g, b = Util.Lerp3(T.Tone.PopA, T.Tone.PopB, t / 0.6); return { r, g, b } end
    local r, g, b = Util.Lerp3(T.Tone.PopB, T.Tone.RecentSeg, (t - 0.6) / 0.4); return { r, g, b }
  end
  if st == "hold" then return T.Tone.RecentSeg end
  if st == "fade" then
    local fadeS = Settings().FadeSeconds or 1
    local t = Util.Clamp((now - seg.t0) / fadeS, 0, 1)
    local r, g, b = Util.Lerp3(T.Tone.RecentSeg, T.Tone.Done, t); return { r, g, b }
  end
  return T.Tone.Done
end

-- Scale multipliers (x, y) for the pop swell; 1, 1 outside the pop phase.
local function SegScale(seg, now)
  if seg.state ~= "pop" then return 1, 1 end
  local t = Util.Clamp((now - seg.t0) / POP_SECONDS, 0, 1)
  if t < 0.6 then
    local k = t / 0.6
    return POP_SWELL_X + (POP_SETTLE_X - POP_SWELL_X) * k, POP_SWELL_Y + (POP_SETTLE_Y - POP_SWELL_Y) * k
  end
  local k = (t - 0.6) / 0.4
  return POP_SETTLE_X + (1 - POP_SETTLE_X) * k, POP_SETTLE_Y + (1 - POP_SETTLE_Y) * k
end

-- Advance a segment's phase. Returns true while still animating.
local function SegStep(seg, now)
  local st = seg.state
  if st == "pop" and now - seg.t0 >= POP_SECONDS then seg.state = "hold"; seg.t0 = now; st = "hold" end
  if st == "hold" and now - seg.t0 >= (Settings().HoldSeconds or 4) then seg.state = "fade"; seg.t0 = now; st = "fade" end
  if st == "fade" and now - seg.t0 >= (Settings().FadeSeconds or 1) then seg.state = "done"; st = "done" end
  return st == "pop" or st == "hold" or st == "fade"
end

-- Row widgets -------------------------------------------------------------------------
local function AcquireRow(block, idx)
  local row = block.rows[idx]
  if row then return row end
  row = CreateFrame("Frame", nil, block)
  row:SetHeight(T.RowHeight)
  row.name = T.Text(row, T.RowSize)
  row.name:SetPoint("LEFT", 0, 0)
  row.count = T.Text(row, T.RowSize)
  row.count:SetPoint("RIGHT", 0, 0); row.count:SetJustifyH("RIGHT"); row.count:SetWidth(T.CountWidth)
  row.bar = CreateFrame("Frame", nil, row)
  row.bar:SetSize(T.BarWidth, T.SegHeight)
  row.bar:SetPoint("RIGHT", row.count, "LEFT", -T.ColGap, 0)
  row.name:SetPoint("RIGHT", row.bar, "LEFT", -T.ColGap, 0)
  row.segs = {}
  block.rows[idx] = row
  return row
end

-- Lay out `need` segments in rows of T.SegPerRow inside row.bar; returns bar height.
local function LayoutSegments(row, need, hideDone, have)
  local perRow = T.SegPerRow
  local shown = 0
  local visible = {}
  for u = 1, need do
    if not (hideDone and u <= have and (row.segs[u] == nil or row.segs[u].state == "done" or row.segs[u].state == "todo")) then
      visible[#visible + 1] = u
    end
  end
  local n = #visible
  local rows = math.max(1, math.ceil(n / perRow))
  local cols = math.min(n, perRow)
  if cols < 1 then cols = 1 end
  local segW = (T.BarWidth - (cols - 1) * T.SegGap) / cols
  for i, u in ipairs(visible) do
    local seg = row.segs[u]
    if not seg then
      seg = row.bar:CreateTexture(nil, "ARTWORK")
      seg.state = "todo"
      row.segs[u] = seg
    end
    local r = math.floor((i - 1) / perRow)
    local c = (i - 1) % perRow
    seg:ClearAllPoints()
    seg:SetSize(segW, T.SegHeight)
    seg:SetPoint("TOPLEFT", row.bar, "TOPLEFT", c * (segW + T.SegGap), -r * (T.SegHeight + T.SegGap))
    seg:Show()
    shown = shown + 1
  end
  for u, seg in pairs(row.segs) do
    local isVisible = false
    for _, v in ipairs(visible) do if v == u then isVisible = true break end end
    if not isVisible then seg:Hide() end
  end
  local h = rows * T.SegHeight + (rows - 1) * T.SegGap
  row.bar:SetHeight(h)
  return h
end

-- Apply the model's objective to a row. Returns row height.
local function RenderRow(block, idx, obj, quest, now)
  local row = AcquireRow(block, idx)
  local s = Settings()
  row.name:SetText(obj.name)
  row.count:SetText(string.format("%d/%d", obj.have, obj.need))
  -- segment states from the model: units <= have are done unless a recent timestamp says they are mid-animation
  local recent = quest.recent and quest.recent[obj.index]
  for u = 1, obj.need do
    local seg = row.segs[u]
    local wasState = seg and seg.state or "todo"
    local at = recent and recent[u]
    local newState
    if u > obj.have then newState = "todo"
    elseif at and wasState == "todo" then newState = "pop"
    elseif at and wasState ~= "done" and wasState ~= "todo" then newState = wasState
    else newState = "done" end
    if not seg then
      seg = row.bar:CreateTexture(nil, "ARTWORK"); row.segs[u] = seg; seg.state = "todo"
    end
    if newState ~= seg.state then
      seg.state = newState
      if newState == "pop" then seg.t0 = at or now end
    end
  end
  for u = obj.need + 1, #row.segs do if row.segs[u] then row.segs[u]:Hide() end end
  local barH = LayoutSegments(row, obj.need, s.HideCompletedSegments, obj.have)
  -- row tone: bright until the last unit's fade completes, then label tone
  local allDone = obj.have >= obj.need
  local animating = false
  for u = 1, obj.need do
    local seg = row.segs[u]
    if seg and seg:IsShown() then
      T.SetColour(seg, SegColour(seg, now))
      -- pop swell: grow around the segment's own centre so neighbours are not displaced
      local sx, sy = SegScale(seg, now)
      if sx ~= 1 or sy ~= 1 then
        local w, h = seg.baseW or seg:GetWidth(), T.SegHeight
        seg.baseW = w
        seg:SetSize(w * sx, h * sy)
        seg:SetDrawLayer("OVERLAY")
      elseif seg.baseW then
        seg:SetSize(seg.baseW, T.SegHeight); seg.baseW = nil; seg:SetDrawLayer("ARTWORK")
      end
      if SegStep(seg, now) then animating = true end
    end
  end
  if allDone then
    -- Text dims on the same clock as the last unit: bright for Hold after it landed, then a Fade to
    -- the label tone. Keyed to the unit's landing time (model), not the segment's phase, so a row
    -- that arrived already complete (or was mid-hold at /reload) dims on schedule instead of
    -- sitting bright until some animation happens to finish.
    local landedAt = recent and recent[obj.need]
    local hold, fadeS = s.HoldSeconds or 4, s.FadeSeconds or 1
    local since = landedAt and (now - landedAt) or math.huge
    local c
    if since < hold then c = T.Tone.Todo
    elseif since < hold + fadeS then local r, g, b = Util.Lerp3(T.Tone.Todo, T.Tone.Label, (since - hold) / fadeS); c = { r, g, b }
    else c = T.Tone.Label end
    T.SetColour(row.name, c); T.SetColour(row.count, c)
    if since < hold + fadeS then animating = true end
  else
    T.SetColour(row.name, T.Tone.Todo); T.SetColour(row.count, T.Tone.Todo)
  end
  row.animating = animating
  row.allDone = allDone
  local h = math.max(T.RowHeight, barH + 6)
  row:SetHeight(h)
  return h, animating, allDone
end

-- Block widgets -----------------------------------------------------------------------
-- True when a click/hover on the panel should be honoured: always, or only with Shift held when
-- the "Require Shift key to interact with panel" setting is on.
local function InteractionAllowed()
  return not Settings().RequireShiftToInteract or IsShiftKeyDown()
end

local function OnTitleEnter(btn)
  -- hover feedback has its own gate ("Hold Shift for hover feedback"); clicks use InteractionAllowed
  if Settings().RequireShiftForHover and not IsShiftKeyDown() then return end
  T.SetColour(btn.text, T.Tone.Todo)
  btn.hovered = true
  -- the title is a child button and swallows the block's OnEnter: forward the hover to the card
  local b = btn:GetParent()
  if b and b.quest then NS.HoverCard.ShowBlock(b, b.quest) end
end

local function OnTitleLeave(btn)
  T.SetColour(btn.text, T.Tone.Label)
  btn.hovered = false
  NS.HoverCard.ScheduleHide()
end

-- Hover anywhere on the block body: same card (block mode) for this quest.
-- A block on its way out (dismissed, or lingering through its final fade) must NOT open a card: the
-- re-layout under the cursor fires OnEnter, the card re-opens anchored to a block that is about to
-- hide, and if the card opened under the cursor the watchdog never sees "away" (owner 2026-11-20:
-- stuck card after a dismiss click).
local function OnBlockEnter(b)
  if b.quest and not b.departing then NS.HoverCard.ShowBlock(b, b.quest) end
end
local function OnBlockLeave() NS.HoverCard.ScheduleHide() end

-- Click on a HAND-IN card's body (not its title, which is its own button): dismiss it to the turn-in
-- line. Blocks for incomplete quests ignore body clicks.
local function OnBlockMouseUp(b, button)
  if button ~= "LeftButton" then return end
  if not InteractionAllowed() then return end
  local q = b.quest
  if q and q.category == "turnin_card" then
    b.departing = true                     -- cleared when the block is next shown for a live quest
    NS.HoverCard.HideNow(); NS.Model.DismissQuest(q.questID)
  end
end

local function OnTitleClick(btn)
  if not InteractionAllowed() then return end
  local ok = NS.Client.OpenQuestLog(btn.questID)
  if not ok and InCombatLockdown() then Util.Print("cannot open the quest log in combat") end
end

local function AcquireBlock(questID)
  local b = blocksByQuest[questID]
  if b then return b end
  b = CreateFrame("Frame", nil, container)
  b:SetWidth(T.PanelWidth)
  b.wash = b:CreateTexture(nil, "BACKGROUND")
  b.wash:SetAllPoints()
  T.SetColour(b.wash, T.Tone.Wash, T.WashAlpha)
  -- Hover: block body is mouse-enabled (the card needs an OnEnter); row.hover is the brighter wash
  -- the shared card toggles while it is up, the same convention as the place / nearby lines.
  b:EnableMouse(true)
  b.hover = b:CreateTexture(nil, "BACKGROUND"); b.hover:SetAllPoints(); b.hover:SetDrawLayer("BACKGROUND", 1)
  T.SetColour(b.hover, T.Tone.Wash, T.WashAlpha); b.hover:Hide()
  b:SetScript("OnEnter", OnBlockEnter); b:SetScript("OnLeave", OnBlockLeave)
  b:SetScript("OnMouseUp", OnBlockMouseUp)
  -- Title is a button: hover brightens it, click opens the quest log to this quest.
  b.titleButton = CreateFrame("Button", nil, b)
  b.titleButton:SetPoint("TOP", 0, -6); b.titleButton:SetSize(T.PanelWidth - 2 * T.PadX, T.LabelSize + 4)
  b.titleButton.questID = questID
  b.title = T.Text(b.titleButton, T.LabelSize, T.Tone.Label)
  b.title:SetAllPoints(); b.title:SetJustifyH("CENTER")
  b.titleButton.text = b.title
  b.titleButton:SetScript("OnEnter", OnTitleEnter)
  b.titleButton:SetScript("OnLeave", OnTitleLeave)
  b.titleButton:SetScript("OnClick", OnTitleClick)
  b.rows = {}
  blocksByQuest[questID] = b
  blockOrder[#blockOrder + 1] = questID
  return b
end

-- Render a block; returns height, and whether anything inside is animating.
local function RenderBlock(b, quest, now)
  local s = Settings()
  b.title:SetText(quest.title)
  local y = -(6 + T.LabelSize + 4)
  local anyAnim = false
  local shownRows = 0
  for idx, obj in ipairs(quest.objectives) do
    local row = AcquireRow(b, idx)
    local h, animating, allDone = RenderRow(b, idx, obj, quest, now)
    if animating then anyAnim = true end
    if s.HideCompletedRows and allDone and not animating then
      row:Hide()
    else
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", b, "TOPLEFT", T.PadX, y)
      row:SetPoint("RIGHT", b, "RIGHT", -T.PadX, 0)
      row:Show()
      y = y - h - (T.RowGap - 2)
      shownRows = shownRows + 1
    end
  end
  for idx = #quest.objectives + 1, #b.rows do b.rows[idx]:Hide() end
  local h = -y + 6
  b:SetHeight(h)
  return h, anyAnim, shownRows
end

-- A complete quest, still recently active: the block becomes a hand-in card. Title as usual, then
-- one bright row: check glyph, the hand-in place (q.turninPlace), a difficulty square. The check is
-- yellow (Recent) for the hold time after completion so the eye lands on "done, go here".
local function RenderHandInCard(b, quest, now)
  b.title:SetText(quest.title)
  for idx = 1, #b.rows do b.rows[idx]:Hide() end
  local h = b.handin
  if not h then
    h = CreateFrame("Frame", nil, b)
    h:SetHeight(T.RowHeight)
    h.check = h:CreateTexture(nil, "ARTWORK")
    h.check:SetSize(14, 14); h.check:SetPoint("LEFT", 0, 0)
    local atlasOk = h.check.SetAtlas and pcall(h.check.SetAtlas, h.check, "common-icon-checkmark")
    if not (atlasOk and h.check:GetAtlas()) then h.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    h.place = T.Text(h, T.RowSize)
    h.place:SetPoint("LEFT", h.check, "RIGHT", 8, 0)
    h.square = h:CreateTexture(nil, "ARTWORK")
    h.square:SetSize(T.Square, T.Square)
    h.square:SetPoint("LEFT", h.place, "RIGHT", 8, 0)
    b.handin = h
  end
  h.place:SetText(quest.turninPlace or quest.zoneName or "?")
  T.SetColour(h.square, T.DifficultyColour(quest.level))
  -- check tone: yellow for the hold window after completion, then label tone
  local sinceDone = quest.lastActivityAt and (now - quest.lastActivityAt) or math.huge
  local hold = Settings().HoldSeconds or 4
  local fade = Settings().FadeSeconds or 1
  local c
  if sinceDone < hold then c = T.Tone.Recent
  elseif sinceDone < hold + fade then local r, g, bb = Util.Lerp3(T.Tone.Recent, T.Tone.Label, (sinceDone - hold) / fade); c = { r, g, bb }
  else c = T.Tone.Label end
  h.check:SetVertexColor(c[1], c[2], c[3])
  T.SetColour(h.place, T.Tone.Todo)
  h:ClearAllPoints()
  h:SetPoint("TOPLEFT", b, "TOPLEFT", T.PadX, -(6 + T.LabelSize + 4))
  h:SetPoint("RIGHT", b, "RIGHT", -T.PadX, 0)
  h:Show()
  local height = 6 + T.LabelSize + 4 + T.RowHeight + 6
  b:SetHeight(height)
  return height, sinceDone < hold + fade
end

-- Public ------------------------------------------------------------------------------
function Blocks.Attach(parent)
  if container then return container end
  container = CreateFrame("Frame", nil, parent)
  container:SetWidth(T.PanelWidth)
  container:SetHeight(1)
  return container
end

-- Draw every active quest in slot order. Completed quests whose last fade is still running are
-- kept (the model already moved them to turnin; we keep the block until its animation ends).
local lingering = {}   -- questID -> quest (complete, animating out)

function Blocks.Render(snap)
  local now = snap.now or GetTime()
  local present = {}
  local y = 0
  local anyAnim = false
  -- ensure blocks exist for every active quest (appends new ones to slot order)
  for _, q in ipairs(snap.byCategory.active) do AcquireBlock(q.questID); present[q.questID] = q end
  -- complete-but-recent quests stay as a hand-in card in the same slot
  for _, q in ipairs(snap.byCategory.turnin_card or {}) do AcquireBlock(q.questID); present[q.questID] = q end
  -- lingering complete quests: still drawn while fading
  for _, q in ipairs(snap.byCategory.turnin) do
    local b = blocksByQuest[q.questID]
    if b and (lingering[q.questID] or b.lastAnimating) then present[q.questID] = q; lingering[q.questID] = q end
  end
  for _, qid in ipairs(blockOrder) do
    local b = blocksByQuest[qid]
    local q = present[qid]
    local keepButtons = Blocks._keepButtons; if not keepButtons then keepButtons = {}; Blocks._keepButtons = keepButtons end
    if q then
      b.quest = q                                    -- the hover card reads this
      -- a block re-shown for a live quest is no longer departing (re-tracked after a dismiss)
      if not lingering[qid] and (q.category == "active" or q.category == "turnin_card") then b.departing = nil end
      if NS.HoverCard.IsShownFor(b) then NS.HoverCard.ShowBlock(b, q) end   -- live refresh under the cursor
      local h, anim
      -- A complete quest in turnin_card is a card at once: the final segment's hold/fade belongs to
      -- the row shape it just left, not to the card (waiting on it delayed the hand-in place ~5 s).
      if q.category == "turnin_card" then h, anim = RenderHandInCard(b, q, now)
      elseif q.isComplete and not lingering[qid] and not b.lastAnimating then h, anim = RenderHandInCard(b, q, now)
      else h, anim = RenderBlock(b, q, now); if b.handin then b.handin:Hide() end end
      b.lastAnimating = anim
      if anim then anyAnim = true end
      if lingering[qid] and not anim then
        lingering[qid] = nil; b.departing = nil; b:Hide()
      else
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -y); b:Show()
        y = y + h + T.PartGap
        -- Usable quest item: a secure button beside the block (active or hand-in card). Complete
        -- quests keep theirs only when the log says the item is still relevant (showWhenComplete).
        local itemID, showWhenComplete = NS.Client.QuestItem(qid)
        if itemID and (not q.isComplete or showWhenComplete) then
          NS.ItemButtons.Want(qid, itemID, b)
          keepButtons[qid] = true
        end
      end
    else
      -- hidden: if the hover card was anchored here, take it down too (its row just vanished)
      if NS.HoverCard.IsShownFor(b) then NS.HoverCard.HideNow() end
      b:Hide(); b.lastAnimating = false; lingering[qid] = nil; b.departing = nil
    end
  end
  -- compact slot order: drop quests no longer in the log
  local keep = {}
  for _, qid in ipairs(blockOrder) do
    local inLog = false
    for _, q in ipairs(snap.quests) do if q.questID == qid then inLog = true break end end
    if inLog then keep[#keep + 1] = qid else blocksByQuest[qid]:Hide(); blocksByQuest[qid] = nil end
  end
  blockOrder = keep
  if y > 0 then y = y - T.PartGap end
  container:SetHeight(math.max(1, y))
  Blocks.animating = anyAnim
  -- item buttons: drop any not wanted by a block drawn this pass
  NS.ItemButtons.Reconcile(keepButtons)
  wipe(keepButtons)
  return y
end