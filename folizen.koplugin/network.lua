local NetworkMgr = require("ui/network/manager")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local FolizenSettings = require("settings")

local Net = {}

-- Runs `on_connected()` once online. If Wi-Fi is off:
--   - if the reader has opted into wifi_auto_enable, turns it on silently
--   - otherwise asks first, and does nothing if they decline
function Net.withConnection(on_connected)
    if NetworkMgr:isConnected() then
        on_connected()
        return
    end

    if FolizenSettings.get("wifi_auto_enable") then
        NetworkMgr:turnOnWifiAndWaitForConnection(on_connected)
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Folizen wants to sync. Turn on Wi-Fi now?"),
        ok_text = _("Turn on Wi-Fi"),
        ok_callback = function()
            NetworkMgr:turnOnWifiAndWaitForConnection(on_connected)
        end,
    })
end

return Net
