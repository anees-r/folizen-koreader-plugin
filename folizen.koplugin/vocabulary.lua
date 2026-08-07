--[[
KOReader's built-in "Vocabulary Builder" plugin (vocabbuilder.koplugin)
keeps its own sqlite3 database of words the reader has looked up, at
<settings dir>/vocabulary_builder.sqlite3.

Verified schema (read directly from vocabbuilder.koplugin/db.lua, not
guessed):

    CREATE TABLE vocabulary (
        word          TEXT PRIMARY KEY,
        title_id      INTEGER,   -- FK -> title.id
        create_time   INTEGER,
        review_time   INTEGER,
        due_time      INTEGER,
        review_count  INTEGER,
        prev_context  TEXT,
        next_context  TEXT,
        streak_count  INTEGER,
        highlight     TEXT
    );
    CREATE TABLE title (
        id     INTEGER PRIMARY KEY,
        name   TEXT UNIQUE,
        filter INTEGER
    );

There is no `book_title` column on `vocabulary` — it references `title`
by id. An earlier version of this file guessed at a `book_title` column
that doesn't exist, which silently made vocabulary sync a no-op; this
version is written directly against the real schema above.

Definitions and pronunciation are NOT resolved here — per
requirements.md section 4.13, that lookup happens server-side, lazily,
the first time a word is displayed in the Folizen web app's Vocabulary
view. The plugin only ever ships the bare word list up.
]]

local DataStorage = require("datastorage")
local logger = require("logger")

local Vocabulary = {}

local function open_db()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        logger.warn("Folizen: lua-ljsqlite3 unavailable, skipping vocabulary sync")
        return nil
    end
    local path = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
    local open_ok, conn = pcall(SQ3.open, path)
    if not open_ok then return nil end
    return conn
end

-- Returns a de-duplicated list of words looked up while reading the book
-- currently titled `book_title` (matched against vocabbuilder's own
-- `title` table — it doesn't know about our bookId, only titles).
function Vocabulary.wordsForBook(book_title)
    if not book_title or book_title == "" then return {} end
    local conn = open_db()
    if not conn then return {} end

    local words = {}
    local ok, stmt = pcall(function()
        return conn:prepare([[
            SELECT v.word FROM vocabulary v
            INNER JOIN title t ON t.id = v.title_id
            WHERE t.name = ?
        ]])
    end)

    if ok and stmt then
        local rows_ok, rows = pcall(function()
            stmt:bind(1, book_title)
            return stmt:resultset()
        end)
        if rows_ok and rows and rows[1] then
            for _, w in ipairs(rows[1]) do
                table.insert(words, w)
            end
        end
        pcall(function() stmt:close() end)
    end

    pcall(function() conn:close() end)
    return words
end

-- Historical/bulk import: every word ever looked up, grouped by the book
-- title vocabbuilder recorded it under. Returns:
--   { { title = "...", words = {"word1","word2",...} }, ... }
-- Used once at first login (and via the manual "Sync reading history"
-- menu action) to backfill vocabulary from books read before this device
-- ever talked to Folizen.
function Vocabulary.allWordsByTitle()
    local conn = open_db()
    if not conn then return {} end

    local groups = {}
    local order = {}
    local ok, stmt = pcall(function()
        return conn:prepare([[
            SELECT t.name AS title, v.word AS word
            FROM vocabulary v
            LEFT JOIN title t ON t.id = v.title_id
            WHERE t.name IS NOT NULL
            ORDER BY t.name
        ]])
    end)

    if ok and stmt then
        local rows_ok, rows = pcall(function() return stmt:resultset() end)
        if rows_ok and rows and rows.title then
            for i = 1, #rows.title do
                local title = rows.title[i]
                local word = rows.word[i]
                if not groups[title] then
                    groups[title] = {}
                    table.insert(order, title)
                end
                table.insert(groups[title], word)
            end
        end
        pcall(function() stmt:close() end)
    end

    pcall(function() conn:close() end)

    local result = {}
    for _, title in ipairs(order) do
        table.insert(result, { title = title, words = groups[title] })
    end
    return result
end

return Vocabulary
