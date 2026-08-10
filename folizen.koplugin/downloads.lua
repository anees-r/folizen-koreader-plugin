local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Device = require("device")
local _ = require("gettext")

local Api = require("api")
local Net = require("network")
local FolizenSettings = require("settings")

local Downloads = {}

local function guess_filename(title)
    local safe = title:gsub("[^%w%s%-%_]", ""):gsub("%s+", "_")
    return (safe ~= "" and safe or "book") .. ".epub"
end

local function download_to(url, dest_path, on_progress, on_done)
    local client = url:match("^https") and https or http
    local file, open_err = io.open(dest_path, "wb")
    if not file then
        on_done(false, "couldn't open destination file: " .. tostring(open_err))
        return
    end

    local received = 0
    local last_reported = 0
    local REPORT_EVERY_BYTES = 200 * 1024 -- ~200 KB, avoids flooding the UI with updates

    local sink = function(chunk, err)
        if err then return nil, err end
        if chunk == nil then return true end -- ltn12 end-of-stream marker
        file:write(chunk)
        received = received + #chunk
        if on_progress and (received - last_reported) >= REPORT_EVERY_BYTES then
            last_reported = received
            on_progress(received)
        end
        return true
    end

    socketutil:set_timeout(15, 120) -- generous block timeout; a few MB over a slow connection can take a while
    local ok, status = client.request({
        url = url,
        method = "GET",
        sink = sink,
    })
    socketutil:reset_timeout()
    file:close()
    on_done(ok and status and status >= 200 and status < 300, status, received)
end

function Downloads.show()
    Net.withConnection(function()
        local ok, body = Api.getQueue()
        if not ok then
            if not FolizenSettings.isLoggedIn() then
                UIManager:show(InfoMessage:new{ text = _("Your Folizen session ended — please sign in again from the Folizen menu.") })
            else
                UIManager:show(InfoMessage:new{ text = _("Folizen: couldn't load your download queue.") })
            end
            return
        end

        local queue = (body and body.queue) or {}
        if #queue == 0 then
            UIManager:show(InfoMessage:new{ text = _("Nothing queued from the web app right now.") })
            return
        end

        local menu
        local items = {}
        for _idx, item in ipairs(queue) do
            table.insert(items, {
                text = item.title .. " — " .. item.author,
                callback = function()
                    UIManager:close(menu)
                    if not item.externalLink or item.externalLink == "" then
                        UIManager:show(InfoMessage:new{ text = _("No download link set for this book yet — add one on the web app.") })
                        return
                    end
                    UIManager:show(PathChooser:new{
                        title = _("Choose a folder to save into"),
                        path = Device.home_dir or "/",
                        onConfirm = function(folder)
                            local dest = folder .. "/" .. guess_filename(item.title)
                            local info = InfoMessage:new{ text = _("Downloading \"") .. item.title .. _("\"…") }
                            UIManager:show(info)

                            local function update_progress(received_bytes)
                                UIManager:close(info)
                                local kb = math.floor(received_bytes / 1024)
                                info = InfoMessage:new{
                                    text = _("Downloading \"") .. item.title .. _("\"… ") .. kb .. _(" KB so far"),
                                }
                                UIManager:show(info)
                                -- KOReader's HTTP call blocks the event loop, so without
                                -- forcing a repaint here these updates may only actually
                                -- become visible once the whole download finishes, on
                                -- some KOReader versions/devices.
                                pcall(function() UIManager:forceRePaint() end)
                            end

                            download_to(item.externalLink, dest, update_progress, function(success, status, received_bytes)
                                UIManager:close(info)
                                if success then
                                    Api.completeQueueItem(item.bookId)
                                    local kb = received_bytes and math.floor(received_bytes / 1024) or nil
                                    UIManager:show(InfoMessage:new{
                                        text = _("Downloaded to ") .. dest .. (kb and (" (" .. kb .. " KB)") or ""),
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = _("Download failed (") .. tostring(status) .. _("). The book stays queued — try again later."),
                                    })
                                end
                            end)
                        end,
                    })
                end,
            })
        end

        menu = Menu:new{
            title = _("Queued from Folizen"),
            item_table = items,
            width = Device.screen:getWidth() * 0.8,
        }
        UIManager:show(menu)
    end)
end

return Downloads
