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
--
-- INVARIANT (the "tall brick" family of bugs, three recurrences 2026-11-20): layout OWNS every
-- segment's resting size and sets it unconditionally here -- visible or hidden. The pop swell is
-- applied AFTER this, as a pure function of (state, t0, now), and is never stored. So a segment that is
-- hidden mid-swell, or re-laid out to a new width mid-swell, has no stale size to come back with: the
-- next layout puts it at segW x SegHeight before anything else looks at it.
local function LayoutSegments(row, need, hideDone, have)
  local perRow = T.SegPerRow
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
  -- Gap scales with segment width: a 2 px gap between 3 x 18 px bricks reads as one bar (owner
  -- 2026-11-21). Wide bricks get a wider gap, 10-per-row bricks keep the 2 px minimum.
  local gap = math.max(T.SegGap, math.floor(T.BarWidth / cols * 0.12 + 0.5))
  local segW = (T.BarWidth - (cols - 1) * gap) / cols
  -- every segment that exists gets its resting size and the resting layer, shown or not
  for u = 1, need do
    local seg = row.segs[u]
    if not seg then
      seg = row.bar:CreateTexture(nil, "ARTWORK")
      seg.state = "todo"
      row.segs[u] = seg
    end
    seg:SetSize(segW, T.SegHeight)
    seg:SetDrawLayer("ARTWORK")
    seg:Hide()
  end
  for i, u in ipairs(visible) do
    local seg = row.segs[u]
    local r = math.floor((i - 1) / perRow)
    local c = (i - 1) % perRow
    seg:ClearAllPoints()
    seg:SetPoint("TOPLEFT", row.bar, "TOPLEFT", c * (segW + gap), -r * (T.SegHeight + T.SegGap))
    seg:Show()
  end
  for u = need + 1, #row.segs do if row.segs[u] then row.segs[u]:Hide() end end
  local h = rows * T.SegHeight + (rows - 1) * T.SegGap
  row.bar:SetHeight(h)
  return h, segW
end

-- Apply the model's objective to a row. Returns row height.
local function RenderRow(block, idx, obj, quest, now)
  local row = AcquireRow(block, idx)
  local s = Settings()
  row.name:SetText(T.CountlessName(obj.name))
  row.count:SetText(T.CountText(obj.have, obj.need))
  -- segment states from the model: units <= have are done unless a recent timestamp says they are mid-animation
  local recent = quest.recent and quest.recent[obj.index]
  -- A unit whose landing is older than the whole pop+hold+fade is finished: it must settle to "done"
  -- directly. Without this, a /reload (segments recreated as "todo", recentUnits restored from the DB)
  -- re-ran every remembered unit through pop -> hold -> fade from its OLD t0, leaving a mix of
  -- yellow-grey (RecentSeg) and plain Done cells until the next state change (owner 2026-11-20:
  -- "different grey bricks after a restart").
  local animLen = POP_SECONDS + (s.HoldSeconds or 4) + (s.FadeSeconds or 1)
  for u = 1, obj.need do
    local seg = row.segs[u]
    local wasState = seg and seg.state or "todo"
    local at = recent and recent[u]
    if at and (now - at) >= animLen then at = nil end
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
  local barH, segW = LayoutSegments(row, obj.need, s.HideCompletedSegments, obj.have)
  -- row tone: bright until the last unit's fade completes, then label tone
  local allDone = obj.have >= obj.need
  local animating = false
  for u = 1, obj.need do
    local seg = row.segs[u]
    if seg then
      -- State advances for EVERY segment, shown or hidden: a hidden segment frozen in "pop" was the
      -- originating mechanism of the tall-brick bugs (it kept its swollen size until something
      -- happened to render it again).
      if SegStep(seg, now) then animating = true end
      if seg:IsShown() then
        T.SetColour(seg, SegColour(seg, now))
        -- pop swell, applied on top of the resting size layout just set; never stored
        local sx, sy = SegScale(seg, now)
        if sx ~= 1 or sy ~= 1 then
          seg:SetSize(segW * sx, T.SegHeight * sy)
          seg:SetDrawLayer("OVERLAY")
        end
      end
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
-- Click / hover gates live in Core\Interact (Shift settings + not in combat).
local function InteractionAllowed() return NS.Interact.ClickAllowed() end

