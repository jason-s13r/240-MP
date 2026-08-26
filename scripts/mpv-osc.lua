local assdraw = require 'mp.assdraw'
local mp_utils = require 'mp.utils'

-- Optional map of external sub-file URL -> friendly track name, written by the app
-- so the OSC can show a real subtitle name instead of mpv's URL-derived title
-- (Jellyfin sidecars are served as "Stream.srt?api_key=..."). Absent for most plays.
local subinfo = {}
do
    local path = mp.get_opt("subinfo-file")
    if path then
        local f = io.open(path, "r")
        if f then
            local parsed = mp_utils.parse_json(f:read("*a") or "")
            f:close()
            if type(parsed) == "table" then subinfo = parsed end
        end
    end
end

-- What is playing, written by the app before launch (MpvController::setNowPlaying).
-- A file rather than a script-opt for the same reason subinfo is one: script-opts
-- is a single comma-separated list, and a title is exactly the kind of string that
-- has a comma in it.
local nowplaying = {}
do
    local path = mp.get_opt("nowplaying-file")
    if path then
        local f = io.open(path, "r")
        if f then
            local parsed = mp_utils.parse_json(f:read("*a") or "")
            f:close()
            if type(parsed) == "table" then nowplaying = parsed end
        end
    end
end

-- Cover art for the title block. mpv draws it through overlay-add, which takes
-- raw premultiplied BGRA at exactly the size it will appear — so the app cannot
-- prepare it until this script says how big the window is. Asked for once, the
-- first time the menu is drawn; the answer arrives as a script-message and the
-- menu is redrawing twice a second anyway, so it simply appears a moment later.
local POSTER_OVERLAY_ID = 0
local poster = nil        -- { file, w, h, stride } once the app has answered
local poster_asked = false
local poster_shown = false

-- overlay-add draws over the video whether or not the menu is up, so it has to
-- come down with it — including when the auto-hide timer, not a keypress, is
-- what closed the menu.
local function hide_poster()
    if poster_shown then
        mp.commandv("overlay-remove", POSTER_OVERLAY_ID)
        poster_shown = false
    end
end

local menu_visible = false
local focus_row = 0  -- 0: Seek Bar, 1: Buttons
local focus_btn = 1  -- index into visible left buttons + STOP; varies with track availability
local update_timer = nil
local idle_timer = nil
local skip_active = false

local SEEK_SECONDS = 10
local MENU_TIMEOUT = 5

-- Colors (ABGR format for ASS)
local C_WHITE = "&HFFFFFF&"
local C_BLACK = "&H000000&"
local A_OPAQUE = "&H00&"
local A_TRANS  = "&HFF&"
local A_DIM    = "&H99&"  -- 40% opacity for unfocused seek fill
local A_SCRIM  = "&HB4&"  -- ~30% black over the video while the menu is up

