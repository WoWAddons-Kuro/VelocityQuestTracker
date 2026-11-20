-- LibZoneBrightness-1.0: how bright is the terrain the player is standing on?
--
-- A small curated table, keyed by UiMapID, of three bands -- "bright" (sand, snow, pale rock),
-- "normal", "dark" (forest canopy, swamp, plaguelands). Addons that draw faint washes and grey text
-- over the world ask for the band and adjust their own palettes; the library knows terrain, not
-- colours. Spec: AddonManagement\SPECS\LibZoneBrightness.md.
--
-- API
--   local ZB = LibStub("LibZoneBrightness-1.0")
--   ZB:GetBand(uiMapID?)             -> LibZoneBrightness_Band   ("bright" | "normal" | "dark"; default = player's map)
--   ZB:Adjust(r, g, b, role, band?)  -> r, g, b                  role: "text" | "dim"
--   ZB:AdjustAlpha(alpha, band?)     -> alpha                    role "wash" (background backing alpha)
--   ZB:WashColour(band?)             -> r, g, b                  wash colour: black on bright ground, white elsewhere
--   ZB:RegisterCallback(fn)          fn(band, uiMapID) when the band changes (zone change / entering world)
--   ZB:SetOverride(uiMapID, band|nil) per-character override, saved in LibZoneBrightnessDB; also /zonebright
--
-- Era and Forever share Classic UiMapIDs (1411..1458), so one table serves both.
local MAJOR, MINOR = "LibZoneBrightness-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Seed table (v1). Unlisted = "normal". Tune with /zonebright and fold overrides back here.
lib.Table = lib.Table or {
  -- bright: sand, snow, pale rock, open coast
  [1436] = "bright",  -- Westfall
  [1413] = "bright",  -- The Barrens
  [1446] = "bright",  -- Tanaris
  [1418] = "bright",  -- Badlands
  [1426] = "bright",  -- Dun Morogh
  [1452] = "bright",  -- Winterspring
  [1447] = "bright",  -- Azshara
  [1451] = "bright",  -- Silithus
  [1416] = "bright",  -- Alterac Mountains
  [1417] = "bright",  -- Arathi Highlands
  [1443] = "bright",  -- Desolace
  -- dark: forest canopy, swamp, plaguelands, night-elf lands
  [1431] = "dark",    -- Duskwood
  [1420] = "dark",    -- Tirisfal Glades
  [1421] = "dark",    -- Silverpine Forest
  [1435] = "dark",    -- Swamp of Sorrows
  [1425] = "dark",    -- The Hinterlands
  [1422] = "dark",    -- Western Plaguelands
  [1423] = "dark",    -- Eastern Plaguelands
  [1438] = "dark",    -- Teldrassil
  [1439] = "dark",    -- Darkshore
  [1440] = "dark",    -- Ashenvale
  [1448] = "dark",    -- Felwood
  [1450] = "dark",    -- Moonglade
  [1434] = "dark",    -- Stranglethorn Vale
  [1437] = "dark",    -- Wetlands
  [1445] = "dark",    -- Dustwallow Marsh
  [1428] = "dark",    -- Burning Steppes
  [1427] = "dark",    -- Searing Gorge
  [1430] = "dark",    -- Deadwind Pass
}

-- Adjustment constants (spec "Adjustment table"). Luminance scale = multiply r,g,b, clamp 0..1.
--   text / dim : foreground tones. On bright ground BOTH go UP -- the dim tones are the ones that vanish
--                first on sand (owner 2026-11-20: "brighten up all the dim text"), so dim lifts harder
--                than text, which is already near white.
--   wash       : a translucent backing behind blocks. On bright ground the backing must be BLACK, not a
--                brighter white: a white wash on sand lightens the sand. `washColour` is what the
--                consumer should paint the wash with; the default (normal) is white at a faint alpha.
--                AdjustAlpha = alpha * washMul + washAdd. bright uses washMul 0 so the result is the
--                ABSOLUTE 0.30 the owner asked for (#000000 at 30 % alpha), not "base + 0.30".
lib.Factors = lib.Factors or {
  bright = { text = 1.06, dim = 1.45, washAdd = 0.30, washMul = 0.0, washColour = { 0, 0, 0 } },
  normal = { text = 1.00, dim = 1.00, washAdd = 0.00, washMul = 1.0, washColour = { 1, 1, 1 } },
  dark   = { text = 1.00, dim = 1.10, washAdd = 0.00, washMul = 1.5, washColour = { 1, 1, 1 } },
}

lib.callbacks = lib.callbacks or {}
lib.lastBand = lib.lastBand or nil
lib.lastMap = lib.lastMap or nil

local function Overrides()
  LibZoneBrightnessDB = LibZoneBrightnessDB or {}
  LibZoneBrightnessDB.override = LibZoneBrightnessDB.override or {}
  return LibZoneBrightnessDB.override
end

local function PlayerMap()
  return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
end

-- Walk up parentMapID until a listed map (override or table) is found; nil if none.
local function Lookup(uiMapID)
  local seen = 0
  local ov = Overrides()
  while uiMapID and uiMapID > 0 and seen < 8 do
    local b = ov[uiMapID] or lib.Table[uiMapID]
    if b then return b end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(uiMapID)
    uiMapID = info and info.parentMapID or nil
    seen = seen + 1
  end
  return nil
end

function lib:GetBand(uiMapID)
  uiMapID = uiMapID or PlayerMap()
  return Lookup(uiMapID) or "normal"
end

local function Clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

function lib:Adjust(r, g, b, role, band)
  local f = lib.Factors[band or self:GetBand()] or lib.Factors.normal
  local k = (role == "dim") and f.dim or f.text
  return Clamp01(r * k), Clamp01(g * k), Clamp01(b * k)
end

function lib:AdjustAlpha(alpha, band)
  local f = lib.Factors[band or self:GetBand()] or lib.Factors.normal
  return Clamp01(alpha * f.washMul + f.washAdd)
end

-- The colour a background wash should be painted in for this band: black on bright ground (a backing),
-- white elsewhere (a lift). Returns r, g, b.
function lib:WashColour(band)
  local f = lib.Factors[band or self:GetBand()] or lib.Factors.normal
  local c = f.washColour or { 1, 1, 1 }
  return c[1], c[2], c[3]
end
function lib:RegisterCallback(fn)
  for _, g in ipairs(self.callbacks) do if g == fn then return end end
  self.callbacks[#self.callbacks + 1] = fn
end

local function Fire()
  local map = PlayerMap()
  local band = lib:GetBand(map)
  if band == lib.lastBand and map == lib.lastMap then return end
  lib.lastBand, lib.lastMap = band, map
  for _, fn in ipairs(lib.callbacks) do pcall(fn, band, map) end
end

function lib:SetOverride(uiMapID, band)
  if band ~= nil and band ~= "bright" and band ~= "normal" and band ~= "dark" then return false end
  Overrides()[uiMapID] = band
  lib.lastBand = nil     -- force the next Fire to notify
  Fire()
  return true
end

-- Events: one frame per library instance (upgrade-safe via the minor check above).
if not lib.frame then
  lib.frame = CreateFrame("Frame")
  lib.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  lib.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  lib.frame:RegisterEvent("ZONE_CHANGED")
  lib.frame:SetScript("OnEvent", function() C_Timer.After(0.2, Fire) end)   -- map id settles a tick after the event
end

-- /zonebright [bright|normal|dark|clear]  (owner tuning; the result feeds the next table revision)
if not lib.slashInstalled then
  lib.slashInstalled = true
  SLASH_LIBZONEBRIGHTNESS1 = "/zonebright"
  SlashCmdList.LIBZONEBRIGHTNESS = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    local map = PlayerMap()
    local name = map and C_Map.GetMapInfo and C_Map.GetMapInfo(map) and C_Map.GetMapInfo(map).name or "?"
    if msg == "clear" then lib:SetOverride(map, nil)
    elseif msg == "bright" or msg == "normal" or msg == "dark" then lib:SetOverride(map, msg) end
    local ov = Overrides()[map]
    print(string.format("|cffffcf4dZoneBrightness|r: %s (map %s) = %s%s", name, tostring(map), lib:GetBand(map), ov and " [override]" or (lib.Table[map] and "" or " [default]")))
  end
end