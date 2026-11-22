-- Velocity Quest Tracker: tones, font, geometry and widget factories. SPEC "Visual language".
-- Tone hex values are the mockup's starting points; the account DB can override them (M2).
local ADDON_NAME, NS = ...
local Util = NS.Util

local T = {}
NS.Theme = T

T.Font       = "Fonts\\ARIALN.TTF"
T.RowSize    = 13      -- objective row text (mockup 14)
T.LabelSize  = 11      -- quest title, place lines, key (mockup 12)
T.PanelWidth = 250
T.PadX       = 10      -- horizontal inset inside blocks and lines
T.PartGap    = 8       -- vertical gap between the four parts and between blocks
T.RowGap     = 5
T.RowHeight  = 16
T.SegHeight  = 4
T.SegGap     = 2
-- Horizontal gap between segments for a row of `cols` bricks: 12 % of the brick width, never under
-- SegGap. Wide bricks (few units) get a visible gap; 10-per-row bricks keep 2 px.
function T.SegGapFor(cols) return math.max(T.SegGap, math.floor(T.BarWidth / math.max(1, cols) * 0.12 + 0.5)) end
T.SegPerRow  = 10      -- segments per segment row; more units wrap to further rows
T.BarWidth   = 56
T.CountWidth = 28
T.ColGap     = 8
T.Square     = 5       -- difficulty squares on the place lines
T.SquareGap  = 3
T.SparkWidth = 60      -- line view
T.SparkMark  = 4
T.ShapeSize  = 7

-- Tones: {r,g,b} 0..1. T.Base holds the mockup palette and never changes; T.Tone is what the views
-- read, re-derived from T.Base through LibZoneBrightness whenever the terrain band changes, so
-- greys and washes stay readable over Westfall sand as well as Duskwood canopy (SPECS\LibZoneBrightness.md).
local function Tone(hex) return { Util.HexToRGB(hex) } end
T.Base = {
  Todo   = Tone("#f2f2ea"),   -- bright: still to do
  Near   = Tone("#aab1aa"),   -- middle: nearby work not started
  Done   = Tone("#566058"),   -- dim: done units
  Label  = Tone("#8d958e"),   -- dim: labels, place names, quest titles
  Recent = Tone("#ffcf4d"),   -- yellow: just happened (check glyph, outlines, text)
  RecentSeg = Tone("#a08a38"),-- yellow at done-cell brightness: the held segment itself, so it reads as a tinted done cell
  PopA   = Tone("#ffffff"),
  PopB   = Tone("#ffe89a"),
  Wash   = { 1, 1, 1 },       -- block wash colour; alpha below
  WashAlpha = 0.06,
  -- Surface: the opaque backing behind the hover card and the map field. NEUTRAL dark grey, no hue.
  -- The earlier #222923 (green channel highest) read as swamp-green beside the bag's brown and the
  -- panel's white wash (owner 2026-11-22). Tinting a surface is for accents; backings stay neutral.
  Surface = Tone("#1c1c1e"),
}
T.Tone = {}
T.WashAlpha = T.Base.WashAlpha
T.Band = "normal"               -- current LibZoneBrightness band

-- Which base tones take which adjustment role. Yellows and the pop whites are left alone: they are
-- accents, and brightening white does nothing.
-- Near is a mid-grey that reads as "dim" on sand: with the text factor (x1.15) the range-view lines
-- came out duller than the already-lifted place lines (Westfall 2026-11-20), so it takes the dim lift.
local ROLE = { Todo = "text", Near = "dim", Label = "dim", Done = "dim" }

local function ZB() return LibStub and LibStub("LibZoneBrightness-1.0", true) end

-- Re-derive T.Tone / T.WashAlpha for a band. Views read T.Tone at draw time, so one Panel.Render
-- applies it; textures that were coloured once (washes) are re-coloured by T.ApplyWash on render.
function T.Retheme(band)
  local zb = ZB()
  band = band or (zb and zb:GetBand()) or "normal"
  T.Band = band
  for name, base in pairs(T.Base) do
    if name ~= "WashAlpha" then
      local role = ROLE[name]
      if zb and role then
        local r, g, b = zb:Adjust(base[1], base[2], base[3], role, band)
        T.Tone[name] = { r, g, b }
      else
        T.Tone[name] = { base[1], base[2], base[3] }
      end
    end
  end
  T.WashAlpha = zb and zb:AdjustAlpha(T.Base.WashAlpha, band) or T.Base.WashAlpha
  -- wash COLOUR flips with the band: a white lift over dark ground, a black backing over sand
  if zb and zb.WashColour then T.Tone.Wash = { zb:WashColour(band) } else T.Tone.Wash = { 1, 1, 1 } end
  -- on bright ground the 1 px shadow needs to be solid to hold the text off the sand
  T.ShadowAlpha = (band == "bright") and 1.0 or 0.9
  if NS.Panel and NS.Panel.Render then NS.Panel.Render() end
end