local function get_audio_str()
    -- Transcoded stream: read track info passed explicitly from QML
    local transcode_audio = mp.get_opt("transcode-audio")
    if transcode_audio and transcode_audio ~= "" then
        if transcode_audio == "Off" then return "(NONE)" end
        return (transcode_audio:gsub("_", " ")):upper()
    end

    local id = mp.get_property_number("current-tracks/audio/id", 0)
    if id == 0 then return "(NONE)" end
    local title    = (mp.get_property("current-tracks/audio/title", "") or ""):upper()
    local lang     = (mp.get_property("current-tracks/audio/lang",  "") or ""):upper()
    local codec    = (mp.get_property("current-tracks/audio/codec", "") or ""):upper()
    local channels = mp.get_property_number("current-tracks/audio/audio-channels", 0)
    local rate     = mp.get_property_number("current-tracks/audio/demux-samplerate", 0)
    local parts = {}
    if title    ~= "" then parts[#parts+1] = title end
    if lang     ~= "" then parts[#parts+1] = lang  end
    if codec    ~= "" then parts[#parts+1] = codec end
    if channels  > 0  then parts[#parts+1] = channels .. "CH" end
    if rate      > 0  then parts[#parts+1] = rate .. " HZ" end
    return table.concat(parts, " ")
end

local function get_sub_str()
    -- Burned-in transcode sub: there is no mpv track to read, so the app passes
    -- the selected track's name (spaces as underscores) for display.
    local transcode_sub = mp.get_opt("transcode-sub")
    if transcode_sub and transcode_sub ~= "" then
        if transcode_sub == "Off" then return "(NONE)" end
        return (transcode_sub:gsub("_", " ")):upper()
    end

    local id = mp.get_property_number("current-tracks/sub/id", 0)
    if id == 0 then return "(NONE)" end
    -- External sidecar with an app-provided friendly name (e.g. Jellyfin): use it
    -- instead of mpv's URL-derived title.
    local ext = mp.get_property("current-tracks/sub/external-filename", "") or ""
    if ext ~= "" and subinfo[ext] and subinfo[ext] ~= "" then
        return tostring(subinfo[ext]):upper()
    end
    local title = (mp.get_property("current-tracks/sub/title", "") or ""):upper()
    local lang  = (mp.get_property("current-tracks/sub/lang",  "") or ""):upper()
    local codec = (mp.get_property("current-tracks/sub/codec", "") or ""):upper()
    local parts = {}
    if title ~= "" then parts[#parts+1] = title end
    if lang  ~= "" then parts[#parts+1] = lang  end
    if codec ~= "" then parts[#parts+1] = codec end
    return table.concat(parts, " ")
end

-- Set by the app when the subtitle is burned into the stream and only the module
-- can change it (Jellyfin transcode): mpv has no sub track to cycle, so the
-- SUBTITLE button asks the module to re-request the stream instead.
local sub_cycle   = mp.get_opt("sub-cycle") == "1"
-- Same for audio when the track is baked into the stream (Jellyfin transcode):
-- the AUDIO button asks the module to re-request rather than cycling locally.
local audio_cycle = mp.get_opt("audio-cycle") == "1"

local btn_actions = {
    function()
        if audio_cycle then
            mp.commandv("script-message", "cycle-audio")
        else
            mp.command("no-osd cycle audio")
        end
    end,
    function()
        if sub_cycle then
            mp.commandv("script-message", "cycle-sub")
        else
            mp.command("no-osd cycle sub")
        end
    end,
    function() mp.command("no-osd cycle-values panscan 0 1") end,
    function() mp.command("quit") end,
    function() mp.command("playlist-prev") end,
    function() mp.command("playlist-next") end,
}

local function has_subtitle_tracks()
    -- Burned-in transcode subs never appear in the track list.
    if sub_cycle then return true end
    local tracks = mp.get_property_native("track-list", {})
    for _, t in ipairs(tracks) do
        if t.type == "sub" then return true end
    end
    return false
end

local function has_playlist()
    return (mp.get_property_number("playlist-count", 1) or 1) > 1
end

-- Set by MpvController on decode paths where --panscan blanks the video
-- (Pi 3 overlay path with 1080p Playback ON) — the CROP button would be a no-op.
local hide_crop = mp.get_opt("hide-crop") == "1"

local function build_left_btns(has_sub, has_pl, bar_w)
    local btns = {}
    if skip_active then
        btns[#btns + 1] = {label="SKIP", width=math.floor(bar_w * 0.090625), action=function()
            mp.commandv("script-message", "skip-segment")
        end}
    end
    btns[#btns + 1] = {label="AUDIO", width=math.floor(bar_w * 0.109375), action=btn_actions[1]}
    if has_sub then
        table.insert(btns, {label="SUBTITLE", width=math.floor(bar_w * 0.15625), action=btn_actions[2]})
    end
    if not hide_crop then
        table.insert(btns, {label="CROP", width=math.floor(bar_w * 0.090625), action=btn_actions[3]})
    end
    if has_pl then
        table.insert(btns, {label="<", width=math.floor(bar_w * 0.055), action=btn_actions[5]})
        table.insert(btns, {label=">", width=math.floor(bar_w * 0.055), action=btn_actions[6]})
    end
    return btns
end

local transcode_offset = tonumber(mp.get_opt("transcode-offset") or "0") or 0

-- Latch duration on the first valid read of each file: when Plex restarts an HLS
-- transcode after rapid seeking, `duration` can spike mid-stream and corrupt the
-- end-time display. Cleared per file so each playlist item latches its own duration.
local stable_duration = nil
mp.observe_property("duration", "number", function(_, value)
    if value and value > 0 and not stable_duration then
        stable_duration = value
    end
end)
mp.register_event("start-file", function() stable_duration = nil end)

-- Matches the clock in the app's top-right corner: the app resolves the
-- 12/24-hour question (AppCore::twelve_hour_clock) and passes the answer down.
local clock_12h = mp.get_opt("clock-12h") == "1"

local function clock_time(t)
    -- %I pads to two digits; a wall clock in this app reads "9:05 PM".
    if clock_12h then return (os.date("%I:%M %p", t):gsub("^0", "")) end
    return os.date("%H:%M", t)
end

-- ASS reads braces and backslashes as markup, so a title containing one would
-- swallow the rest of the line. Newlines fold to spaces for the same reason.
local function ass_escape(s)
    return (s:gsub("[{}\\]", ""):gsub("%s+", " "))
end

-- Byte length lies about UTF-8, and a naive sub() can slice a multi-byte glyph
-- in half, so count and cut on character boundaries instead.
local function utf8_len(s)
    local n = 0
    for _ in s:gmatch("[^\128-\191]") do n = n + 1 end
    return n
end

local function utf8_sub(s, n)
    local i, count = 1, 0
    while i <= #s and count < n do
        local c = s:byte(i)
        i = i + (c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4)
        count = count + 1
    end
    return s:sub(1, i - 1)
end

local function format_time(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%d:%02d", m, s)
    end
end

-- Draw a filled rectangle with an optional border.
-- Uses ass:pos() (no \an tag) to match mpv's expected drawing coordinate origin.
local function draw_rect(ass, x, y, w, h, fc, fa, bs, bc)
    ass:new_event()
    ass:pos(x, y)
    ass:append(string.format(
        "{\\bord%d\\3c%s\\3a&H00&\\1c%s\\1a%s\\shad0}",
        bs, bc, fc, fa))
    ass:draw_start()
    ass:rect_cw(0, 0, w, h)
    ass:draw_stop()
end

-- Draw a text label using VCR OSD Mono.
local function draw_text(ass, x, y, anchor, text, fs, fc, fa)
    ass:new_event()
    ass:append(string.format(
        "{\\an%d\\pos(%d,%d)\\fnVCR OSD Mono\\fs%d\\1c%s\\1a%s\\shad0\\bord0}%s",
        anchor, x, y, fs, fc, fa, text))
end

local function draw_menu()
    local ass = assdraw.ass_new()
    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return end

    -- Layout constants
    local fs      = math.floor(wh * 0.0333333)   -- font size
    local lm      = math.floor(ww * 0.12)    -- left margin
    local rm      = math.floor(ww * 0.88)    -- right margin
    local bar_w   = rm - lm
    local border  = 2

    -- Heights derived from fs so they scale consistently with the font
    local bar_h   = math.floor(fs * 2)
    local btn_h   = math.floor(fs * 1.5)
    local btn_gap = math.floor(bar_w * 0.025)

    -- Row y-positions
    local row1_y  = math.floor(wh * 0.7083333)
    local bar_y   = math.floor(wh * 0.74375)
    local btn_y   = math.floor(wh * 0.8333333)

    local has_sub    = has_subtitle_tracks()
    local stop_w     = math.floor(bar_w * 0.090625)
    local left_btns  = build_left_btns(has_sub, has_playlist(), bar_w)

    -- Title-block geometry, needed here so the scrim below can cut around it.
    local poster_h = math.floor(wh * 0.09375)
    -- Cover art unless the module says otherwise: a square channel avatar or a
    -- 16:9 still would be cropped to a portrait box for nothing. Height is the
    -- fixed side either way, so the block's lines land in the same places.
    local poster_ar = tonumber(nowplaying.aspect) or 0
    if poster_ar <= 0 then poster_ar = 2 / 3 end
    local poster_w = math.floor(poster_h * poster_ar)
    local block_y  = math.floor(wh * 0.1)

    -- ── Scrim ─────────────────────────────────────────────────────
    -- The controls are white-on-white over a bright frame otherwise. Drawn
    -- first, and cut away over the poster: mpv draws overlay-add art *under*
    -- this script's ASS, so without the hole the art would be dimmed twice.
    ass:new_event()
    ass:pos(0, 0)
    ass:append(string.format("{\\bord0\\shad0\\1c%s\\1a%s}", C_BLACK, A_SCRIM))
    ass:draw_start()
    ass:rect_cw(0, 0, ww, wh)
    if poster_shown then
        ass:rect_ccw(lm, block_y, lm + poster_w, block_y + poster_h)
    end
    ass:draw_stop()

    -- A hairline round the art in the same white as every other element here,
    -- so a poster whose edges are dark does not bleed into the dimmed frame.
    -- Drawn after the scrim, not through it, or it would be dimmed with the video.
    if poster_shown then
        draw_rect(ass, lm, block_y, poster_w, poster_h, C_BLACK, A_TRANS, 1, C_WHITE)
    end

    -- VCR OSD Mono is monospaced, so a character is 0.6em and a line's width is
    -- countable without measuring it.
    local char_w = fs * 0.6

    -- ── Title block (top-left) ────────────────────────────────────
    -- Cover art with what is playing beside it: the film, episode or video on
    -- the top line, what it belongs to (the show, the channel) beneath. A movie
    -- names itself and has nothing for that second line.
    local show     = tostring(nowplaying.show  or "")
    local np_title = tostring(nowplaying.title or mp.get_property("media-title", "") or "")
    local heading  = (np_title ~= "") and np_title or show
    local subline  = (np_title ~= "") and show or ""
    -- Read before the heading is laid out: they share a line, and the heading is
    -- the one that has to give way.
    local clock_str = clock_time(os.time())

    -- SERVER | PROFILE, left of the clock — the same strip the app keeps in its
    -- own corner (Plex's StatusLine.qml). Text only: there is nothing to switch
    -- to mid-playback. Smaller than the clock, in the app's own proportion.
    local src_fs  = math.floor(fs * 0.75)
    local src_parts = {}
    if nowplaying.server  and nowplaying.server  ~= "" then
        src_parts[#src_parts + 1] = tostring(nowplaying.server)
    end
    if nowplaying.profile and nowplaying.profile ~= "" then
        src_parts[#src_parts + 1] = tostring(nowplaying.profile)
    end
    local src_str = ass_escape(table.concat(src_parts, " | ")):upper()
    -- A server or profile can be named anything; the corner has a quarter of the
    -- row for both, and the title block beside it has the rest.
    local src_max = math.floor((ww * 0.25) / (src_fs * 0.6))
    if utf8_len(src_str) > src_max then
        src_str = (src_max >= 4) and (utf8_sub(src_str, src_max - 3) .. "...") or ""
    end
    -- Both fonts are monospaced, so the strip's width is countable: the clock at
    -- the full size, this at the smaller one, and two clock characters between.
    local src_gap = char_w * 2
    local src_w   = (src_str ~= "")
                    and (utf8_len(src_str) * src_fs * 0.6 + src_gap) or 0

    -- Asked for at whatever this window's pixels are, so it is sharp on a Pi's
    -- 480p framebuffer and on a desktop 4K alike. overlay-add does not scale, so
    -- art of the wrong size can only sit small or spill out: anything that does
    -- not match what this window wants is dropped and asked for again.
    if poster and (poster.w ~= poster_w or poster.h ~= poster_h) then
        mp.msg.warn(string.format(
            "poster is %dx%d but this window wants %dx%d — asking again",
            poster.w, poster.h, poster_w, poster_h))
        hide_poster()
        poster       = nil
        poster_asked = false
    end
    if nowplaying.poster and not poster_asked then
        poster_asked = true
        mp.msg.info(string.format("poster request %dx%d (osd %dx%d)",
                                  poster_w, poster_h, ww, wh))
        mp.commandv("script-message", "240mp-poster-request",
                    tostring(poster_w), tostring(poster_h))
    end
    if poster and not poster_shown then
        mp.commandv("overlay-add", POSTER_OVERLAY_ID, lm, block_y,
                    poster.file, 0, "bgra", poster.w, poster.h, poster.stride)
        poster_shown = true
    end

    -- Space kept from the first frame, not from the moment the art turns up, so
    -- the text does not jump sideways when it does.
    local text_x  = nowplaying.poster and (lm + poster_w + math.floor(char_w * 1.5)) or lm
    -- The two lines are measured against the art beside them rather than against
    -- the font, so the block reads as one object: the poster's height divides
    -- into gap, name, gap, rating, gap — thirds of a third, so the name and the
    -- rating each get a third and the three gaps share the rest.
    local unit    = poster_h / 3
    local gap     = unit / 3
    local head_y  = block_y + gap + unit / 2
    local rate_y  = block_y + gap * 2 + unit * 1.5
    if heading ~= "" then
        local max_ch = math.floor((rm - text_x - src_w) / char_w) - #clock_str - 2
        local line   = ass_escape(heading):upper()
        if max_ch >= 4 then
            if utf8_len(line) > max_ch then line = utf8_sub(line, max_ch - 3) .. "..." end
            draw_text(ass, text_x, head_y, 4, line, fs, C_WHITE, A_OPAQUE)
        end
    end

    -- ── Second line: what it belongs to, and its mark ─────────────
    -- The show an episode is from, the channel a video is from — smaller than
    -- the name above, because it qualifies it. Right-aligned on the same line,
    -- under the clock: the certificate, or the plain label a module with none
    -- puts there (YouTube names the playlist).
    local r_fs = math.floor(unit * 0.72)
    -- A third of the row at most for either: a certificate is three characters
    -- and never tests this, a playlist name can be any length.
    local mark_max = math.floor((ww / 3) / (r_fs * 0.6))
    local function fit(text)
        if utf8_len(text) <= mark_max then return text end
        return (mark_max >= 4) and (utf8_sub(text, mark_max - 3) .. "...") or ""
    end
    local rating = fit(ass_escape(tostring(nowplaying.rating or "")):upper())
    local label  = fit(ass_escape(tostring(nowplaying.label  or "")):upper())
    -- What the right-hand corner takes, for the name beside it to stop short of.
    local mark_w = 0
    if rating ~= "" then
        -- Boxed the way a certificate card is, which is as official as this can
        -- honestly look: the real marks are trademarked artwork, and ASS draws
        -- vectors and text, not bitmaps.
        local box_h  = math.floor(unit)
        local box_w  = math.floor((utf8_len(rating) + 1.4) * r_fs * 0.6)
        local box_x  = rm - box_w
        local box_y  = math.floor(rate_y - box_h / 2)
        -- A hairline: the seek bar's 2px border would be half the height of a
        -- box this size.
        local r_bord = math.max(1, math.floor(border / 2))
        draw_rect(ass, box_x, box_y, box_w, box_h, C_BLACK, A_TRANS, r_bord, C_WHITE)
        draw_text(ass, box_x + box_w / 2, box_y + box_h / 2, 5,
                  rating, r_fs, C_WHITE, A_OPAQUE)
        mark_w = box_w
    elseif label ~= "" then
        -- No box: this one is a name, and a border would present it as a mark.
        draw_text(ass, rm, rate_y, 6, label, r_fs, C_WHITE, A_OPAQUE)
        mark_w = utf8_len(label) * r_fs * 0.6
    end
    if subline ~= "" then
        -- Stops short of the mark beside it, not at the margin, with one line's
        -- worth of air between the two.
        local max_ch = math.floor((rm - text_x - mark_w - r_fs) / (r_fs * 0.6))
        local line   = ass_escape(subline):upper()
        if max_ch >= 4 then
            if utf8_len(line) > max_ch then line = utf8_sub(line, max_ch - 3) .. "..." end
            draw_text(ass, text_x, rate_y, 4, line, r_fs, C_WHITE, A_OPAQUE)
        end
    end

    -- ── Wall clock (top-right) ────────────────────────────────────
    -- Where the app's own clock sits, so bringing up the OSD doesn't lose the
    -- time. Redrawn with the menu twice a second. On the first title line's
    -- baseline, so poster, title and time all start on the same line.
    draw_text(ass, rm, head_y, 6, clock_str, fs, C_WHITE, A_OPAQUE)
    if src_str ~= "" then
        draw_text(ass, rm - #clock_str * char_w - src_gap, head_y, 6,
                  src_str, src_fs, C_WHITE, A_OPAQUE)
    end

    -- ── Row 1: Time text ──────────────────────────────────────────
    local total    = stable_duration or (mp.get_property_number("duration", 0) or 0)
    local time_pos = math.min(math.max(0, (mp.get_property_number("time-pos", 0) or 0) + transcode_offset), total)
    local percent  = (total > 0) and math.min(100, math.max(0, time_pos / total * 100)) or 0

    draw_text(ass, lm, row1_y, 4, format_time(time_pos), fs, C_WHITE, A_OPAQUE)
    draw_text(ass, rm, row1_y, 6, format_time(total),    fs, C_WHITE, A_OPAQUE)

    -- Nothing else goes on this row: it is two readings of the same bar, and a
    -- name squeezed between them reads as a third one. What is playing is named
    -- in the block at the top, where it is a heading rather than a caption.

    -- ── Row 2: Seek bar ───────────────────────────────────────────
    local pad   = 2
    local inset = border + pad

    -- Transparent box with white border
    draw_rect(ass, lm, bar_y, bar_w, bar_h, C_BLACK, A_TRANS, border, C_WHITE)

    -- Progress fill (full opacity when focused, 40% when not)
    local inner_w    = bar_w - 2 * inset
    local fill_w     = math.max(0, math.floor(inner_w * (percent / 100)))
    local fill_alpha = (focus_row == 0) and A_OPAQUE or A_DIM
    if fill_w > 0 then
        draw_rect(ass, lm + inset, bar_y + inset, fill_w, bar_h - 2 * inset,
                  C_WHITE, fill_alpha, 0, C_WHITE)
    end

    -- ── Row 3: Buttons ────────────────────────────────────────────
    -- Left group: [SKIP], AUDIO, [SUBTITLE], [CROP], [< >]
    local stop_idx = #left_btns + 1
    local bx = lm
    for i, btn in ipairs(left_btns) do
        local sel    = (focus_row == 1 and focus_btn == i)
        local fill_c = sel and C_WHITE or C_BLACK
        local fill_a = sel and A_OPAQUE or A_TRANS
        local text_c = sel and C_BLACK  or C_WHITE

        draw_rect(ass, bx, btn_y, btn.width, btn_h, fill_c, fill_a, border, C_WHITE)
        draw_text(ass, bx + btn.width / 2, btn_y + btn_h / 2, 5,
                  btn.label, fs, text_c, A_OPAQUE)
        bx = bx + btn.width + btn_gap
    end

    -- Left of STOP: when this finishes, as a wall-clock time. "45 MINUTES LEFT"
    -- is a number you have to do arithmetic on; "ENDS 21:45" is the answer.
    -- Live TV and anything else with no duration gets nothing.
    local stop_x = rm - stop_w
    if total > 0 then
        local end_x  = stop_x - btn_gap
        local finish = clock_time(os.time() + math.floor(math.max(0, total - time_pos)))
        local label  = "ENDS " .. finish
        -- With SKIP up and a playlist loaded the middle of this row gets narrow,
        -- so give up the word before the time, then the line itself, rather than
        -- run underneath the buttons.
        if #label * char_w > end_x - bx then label = finish end
        if #label * char_w <= end_x - bx then
            draw_text(ass, end_x, btn_y + btn_h / 2, 6, label, fs, C_WHITE, A_OPAQUE)
        end
    end

    -- Right: STOP
    local sel    = (focus_row == 1 and focus_btn == stop_idx)
    local fill_c = sel and C_WHITE or C_BLACK
    local fill_a = sel and A_OPAQUE or A_TRANS
    local text_c = sel and C_BLACK  or C_WHITE

    draw_rect(ass, stop_x, btn_y, stop_w, btn_h, fill_c, fill_a, border, C_WHITE)
    draw_text(ass, stop_x + stop_w / 2, btn_y + btn_h / 2, 5,
              "STOP", fs, text_c, A_OPAQUE)

    -- ── Track info (under the transport) ──────────────────────────
    -- Which audio and subtitle are playing: a footnote to the bar, so it sits at
    -- the foot of the controls rather than the top-left corner the title block
    -- now owns.
    local info_fs = math.floor(fs * 0.75)
    local info_lh = math.floor(info_fs * 1.4)
    local info_y  = btn_y + btn_h + math.floor(info_lh * 0.75)

    draw_text(ass, lm, info_y, 4, "AUDIO: " .. get_audio_str(), info_fs, C_WHITE, A_OPAQUE)
    if has_sub then
        draw_text(ass, lm, info_y + info_lh, 4, "SUBTITLE: " .. get_sub_str(), info_fs, C_WHITE, A_OPAQUE)
    end

    mp.set_osd_ass(ww, wh, ass.text)
end

local function reset_idle_timer()
    if idle_timer then idle_timer:kill() end
    idle_timer = mp.add_timeout(MENU_TIMEOUT, function()
        if menu_visible then
            menu_visible = false
            mp.set_osd_ass(0, 0, "")
            hide_poster()
            if update_timer then update_timer:stop() end
            mp.remove_key_binding("menu-up")
            mp.remove_key_binding("menu-down")
            mp.remove_key_binding("menu-left")
            mp.remove_key_binding("menu-right")
            mp.remove_key_binding("menu-enter")
            mp.remove_key_binding("menu-esc")
            mp.remove_key_binding("menu-bs")
        end
    end)
end

local function update_nav(action)
    reset_idle_timer()

    if action == "up" then
        focus_row = 0
    elseif action == "down" then
        focus_row = 1
    elseif action == "left" then
        if focus_row == 0 then
            mp.command("seek -" .. SEEK_SECONDS)
        else
            local has_sub = has_subtitle_tracks()
            local has_pl  = has_playlist()
            local ww, _   = mp.get_osd_size()
            local bar_w   = math.floor(ww * 0.88) - math.floor(ww * 0.12)
            local total   = #build_left_btns(has_sub, has_pl, bar_w) + 1
            focus_btn = focus_btn > 1 and focus_btn - 1 or total
        end
    elseif action == "right" then
        if focus_row == 0 then
            mp.command("seek " .. SEEK_SECONDS)
        else
            local has_sub = has_subtitle_tracks()
            local has_pl  = has_playlist()
            local ww, _   = mp.get_osd_size()
            local bar_w   = math.floor(ww * 0.88) - math.floor(ww * 0.12)
            local total   = #build_left_btns(has_sub, has_pl, bar_w) + 1
            focus_btn = focus_btn < total and focus_btn + 1 or 1
        end
    elseif action == "enter" and focus_row == 1 then
        local has_sub   = has_subtitle_tracks()
        local has_pl    = has_playlist()
        local ww, wh    = mp.get_osd_size()
        local bar_w     = math.floor(ww * 0.88) - math.floor(ww * 0.12)
        local btns      = build_left_btns(has_sub, has_pl, bar_w)
        local total     = #btns + 1
        local clamped   = math.min(focus_btn, total)
        if clamped <= #btns then
            btns[clamped].action()
        else
            btn_actions[4]()
        end
    end

    draw_menu()
end

local function toggle_menu()
    if menu_visible then
        menu_visible = false
        mp.set_osd_ass(0, 0, "")
        hide_poster()
        if update_timer then update_timer:stop() end
        if idle_timer   then idle_timer:kill()   end
        mp.remove_key_binding("menu-up")
        mp.remove_key_binding("menu-down")
        mp.remove_key_binding("menu-left")
        mp.remove_key_binding("menu-right")
        mp.remove_key_binding("menu-enter")
        mp.remove_key_binding("menu-esc")
        mp.remove_key_binding("menu-bs")
    else
        -- Tell the volume bar (mpv-media-keys.lua) to stand down — the two OSDs
        -- share the same spot and are mutually exclusive.
        mp.commandv("script-message", "240mp-osd-volume-hide")
        menu_visible = true
        focus_row    = 1
        draw_menu()
        update_timer = mp.add_periodic_timer(0.5, draw_menu)
        reset_idle_timer()

        mp.add_forced_key_binding("UP",    "menu-up",    function() update_nav("up")    end)
        mp.add_forced_key_binding("DOWN",  "menu-down",  function() update_nav("down")  end)
        mp.add_forced_key_binding("LEFT",  "menu-left",  function() update_nav("left")  end, {repeatable = true})
        mp.add_forced_key_binding("RIGHT", "menu-right", function() update_nav("right") end, {repeatable = true})
        mp.add_forced_key_binding("ENTER", "menu-enter", function() update_nav("enter") end)
        mp.add_forced_key_binding("ESC",   "menu-esc",   toggle_menu)
        mp.add_forced_key_binding("BS",    "menu-bs",    toggle_menu)
    end
end

-- The app's answer to 240mp-poster-request: raw premultiplied BGRA at the size
-- that was asked for. Nothing is drawn here — the menu redraws twice a second
-- and picks the overlay up on its next pass.
mp.register_script_message("240mp-poster-ready", function(file, w, h, stride)
    poster = { file = file, w = tonumber(w), h = tonumber(h), stride = tonumber(stride) }
    if not (poster.w and poster.h and poster.stride) then
        poster = nil
        return
    end
    mp.msg.info(string.format("poster ready %dx%d stride %d", poster.w, poster.h, poster.stride))
end)

-- The volume bar (mpv-media-keys.lua) broadcasts this when it appears; close the
-- menu so the two OSDs never overlap. toggle_menu() runs the full teardown.
mp.register_script_message("240mp-osd-menu-hide", function()
    if menu_visible then toggle_menu() end
end)

-- mpv-media-keys.lua broadcasts this on seek / chapter changes so the nav menu
-- pops up to show the new position. Open it if closed; otherwise just redraw
-- and restart the auto-hide timer.
mp.register_script_message("240mp-osd-menu-show", function()
    if menu_visible then
        reset_idle_timer()
        draw_menu()
    else
        toggle_menu()
    end
end)

-- Forced bindings so UP/DOWN take priority over mpv's default seek bindings
-- on desktop (macOS/Linux with native keyboard input).
mp.add_forced_key_binding("UP",   "open_menu_up",   toggle_menu)
mp.add_forced_key_binding("DOWN", "open_menu_down", toggle_menu)

-- ESC / BS quit when the menu is not visible. When the menu opens it adds
-- forced bindings for these keys that take priority automatically; when it
-- closes those forced bindings are removed and these become active again.
mp.add_key_binding("ESC", "bg-esc", function() mp.command("quit") end)
mp.add_key_binding("BS",  "bg-bs",  function() mp.command("quit") end)

mp.register_script_message("skip-overlay-state", function(state)
    skip_active = (state == "1")
    -- Land focus on SKIP (first button) so ENTER skips immediately —
    -- focus_btn otherwise persists from the last menu interaction.
    if skip_active then focus_btn = 1 end
end)
