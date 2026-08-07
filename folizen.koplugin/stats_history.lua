--[[
statistics.koplugin (if installed/enabled) keeps a sqlite3 database at
<settings dir>/statistics.sqlite3 with a page_stat_data table logging
every single page-turn: (id_book, page, start_time, duration, total_pages).
Schema verified directly from statistics.koplugin/main.lua, not guessed.

We aggregate this into one row per calendar day (total pages "turned",
total seconds spent) rather than shipping the raw per-page log — smaller
payload, and Folizen's calendar only needs day-level granularity anyway.

The `+ 10800` (3 hours) offset when bucketing by day matches exactly what
statistics.koplugin's own calendar view does (calendarview.lua) when
deciding which calendar day a reading session belongs to, so Folizen's
calendar agrees with the one you already see on-device.

If statistics.koplugin isn't installed, this returns an empty list —
never treated as an error, since it's an optional companion plugin.
]]

local DataStorage = require("datastorage")
local logger = require("logger")

local StatsHistory = {}

local function open_db()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        logger.warn("Folizen: lua-ljsqlite3 unavailable, skipping reading-history import")
        return nil
    end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local fh = io.open(path, "rb")
    if not fh then return nil end -- statistics.koplugin never installed/used
    fh:close()
    local open_ok, conn = pcall(SQ3.open, path)
    if not open_ok then return nil end
    return conn
end

-- Returns { {date="YYYY-MM-DD", pagesRead=N, durationSeconds=N}, ... }
-- covering every day KOReader has ever logged reading activity for.
function StatsHistory.dailyTotals()
    local conn = open_db()
    if not conn then return {} end

    local days = {}
    local ok, stmt = pcall(function()
        return conn:prepare([[
            SELECT strftime('%Y-%m-%d', start_time + 10800, 'unixepoch') AS day,
                   SUM(duration) AS duration_seconds,
                   COUNT(*) AS pages_read
            FROM page_stat_data
            GROUP BY day
            ORDER BY day
        ]])
    end)

    if ok and stmt then
        local rows_ok, rows = pcall(function() return stmt:resultset() end)
        if rows_ok and rows and rows.day then
            for i = 1, #rows.day do
                table.insert(days, {
                    date = rows.day[i],
                    durationSeconds = tonumber(rows.duration_seconds[i]) or 0,
                    pagesRead = tonumber(rows.pages_read[i]) or 0,
                })
            end
        end
        pcall(function() stmt:close() end)
    end

    pcall(function() conn:close() end)
    return days
end

return StatsHistory
