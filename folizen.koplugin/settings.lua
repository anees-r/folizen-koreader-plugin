--[[
Thin wrapper around KOReader's LuaSettings for everything the Folizen
plugin needs to remember between sessions: server URL, the long-lived
refresh token issued at login, the signed-in username (display only),
and a local cache of the sync preferences that live server-side in
plugin_sessions (section 5.2 / requirements.md).
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local FolizenSettings = {}

local settings_file = DataStorage:getSettingsDir() .. "/folizen.lua"
local store = LuaSettings:open(settings_file)

local DEFAULTS = {
    server_url = "https://folizen.vercel.app",
    refresh_token = nil,
    username = nil,
    auto_sync_enabled = true,
    sync_threshold_pages = 5,
    wifi_auto_enable = false,
    history_synced_once = false,
}

function FolizenSettings.get(key)
    local value = store:readSetting(key)
    if value == nil then
        return DEFAULTS[key]
    end
    return value
end

function FolizenSettings.set(key, value)
    store:saveSetting(key, value)
    store:flush()
end

function FolizenSettings.isLoggedIn()
    return FolizenSettings.get("refresh_token") ~= nil
end

-- Clears the token plus every locally cached sync preference (they revert
-- to DEFAULTS via FolizenSettings.get until a fresh login re-fetches the
-- server's actual values) — section 5.2's "clears the stored token and any
-- locally cached sync state". Per-book links live in each book's own
-- sidecar, not here — see BookIdentity.clearAllLocalLinks.
function FolizenSettings.clearSession()
    store:saveSetting("refresh_token", nil)
    store:saveSetting("username", nil)
    store:saveSetting("auto_sync_enabled", nil)
    store:saveSetting("sync_threshold_pages", nil)
    store:saveSetting("wifi_auto_enable", nil)
    store:saveSetting("history_synced_once", nil)
    store:saveSetting("sync_pending", nil)
    store:flush()
end

-- Applies a {autoSyncEnabled=, syncThresholdPages=, wifiAutoEnable=} table
-- (as returned by GET/PATCH /api/plugin/settings) to local storage.
function FolizenSettings.applyServerPrefs(prefs)
    if prefs == nil then return end
    if prefs.autoSyncEnabled ~= nil then
        FolizenSettings.set("auto_sync_enabled", prefs.autoSyncEnabled)
    end
    if prefs.syncThresholdPages ~= nil then
        FolizenSettings.set("sync_threshold_pages", prefs.syncThresholdPages)
    end
    if prefs.wifiAutoEnable ~= nil then
        FolizenSettings.set("wifi_auto_enable", prefs.wifiAutoEnable)
    end
end

return FolizenSettings