local function OnTitleEnter(btn)
  -- hover feedback has its own gate ("Hold Shift for hover feedback"); clicks use InteractionAllowed
  if not NS.Interact.HoverAllowed() then return end
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
  -- Shift-click the title of ANY block (active or hand-in card): dismiss it out of the block area
  -- (owner 2026-11-22). Activity is cleared and the quest untracked, so it falls to its line until
  -- a kill / loot / re-track / proximity touches it again. Plain click still opens the quest log.
  if IsShiftKeyDown() then
    local b = btn:GetParent()
    if b then b.departing = true end
    NS.HoverCard.HideNow()
    NS.Model.DismissQuest(btn.questID)
    return
  end
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
  -- Mouse is owned by Core\Interact (off in combat); the title button below is registered the same way.
  NS.Interact.Register(b)
  b.hover = b:CreateTexture(nil, "BACKGROUND"); b.hover:SetAllPoints(); b.hover:SetDrawLayer("BACKGROUND", 1)
  T.SetColour(b.hover, T.Tone.Wash, T.WashAlpha); b.hover:Hide()
  b:SetScript("OnEnter", OnBlockEnter); b:SetScript("OnLeave", OnBlockLeave)
  b:SetScript("OnMouseUp", OnBlockMouseUp)
  -- Title is a button: hover brightens it, click opens the quest log to this quest.
  b.titleButton = CreateFrame("Button", nil, b)
  NS.Interact.Register(b.titleButton)
  b.titleButton:SetPoint("TOP", 0, -6); b.titleButton:SetSize(T.PanelWidth - 2 * T.PadX, T.LabelSize + 4)
  b.titleButton.questID = questID
  b.title = T.Text(b.titleButton, T.LabelSize, T.Tone.Label)
  b.title:SetAllPoints(); b.title:SetJustifyH("CENTER")
  b.titleButton.text = b.title
  b.titleButton:SetScript("OnEnter", OnTitleEnter)
  b.titleButton:SetScript("OnLeave", OnTitleLeave)
  b.titleButton:SetScript("OnClick", OnTitleClick)
  -- timed-quest countdown line (hidden unless the quest has a running timer; see RenderBlock)
  b.timer = T.Text(b, T.RowSize, T.Tone.Recent)
  b.timer:SetJustifyH("CENTER"); b.timer:SetWidth(T.PanelWidth - 2 * T.PadX); b.timer:Hide()
  b.rows = {}
  blocksByQuest[questID] = b
  blockOrder[#blockOrder + 1] = questID
  return b
end

-- Render a block; returns height, and whether anything inside is animating.
-- Timed quest countdown (SPEC-VQT-TimedQuests): "Remaining: mm:ss" centred under the title. Seconds
-- are the model's last sample extrapolated with GetTime(), so no API call per frame; the block
-- reports itself animating while a clock runs so Panel.OnUpdate re-renders every frame.
-- Tones: Recent (yellow) the whole time, Danger (red) under TimerDangerSeconds (owner 2026-11-27).
local TIMER_LINE_GAP = 2
local TIMER_TEXT_SIZE = T.RowSize      -- one step up from the title's LabelSize: a running clock must be obvious
function Blocks.FormatTimer(seconds)
  seconds = math.floor(math.max(0, seconds or 0) + 0.5)
  local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end
local function TimerSecondsLeft(quest, now)
  if not quest.timerRunning or not quest.timerRemainingSeconds then return nil end
  return math.max(0, quest.timerRemainingSeconds - (now - (quest.timerSampledAt or now)))
end
local function TimerTone(left)
  local s = Settings()
  if left < (s.TimerDangerSeconds or 15) then return T.Tone.Danger end
  return T.Tone.Recent
end

local function RenderBlock(b, quest, now)
  local s = Settings()
  b.title:SetText(quest.title)
  -- back from the card shape: the stock centred title is the visible one again
  if b.handin then b.handin.titleGroup:Hide(); b.titleButton.text = b.title end
  if not b.titleButton.hovered then T.SetColour(b.title, T.Tone.Label) end   -- re-apply band tone
  local y = -(6 + T.LabelSize + 4)
  local anyAnim = false
  local timerLeft = TimerSecondsLeft(quest, now)
  if timerLeft then
    b.timer:SetText("Remaining: " .. Blocks.FormatTimer(timerLeft))
    T.SetColour(b.timer, TimerTone(timerLeft))
    b.timer:ClearAllPoints()
    b.timer:SetPoint("TOP", b, "TOP", 0, y - TIMER_LINE_GAP)
    b.timer:Show()
    y = y - TIMER_LINE_GAP - TIMER_TEXT_SIZE - 4
    anyAnim = true                                   -- the clock ticks: re-render each frame
  else
    b.timer:Hide()
  end
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
-- the hand-in row(s). Three shapes (owner 2026-11-21):
--   finisher known, hand-in IN this zone : check | finisher name            | range spark (one marker
--                                          at the finisher's distance, the nearby lines' scale)
--   finisher known, other zone           : check | finisher name
--                                                  place (second line, indented under the name)
--   finisher unknown (no QuestieDB)      : check | place | difficulty square   (M1 row)
-- The check is yellow (Recent) for the hold time after completion so the eye lands on "done, go here".
-- Distance in yards to the finisher (nil = unknown) and its spark fraction 0..1. The hand-in spark is
-- LINEAR over HANDIN_SPARK_RANGE_YARDS, not the nearby lines' sqrt-over-range: that curve spreads a
-- field of spawns, but a single target wants "left edge == here". With sqrt over a 600 yd range the
-- marker sat 9 % in at 5 yd -- visibly off the edge while standing on the NPC (owner 2026-11-21).
-- Anything beyond the range pins to the right end.
local HANDIN_SPARK_RANGE_YARDS = 300
-- Arrival radius: setting HandInArriveYards (Options slider 0..50, default 25; 0 = off). 5 was too tight
-- against approximate spawn coordinates (owner 2026-11-22). The model registers Position watch points at it.
function Blocks.HandInArriveYards() local v = Settings().HandInArriveYards; if v == nil then return 25 end return v end
local function HandInDistance(quest)
  local Position = NS.Position
  if not (quest.turninSpawn and Position and Position.Current()) then return nil end
  return Position.DistanceTo(quest.turninSpawn)
end
local function HandInMarkerFraction(d)
  if not d then return nil end
  return math.min(1, d / HANDIN_SPARK_RANGE_YARDS)
end

local function RenderHandInCard(b, quest, now)
  b.title:SetText(quest.title)
  if not b.titleButton.hovered then T.SetColour(b.title, T.Tone.Label) end   -- re-apply band tone
  for idx = 1, #b.rows do b.rows[idx]:Hide() end
  local h = b.handin
  if not h then
    h = CreateFrame("Frame", nil, b)
    h:SetHeight(T.RowHeight)
    -- The CHECK sits on the TITLE ("this quest is done"), immediately before the title TEXT -- the
    -- title FontString fills the button and centres, so the check is anchored to a shrink-wrapped
    -- copy of the text (h.titleText, below), not to the FontString's left edge (owner 2026-11-21:
    -- "right in front of the quest title"). The row below answers "where to".
    h.check = b.titleButton:CreateTexture(nil, "ARTWORK")
    h.check:SetSize(12, 12)
    local atlasOk = h.check.SetAtlas and pcall(h.check.SetAtlas, h.check, "common-icon-checkmark")
    if not (atlasOk and h.check:GetAtlas()) then h.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    -- check + text as one centred unit: a holder frame sized to both, centred in the title button
    h.titleGroup = CreateFrame("Frame", nil, b.titleButton)
    h.titleGroup:SetPoint("CENTER", b.titleButton, "CENTER", 0, 0); h.titleGroup:SetHeight(T.LabelSize + 4)
    h.check:SetPoint("LEFT", h.titleGroup, "LEFT", 0, 0)
    h.titleText = T.Text(h.titleGroup, T.LabelSize, T.Tone.Label)
    h.titleText:SetPoint("LEFT", h.check, "RIGHT", 6, 0)
    -- turn-in glyph: the quest-giver's "?" bubble is what the game itself puts over a finisher
    h.glyph = h:CreateTexture(nil, "ARTWORK")
    h.glyph:SetSize(14, 14); h.glyph:SetPoint("TOPLEFT", 0, -(T.RowHeight - 14) / 2)
    local glyphOk = h.glyph.SetAtlas and pcall(h.glyph.SetAtlas, h.glyph, "QuestTurnin")
    if not (glyphOk and h.glyph:GetAtlas()) then h.glyph:SetTexture("Interface\\GossipFrame\\ActiveQuestIcon") end
    h.place = T.Text(h, T.RowSize)
    h.place:SetPoint("TOPLEFT", h.glyph, "TOPRIGHT", 8, (T.RowHeight - 14) / 2); h.place:SetHeight(T.RowHeight)
    h.square = h:CreateTexture(nil, "ARTWORK")
    h.square:SetSize(T.Square, T.Square)
    h.square:SetPoint("LEFT", h.place, "RIGHT", 8, 0)
    -- second line: the place under the finisher name (other-zone shape), label tone
    h.sub = T.Text(h, T.LabelSize, T.Tone.Label)
    h.sub:SetPoint("TOPLEFT", h.place, "BOTTOMLEFT", 0, 0); h.sub:SetHeight(T.RowHeight - 2)
    -- range spark (in-zone shape): same geometry as a nearby line, one marker. Anchored to the ROW
    -- only (right edge, centred on the first text line) -- never to h.place, whose RIGHT is anchored
    -- to the spark in the in-zone shape (circular anchor error on first render, 2026-11-21).
    h.spark = CreateFrame("Frame", nil, h)
    h.spark:SetSize(T.SparkWidth, 8); h.spark:SetPoint("TOPRIGHT", h, "TOPRIGHT", 0, -(T.RowHeight - 8) / 2)
    h.spark.base = h.spark:CreateTexture(nil, "BACKGROUND")
    h.spark.base:SetHeight(1); h.spark.base:SetPoint("LEFT", 0, 0); h.spark.base:SetPoint("RIGHT", 0, 0)
    h.spark.mark = h.spark:CreateTexture(nil, "ARTWORK"); h.spark.mark:SetSize(T.SparkMark, T.SparkMark)
    b.handin = h
  end
  local place = quest.turninPlace or quest.zoneName or "?"
  local zone = NS.Model.Current().zone
  local inZone = quest.turninZone ~= nil and quest.turninZone == zone
  local lines = 1
  local dist = nil                                     -- yards to the finisher (in-zone shape only)
  if quest.turninName and inZone then
    h.place:SetText(quest.turninName)
    h.square:Hide(); h.sub:Hide()
    dist = HandInDistance(quest)
    local f = HandInMarkerFraction(dist)
    if f then
      T.SetColour(h.spark.base, T.Tone.Todo, 0.35); T.SetColour(h.spark.mark, T.Tone.Todo)
      h.spark.mark:ClearAllPoints(); h.spark.mark:SetPoint("LEFT", h.spark, "LEFT", math.floor(f * (T.SparkWidth - T.SparkMark) + 0.5), 0)
      h.spark:Show(); h.place:SetPoint("RIGHT", h.spark, "LEFT", -T.ColGap, 0)
    else h.spark:Hide(); h.place:SetPoint("RIGHT", h, "RIGHT", 0, 0) end
  elseif quest.turninName then
    h.place:SetText(quest.turninName); h.place:SetPoint("RIGHT", h, "RIGHT", 0, 0)
    h.sub:SetText(place); T.SetColour(h.sub, T.Tone.Label); h.sub:Show()
    h.square:Hide(); h.spark:Hide()
    lines = 2
  else
    h.place:SetText(place); h.place:SetPoint("RIGHT", h, "RIGHT", -(8 + T.Square), 0)
    T.SetColour(h.square, T.DifficultyColour(quest.level)); h.square:Show()
    h.sub:Hide(); h.spark:Hide()
  end
  -- Tones: yellow (Recent) for the hold window after completion, then the MUTED done tone for every
  -- part of the card -- check, title, NPC name, glyph, spark (owner 2026-11-21: a finished quest is
  -- not work, it should not sit at Todo brightness next to the active blocks). A green check is the
  -- one accent; it is tinted toward Label so it recedes too.
  local sinceDone = quest.lastActivityAt and (now - quest.lastActivityAt) or math.huge
  local hold = Settings().HoldSeconds or 4
  local fade = Settings().FadeSeconds or 1
  local c
  if sinceDone < hold then c = T.Tone.Recent
  elseif sinceDone < hold + fade then local r, g, bb = Util.Lerp3(T.Tone.Recent, T.Tone.Label, (sinceDone - hold) / fade); c = { r, g, bb }
  else c = T.Tone.Label end
  h.check:SetVertexColor(0.45, 0.75, 0.45)            -- muted green: done, not shouting
  h.glyph:SetVertexColor(c[1], c[2], c[3])
  -- Card flash (owner 2026-11-21): on completion the WHOLE card background goes medium-bright yellow
  -- and settles back to the plain wash. Wash colour + alpha only; no size change. Audit 2026-11-21:
  -- the first cut (peak 0.45 -> hold 0.25 of pale Recent over a 0.06 wash) was not noticed at all,
  -- so: a 0.5 s white->yellow pop at 0.70, the hold at 0.45 solid yellow, then the FadeSeconds fade
  -- to whatever the terrain wash is. Nothing else on the card is this bright, so it cannot be missed.
  local CARD_POP = 0.5
  local PEAK_A, HOLD_A = 0.70, 0.45
  local washC, washA = T.Tone.Wash, T.WashAlpha
  if sinceDone < CARD_POP then
    local t = sinceDone / CARD_POP
    local r, g, bb
    if t < 0.4 then r, g, bb = Util.Lerp3(T.Tone.PopA, T.Tone.PopB, t / 0.4) else r, g, bb = Util.Lerp3(T.Tone.PopB, T.Tone.Recent, (t - 0.4) / 0.6) end
    washC, washA = { r, g, bb }, PEAK_A + (HOLD_A - PEAK_A) * t
  elseif sinceDone < hold then
    washC, washA = T.Tone.Recent, HOLD_A
  elseif sinceDone < hold + fade then
    local k = (sinceDone - hold) / fade
    local r, g, bb = Util.Lerp3(T.Tone.Recent, T.Tone.Wash, k)
    washC, washA = { r, g, bb }, HOLD_A + (T.WashAlpha - HOLD_A) * k
  end
  -- Arrival (owner 2026-11-21): standing at the finisher (within HANDIN_ARRIVE_YARDS) holds the card
  -- at the dim yellow for as long as you are there -- "you are here, hand it in". Position reports on
  -- >= 15 yd moves, so the rebuild that brings you inside 5 yd is the one that lights it.
  -- Half the hold alpha (owner 2026-11-22: full HOLD_A was too loud for a state you sit in).
  local arrived = dist ~= nil and dist <= Blocks.HandInArriveYards() and Blocks.HandInArriveYards() > 0
  if arrived and sinceDone >= hold then washC, washA = T.Tone.Recent, HOLD_A * 0.5 end
  T.SetColour(b.wash, washC, washA)
  -- card title = [check] text, centred as one unit; the stock centred title is blanked for the card
  -- shape (RenderBlock re-sets its text, so a block reverting from a card gets it back)
  h.titleText:SetText(quest.title)
  T.SetColour(h.titleText, b.titleButton.hovered and T.Tone.Todo or c)
  h.titleGroup:SetWidth(12 + 6 + h.titleText:GetStringWidth())
  h.titleGroup:Show(); h.check:Show()
  b.title:SetText("")
  b.titleButton.text = h.titleText           -- hover brightening targets the visible text
  T.SetColour(h.place, c)
  T.SetColour(h.spark.base, c, 0.35); T.SetColour(h.spark.mark, c)
  -- Timed delivery (SPEC-VQT-TimedQuests): most timed quests are complete on accept and the clock runs
  -- until hand-in, so the hand-in card carries the "Remaining:" line too, under the title.
  local titleBottom = 6 + T.LabelSize + 4
  local timerLeft = TimerSecondsLeft(quest, now)
  if timerLeft then
    b.timer:SetText("Remaining: " .. Blocks.FormatTimer(timerLeft))
    T.SetColour(b.timer, TimerTone(timerLeft))
    b.timer:ClearAllPoints()
    b.timer:SetPoint("TOP", b, "TOP", 0, -(titleBottom + TIMER_LINE_GAP))
    b.timer:Show()
    titleBottom = titleBottom + TIMER_LINE_GAP + T.LabelSize + 4
  else
    b.timer:Hide()
  end
  local rowH = T.RowHeight + (lines - 1) * (T.RowHeight - 2)
  h:SetHeight(rowH)
  h:ClearAllPoints()
  h:SetPoint("TOPLEFT", b, "TOPLEFT", T.PadX, -titleBottom)
  h:SetPoint("RIGHT", b, "RIGHT", -T.PadX, 0)
  h:Show()
  local height = titleBottom + rowH + 6
  b:SetHeight(height)
  return height, sinceDone < hold + fade or arrived or timerLeft ~= nil
