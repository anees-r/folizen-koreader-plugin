--[[
statistics.koplugin (if installed/enabled) keeps a sqlite3 database at
<settings dir>/statistics.sqlite3 with:
  - page_stat_data(id_book, page, start_time, duration, total_pages)
  - book(id, title, authors, ..., md5, total_read_time, total_read_pages)
Schema verified directly from statistics.koplugin/main.lua, not guessed.

We aggregate this into one row per calendar day (total pages "turned",
total seconds spent) for the streak calendar, PLUS a per-book breakdown
of that same day (each book's own title/duration/pages) so Folizen can
attribute reading time to the right book instead of crediting every book
read that day with the day's full total. The per-book breakdown comes
straight out of the SQL GROUP BY below — nothing is collapsed away.

The `+ 10800` (3 hours) offset when bucketing by day matches exactly what
statistics.koplugin's own calendar view does (calendarview.lua) when
deciding which calendar day a reading session belongs to, so Folizen's
calendar agrees with the one you already see on-device.

IMPORTANT: prepared-statement resultset() returns a COLUMN-MAJOR table
indexed positionally by column number — result[1] is an array of every
row's value for the first selected column, result[2] for the second, and
so on (verified against this plugin's own working vocabulary query, not
guessed) — NOT a table keyed by column name. An earlier version of this
file used name-keyed access (result.day, result.pages_read), which
silently returned nothing every time.

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

-- Returns { {date="YYYY-MM-DD", pagesRead=N, durationSeconds=N,
--            books={ {title=, durationSeconds=, pagesRead=}, ... }}, ... }
-- covering every day KOReader has ever logged reading activity for. Each
-- `books` entry is that one book's own share of the day — they sum to the
-- day-level pagesRead/durationSeconds, they don't duplicate it.
function StatsHistory.dailyTotals()
    local conn = open_db()
    if not conn then return {} end

    local by_day = {}
    local order = {}

    local ok, stmt = pcall(function()
        return conn:prepare([[
            SELECT strftime('%Y-%m-%d', p.start_time + 10800, 'unixepoch') AS day,
                   b.title AS title,
                   SUM(p.duration) AS duration_seconds,
                   COUNT(*) AS pages_read
            FROM page_stat_data p
            LEFT JOIN book b ON b.id = p.id_book
            GROUP BY day, p.id_book
            ORDER BY day
        ]])
    end)

    if ok and stmt then
        local rows_ok, rows = pcall(function() return stmt:resultset() end)
        -- rows[1] = day values, rows[2] = title values, rows[3] = duration,
        -- rows[4] = pages_read — one entry per (day, book) group, already
        -- the per-book breakdown we want (no further collapsing needed).
        if rows_ok and rows and rows[1] then
            for i = 1, #rows[1] do
                local day = rows[1][i]
                local title = rows[2] and rows[2][i]
                local duration = tonumber(rows[3] and rows[3][i]) or 0
                local pages = tonumber(rows[4] and rows[4][i]) or 0

                if day then
                    if not by_day[day] then
                        by_day[day] = { date = day, pagesRead = 0, durationSeconds = 0, books = {} }
                        table.insert(order, day)
                    end
                    local entry = by_day[day]
                    entry.pagesRead = entry.pagesRead + pages
                    entry.durationSeconds = entry.durationSeconds + duration
                    if title and title ~= "" then
                        table.insert(entry.books, { title = title, durationSeconds = duration, pagesRead = pages })
                    end
                end
            end
        end
        pcall(function() stmt:close() end)
    end

    pcall(function() conn:close() end)

    local days = {}
    for _, day in ipairs(order) do
        table.insert(days, by_day[day])
    end
    return days
end

return StatsHistory