-- A wash texture re-reads the live colour AND alpha (called from the render paths that own washes).
function T.ApplyWash(tex, mul) T.SetColour(tex, T.Tone.Wash, T.WashAlpha * (mul or 1)) end

T.Retheme("normal")             -- fill T.Tone before any view is built; the lib re-themes on zone change

function T.SetColour(obj, c, alpha)
  if obj.SetTextColor then obj:SetTextColor(c[1], c[2], c[3], alpha or c[4] or 1)
  elseif obj.SetColorTexture then obj:SetColorTexture(c[1], c[2], c[3], alpha or c[4] or 1)
  elseif obj.SetVertexColor then obj:SetVertexColor(c[1], c[2], c[3], alpha or c[4] or 1) end
end

-- Difficulty colour for a quest level, from the client's own palette.
function T.DifficultyColour(level)
  local c = GetQuestDifficultyColor and GetQuestDifficultyColor(level or 1)
  if c then return { c.r, c.g, c.b } end
  return T.Tone.Near
end

-- Objective count text, per the "Show objectives as" setting (VQT_ObjectiveCountMode):
--   "remaining" (default) -> units still owed, e.g. "3"   (0 when done)
--   "completed"            -> done over total,   e.g. "1/4"
-- No-count objectives (need == 1) have nothing useful to count: remaining mode shows "" when done,
-- "1" when owed; completed mode shows the usual "0/1" / "1/1".
function T.CountText(have, need)
  local mode = NS.db and NS.db.settings and NS.db.settings.ObjectiveCountMode or "remaining"
  if mode == "completed" then return string.format("%d/%d", have, need) end
  local left = math.max(0, need - have)
  if need == 1 then return left > 0 and "1" or "" end
  return tostring(left)
end

-- Objective name with any leading Blizzard count prefix ("0/4 Grizzled Scalp") removed, so the
-- count can be re-attached in the chosen mode. Names that carry the count as a suffix are already
-- clean (ParseObjectiveText strips ": n/m").
function T.CountlessName(name)
  return (name or ""):gsub("^%d+%s*/%s*%d+%s+", "")
end

function T.Text(parent, size, tone, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  fs:SetFont(T.Font, size or T.RowSize, "")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, T.ShadowAlpha or 0.9)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  T.SetColour(fs, tone or T.Tone.Todo)
  return fs
end

function T.Texture(parent, tone, layer, alpha)
  local tx = parent:CreateTexture(nil, layer or "ARTWORK")
  T.SetColour(tx, tone or T.Tone.Todo, alpha)
  return tx
end

-- Marker shapes for source types (M1 line view uses index 1..n; M3 map view shares them).
-- Drawn with plain textures: square and diamond are a rotated square, circle/triangles use
-- Blizzard's small atlas-free textures where available, else fall back to a square.
T.Shapes = { "square", "circle", "triangle", "triangle_down", "diamond", "plus" }

function T.Shape(parent, kind, tone, size)
  size = size or T.ShapeSize
  local tx = parent:CreateTexture(nil, "ARTWORK")
  tx:SetSize(size, size)
  if kind == "circle" then
    tx:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    tx:SetVertexColor(tone[1], tone[2], tone[3], 1)
  elseif kind == "triangle" or kind == "triangle_down" then
    tx:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    tx:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    tx:SetRotation(kind == "triangle" and math.pi / 2 or -math.pi / 2)
    tx:SetVertexColor(tone[1], tone[2], tone[3], 1)
  elseif kind == "diamond" then
    tx:SetColorTexture(tone[1], tone[2], tone[3], 1)
    tx:SetRotation(math.pi / 4)
    tx:SetSize(size * 0.75, size * 0.75)
  elseif kind == "plus" then
    tx:SetColorTexture(tone[1], tone[2], tone[3], 1)
    tx:SetSize(size, size * 0.4)
    local v = parent:CreateTexture(nil, "ARTWORK")
    v:SetColorTexture(tone[1], tone[2], tone[3], 1)
    v:SetSize(size * 0.4, size)
    v:SetPoint("CENTER", tx, "CENTER")
    tx.extra = v
  else
    tx:SetColorTexture(tone[1], tone[2], tone[3], 1)
    tx:SetSize(size - 1, size - 1)
  end
  return tx
end

-- Row of difficulty squares: squares(parent, { {r,g,b}, ... }) -> frame sized to fit
function T.Squares(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(T.Square)
  f.cells = {}
  function f:Set(colours)
    for i, c in ipairs(colours) do
      local tx = self.cells[i]
      if not tx then
        tx = self:CreateTexture(nil, "ARTWORK"); tx:SetSize(T.Square, T.Square)
        tx:SetPoint("LEFT", (i - 1) * (T.Square + T.SquareGap), 0)
        self.cells[i] = tx
      end
      T.SetColour(tx, c); tx:Show()
    end
    for i = #colours + 1, #self.cells do self.cells[i]:Hide() end
    self:SetWidth(math.max(1, #colours * (T.Square + T.SquareGap) - T.SquareGap))
  end
  return f
end