--[[

License: https://github.com/CrendKing/mpv-twitch-chat/blob/master/LICENSE

Options:

    show_name: Whether to show the commenter's name.

    color: If show_name is enabled, color the commenter's name with its user color. Otherwise, color the whole message.

    duration_multiplier: Each chat message's duration is calculated based on the density of the messages at the time after
        applying this multiplier. Basically, if you want more messages simultaneously on screen, increase this number.

    max_duration: Maximum duration in seconds of each chat message after applying the previous multiplier. This exists to prevent
        messages to stay forever in "cold" segments.

    fetch_aot: The chat data is downloaded in segments. This script uses timer to fetch new segments this many seconds before the
        current segment is exhausted. Increase this number to avoid interruption if you have slower network to Twitch.

--]]

local o = {
    show_name = false,
    color = true,
    duration_multiplier = 10,
    max_duration = 10,
    fetch_aot = 1
}

local options = require 'mp.options'
options.read_options(o)

if not mp.get_script_directory() then
    return
end

local utils = require "mp.utils"
package.path = utils.join_path(utils.join_path(mp.get_script_directory(), "json.lua"), "json.lua;") .. package.path
local json = require "json"

-- sid to be operated on
local chat_sid
-- request url for the chat data
local twitch_comments_url
-- next segment ID to fetch from Twitch
local twitch_cursor
-- two fifo segments for cycling the subtitle text
local curr_segment
local next_segment
-- SubRip sequence counter
local seq_counter
-- timer to fetch new segments of the chat data
local timer

function load_twitch_chat(is_new_session)
    if not chat_sid then
        return
    end

    local request_url
    if is_new_session then
        local time_pos = mp.get_property_native("time-pos")
        if not time_pos then
            return
        end

        request_url = twitch_comments_url .. "?content_offset_seconds=" .. math.max(time_pos, 0)
        next_segment = ""
        seq_counter = 0
    else
        request_url = twitch_comments_url .. "?cursor=" .. twitch_cursor
    end

    local sp_ret = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        args = {"curl", "-s", "-H", "Client-ID: phiay4sq36lfv9zu7cbqwz2ndnesfd8", request_url},
    })
    if sp_ret.status ~= 0 then
        mp.msg.error("Error curl exit code: " .. sp_ret.status)
        return
    end

    local resp_json = json.decode(sp_ret.stdout)
    local comments = resp_json.comments
    if not comments then
        mp.msg.error("Failed to download comments JSON: " .. sp_ret.stdout)
        return
    end

    twitch_cursor = resp_json._next
    curr_segment = next_segment
    next_segment = ""

    local last_msg_offset = comments[#comments].content_offset_seconds
    local segment_duration = last_msg_offset - comments[1].content_offset_seconds
    local per_msg_duration = math.min(segment_duration * o.duration_multiplier / #comments, o.max_duration)

    for i, curr_comment in ipairs(comments) do
        local msg_time_from = curr_comment.content_offset_seconds
        local msg_time_from_ms = math.floor(msg_time_from * 1000) % 1000
        local msg_time_from_sec = math.floor(msg_time_from) % 60
        local msg_time_from_min = math.floor(msg_time_from / 60) % 60
        local msg_time_from_hour = math.floor(msg_time_from / 3600)

        local msg_time_to = msg_time_from + per_msg_duration
        local msg_time_to_ms = math.floor(msg_time_to * 1000) % 1000
        local msg_time_to_sec = math.floor(msg_time_to) % 60
        local msg_time_to_min = math.floor(msg_time_to / 60) % 60
        local msg_time_to_hour = math.floor(msg_time_to / 3600)

        local msg_part_1, msg_part_2, msg_separator
        if o.show_name then
            msg_part_1 = curr_comment.commenter.display_name
            msg_part_2 = curr_comment.message.body
            msg_separator = ": "
        else
            msg_part_1 = curr_comment.message.body
            msg_part_2 = ""
            msg_separator = ""
        end

        if o.color and curr_comment.message.user_color then
            msg_part_1 = string.format("<font color=\"%s\">%s</font>", curr_comment.message.user_color, msg_part_1)
        end

        local msg_line = msg_part_1 .. msg_separator .. msg_part_2

        local subtitle = string.format([[%i
%i:%i:%i,%i --> %i:%i:%i,%i
%s

]],
            seq_counter,
            msg_time_from_hour, msg_time_from_min, msg_time_from_sec, msg_time_from_ms,
            msg_time_to_hour, msg_time_to_min, msg_time_to_sec, msg_time_to_ms,
            msg_line)
        next_segment = next_segment .. subtitle
        seq_counter = seq_counter + 1
    end

    mp.commandv("sub-remove", chat_sid)
    mp.command_native({
        name = "sub-add",
        url = "memory://" .. curr_segment .. next_segment,
        title = "Twitch Chat"
    })
    chat_sid = mp.get_property_native("sid")

    return last_msg_offset
end

function init()
    twitch_comments_url = nil
end

function timer_callback(is_new_session)
    local last_msg_offset = load_twitch_chat(is_new_session)
    if last_msg_offset then
        local fetch_delay = last_msg_offset - mp.get_property_native("time-pos") - o.fetch_aot
        timer = mp.add_timeout(fetch_delay, function()
            timer_callback(false)
        end)
    end
end

function handle_track_change(name, sid)
    if not sid and timer then
        timer:kill()
        timer = nil
    elseif sid and not timer then
        if not twitch_comments_url then
            local sub_filename = mp.get_property_native("current-tracks/sub/external-filename")
            twitch_comments_url = sub_filename:match("https://api.twitch.tv/v5/videos/%d+/comments")
        end

        chat_sid = sid
        timer_callback(true)
    end
end

function handle_seek()
    if mp.get_property_native("sid") then
        load_twitch_chat(true)
    end
end

mp.register_event("start-file", init)
mp.observe_property("current-tracks/sub/id", "native", handle_track_change)
mp.register_event("seek", handle_seek)
