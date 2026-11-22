-- Velocity Quest Tracker: shared helpers. Loads first.
local ADDON_NAME, NS = ...
NS.ADDON_NAME = ADDON_NAME

local Util = {}
NS.Util = Util

local PREFIX = "|cffffcf4dVQT|r: "

function Util.Print(fmt, ...)
  if select("#", ...) > 0 then fmt = string.format(fmt, ...) end
  print(PREFIX .. tostring(fmt))
end

-- Banner above every diagnostic dump so the start of a paste is unmistakable:
--   ====== /vqt dump ======
function Util.DumpHeader(title)
  print("|cffffcf4d====== " .. tostring(title) .. " ======|r")
end
function Util.DumpFooter(title) print("|cffffcf4d====== end " .. tostring(title) .. " ======|r") end

local warned = {}
function Util.WarnOnce(key, msg)
  if warned[key] then return end
  warned[key] = true
  Util.Print("|cffff4040warning|r " .. tostring(msg))
end

-- Report a caught error as a REAL Lua error, without unwinding the caller. Routes through the
-- client's error handler, which is what BugGrabber / BugSack / the Blizzard error frame hook -- a
-- chat line is not noticed, an exception is (owner 2026-11-21). Use after every pcall whose failure
-- must not be swallowed; the caller then carries on with its own fallback.
function Util.Raise(context, err)
  local msg = string.format("VelocityQuestTracker: %s: %s", tostring(context), tostring(err))
  local handler = geterrorhandler and geterrorhandler()
  if handler then handler(msg) else error(msg, 0) end
end

-- "#rrggbb" -> r, g, b in 0..1
function Util.HexToRGB(hex)
  hex = hex:gsub("#", "")
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- Linear blend of two {r,g,b} at t in 0..1.
function Util.Lerp3(a, b, t)
  return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

function Util.Clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- Shallow copy of defaults into a table, only where missing.
function Util.ApplyDefaults(dst, defaults)
  for k, v in pairs(defaults) do
    if dst[k] == nil then
      if type(v) == "table" then
        local c = {}
        for kk, vv in pairs(v) do c[kk] = vv end
        dst[k] = c
      else
        dst[k] = v
      end
    end
  end
  return dst
end

-- Coalesce many calls in one frame into one callback on the next frame.
function Util.NextFrameOnce(state, key, fn)
  if state[key] then return end
  state[key] = true
  C_Timer.After(0, function() state[key] = nil; fn() end)
end

function Util.ClientInfo()
  local version, build, _, interface = GetBuildInfo()
  return { Version = version, Build = build, Interface = interface, Project = WOW_PROJECT_ID }
end