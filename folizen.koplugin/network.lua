local NetworkMgr = require("ui/network/manager")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local FolizenSettings = require("settings")

local Net = {}

-- Runs `on_connected()` once online.
--   - Already connected: runs immediately.
--   - Wi-Fi off, but the reader opted into wifi_auto_enable: turns it on
--     silently and runs once connected.
--   - Wi-Fi off, opts.manual (a deliberate reader action, e.g. "Sync this
--     book now"): asks first, per section 5.3 — declining calls
--     opts.on_declined if given, and nothing else happens.
--   - Wi-Fi off, automatic trigger (not opts.manual): the caller queues
--     the work itself instead of interrupting the reader (section 5.3);
--     this returns false so it can.
-- Returns true if a connection attempt was started (immediately, silently,
-- or pending the reader's answer to the prompt); false if nothing was
-- attempted at all.
function Net.withConnection(on_connected, opts)
    opts = opts or {}
    if NetworkMgr:isConnected() then
        on_connected()
        return true
    end

    if FolizenSettings.get("wifi_auto_enable") then
        NetworkMgr:turnOnWifiAndWaitForConnection(on_connected)
        return true
    end

    if not opts.manual then
        return false
    end

    UIManager:show(ConfirmBox:new{
        text = _("Folizen wants to sync. Turn on Wi-Fi now?"),
        ok_text = _("Turn on Wi-Fi"),
        ok_callback = function()
            NetworkMgr:turnOnWifiAndWaitForConnection(on_connected)
        end,
        cancel_callback = function()
            if opts.on_declined then opts.on_declined() end
        end,
    })
    return true
end

return Net
