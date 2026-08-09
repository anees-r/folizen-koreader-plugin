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

local Downloads = {}

local function guess_filename(title)
    local safe = title:gsub("[^%w%s%-%_]", ""):gsub("%s+", "_")
    return (safe ~= "" and safe or "book") .. ".epub"
end

local function download_to(url, dest_path, on_done)
    local client = url:match("^https") and https or http
    socketutil:set_timeout(15, 60)
    local ok, status = client.request({
        url = url,
        method = "GET",
        sink = ltn12.sink.file(io.open(dest_path, "wb")),
    })
    socketutil:reset_timeout()
    on_done(ok and status and status >= 200 and status < 300, status)
end

function Downloads.show()
    Net.withConnection(function()
        local ok, body = Api.getQueue()
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Folizen: couldn't load your download queue.") })
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
                    PathChooser:new{
                        title = _("Choose a folder to save into"),
                        path = Device.home_dir or "/",
                        onConfirm = function(folder)
                            local dest = folder .. "/" .. guess_filename(item.title)
                            local info = InfoMessage:new{ text = _("Downloading…") }
                            UIManager:show(info)
                            download_to(item.externalLink, dest, function(success, status)
                                UIManager:close(info)
                                if success then
                                    Api.completeQueueItem(item.bookId)
                                    UIManager:show(InfoMessage:new{ text = _("Downloaded to ") .. dest })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = _("Download failed (") .. tostring(status) .. _("). The book stays queued — try again later."),
                                    })
                                end
                            end)
                        end,
                    }:chooseDir()
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
