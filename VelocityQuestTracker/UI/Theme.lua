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
T.SegPerRow  = 10      -- segments per segment row; more units wrap to further rows
T.BarWidth   = 56
T.CountWidth = 28
T.ColGap     = 8
T.Square     = 5       -- difficulty squares on the place lines
T.SquareGap  = 3
T.SparkWidth = 60      -- line view
T.SparkMark  = 4
T.ShapeSize  = 7

-- Tones: {r,g,b} 0..1
local function Tone(hex) return { Util.HexToRGB(hex) } end
T.Tone = {
  Todo   = Tone("#f2f2ea"),   -- bright: still to do
  Near   = Tone("#aab1aa"),   -- middle: nearby work not started
  Done   = Tone("#566058"),   -- dim: done units
  Label  = Tone("#8d958e"),   -- dim: labels, place names, quest titles
  Recent = Tone("#ffcf4d"),   -- yellow: just happened (check glyph, outlines, text)
  RecentSeg = Tone("#a08a38"),-- yellow at done-cell brightness: the held segment itself, so it reads as a tinted done cell
  PopA   = Tone("#ffffff"),
  PopB   = Tone("#ffe89a"),
  Wash   = { 1, 1, 1 },       -- block wash colour; alpha below
}
T.WashAlpha = 0.06

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

function T.Text(parent, size, tone, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  fs:SetFont(T.Font, size or T.RowSize, "")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.9)
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