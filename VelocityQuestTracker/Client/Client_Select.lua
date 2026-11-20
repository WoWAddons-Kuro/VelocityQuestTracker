-- Velocity Quest Tracker: picks the client flavour and binds it onto NS.Client.
-- Warns on any INTERFACE method a flavour lacks, and on any flavour method not in INTERFACE.
local ADDON_NAME, NS = ...
local Client, Util = NS.Client, NS.Util

local function SelectFlavour()
  if WOW_PROJECT_ID ~= nil and WOW_PROJECT_CLASSIC ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then
    return "classic_era"
  end
  return "forever"
end

Client.flavour = SelectFlavour()
local impl = NS.ClientFlavours[Client.flavour]
if not impl then
  Util.WarnOnce("client", "no client implementation for flavour " .. tostring(Client.flavour))
  impl = {}
end

for _, name in ipairs(Client.INTERFACE) do
  if type(impl[name]) == "function" then
    Client[name] = impl[name]
  else
    Util.WarnOnce("client:" .. name, Client.flavour .. " client is missing " .. name)
    Client[name] = function() return nil end
  end
end

for flavour, t in pairs(NS.ClientFlavours) do
  for name in pairs(t) do
    local listed = false
    for _, n in ipairs(Client.INTERFACE) do if n == name then listed = true break end end
    if not listed then Util.WarnOnce("client-extra:" .. flavour .. ":" .. name, flavour .. " client defines " .. name .. " which is not in Client.INTERFACE") end
  end
end