end

-- Public ------------------------------------------------------------------------------
function Blocks.Attach(parent)
  if container then return container end
  container = CreateFrame("Frame", nil, parent)
  container:SetWidth(T.PanelWidth)
  container:SetHeight(1)
  return container
end

-- Other-zone grace cards (model category "other_card"): a block for a quest just accepted / just
-- completed whose work is elsewhere, drawn in PART 4 under that zone's "+N in Zone" line so the zone
-- is the heading. Separate pool from the part-2 blocks so the same quest moving part 2 <-> part 4
-- never fights over one frame. Returns height drawn.
local otherPool = {}            -- questID -> block frame (parented to the caller's list)
-- `live` is shared across the caller's zone groups: cards drawn for an earlier group must not be hidden
-- by a later group's call (2026-11-22: the Loch Modan cards vanished, leaving their gap, as soon as
-- the Dun Morogh group rendered). The caller finishes with Blocks.HideOtherCardsExcept(live).
function Blocks.RenderOtherCards(parent, cards, now, y0, live)
  local y = y0
  for _, q in ipairs(cards) do
    if live then live[q.questID] = true end
    local b = otherPool[q.questID]
    if not b then
      -- AcquireBlock parents to the part-2 container and registers in blockOrder; take it out again
      b = AcquireBlock(q.questID); blocksByQuest[q.questID] = nil
      for i = #blockOrder, 1, -1 do if blockOrder[i] == q.questID then table.remove(blockOrder, i) end end
      b:SetParent(parent); otherPool[q.questID] = b
    end
    b.quest = q; b.departing = nil
    T.ApplyWash(b.wash); T.ApplyWash(b.hover, 1)
    local h
    if q.isComplete then h = RenderHandInCard(b, q, now) else h = RenderBlock(b, q, now); if b.handin then b.handin:Hide() end end
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -y); b:Show()
    y = y + h + 2
  end
  return y - y0
end

function Blocks.HideOtherCardsExcept(live) for qid, b in pairs(otherPool) do if not live[qid] then b:Hide() end end end

-- A quest leaving the other-card pool for the part-2 block must get a fresh frame there.
function Blocks.ReleaseOtherCard(questID) local b = otherPool[questID]; if b then b:Hide(); otherPool[questID] = nil end end

-- Draw every active quest in slot order. Completed quests whose last fade is still running are
-- kept (the model already moved them to turnin; we keep the block until its animation ends).
local lingering = {}   -- questID -> quest (complete, animating out)

function Blocks.Render(snap)
  -- ANIMATION CLOCK IS GetTime(), NEVER snap.now. snap.now is stamped once per model build, and Panel
  -- re-renders the SAME snapshot every frame while animating: with snap.now the pop sat at t=0 for
  -- every frame -> full swell (1.15 x 3.4) until the next rebuild. The "tall brick" root cause
  -- (fourth recurrence, 2026-11-20): layout was right, time was frozen.
  local now = GetTime()
  local present = {}
  local y = 0
  local anyAnim = false
  -- questIDs whose block wants an item button this pass (reconciled against live buttons at the end)
  local keepButtons = {}
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
    if q then
      b.quest = q                                    -- the hover card reads this
      -- washes follow the terrain band (LibZoneBrightness): re-read the live alpha each render
      T.ApplyWash(b.wash); T.ApplyWash(b.hover, 1)
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
        -- Guarded: an item-button failure must never take the panel layout down with it.
        local ok, err = pcall(function()
          local itemID, showWhenComplete = NS.Client.QuestItem(qid)
          if itemID and (not q.isComplete or showWhenComplete) then
            NS.ItemButtons.Want(qid, itemID, b)
            keepButtons[qid] = true
          end
        end)
        if not ok then Util.Raise("item button for quest " .. qid, err) end
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
  local okR, errR = pcall(NS.ItemButtons.Reconcile, keepButtons)
  if not okR then Util.Raise("item button reconcile", errR) end
  return y
end