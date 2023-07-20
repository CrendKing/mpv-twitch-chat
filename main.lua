--[[

License: https://github.com/CrendKing/mpv-twitch-chat/blob/master/LICENSE

Options:

    twitch_client_id: Client ID to be used to request the comments from Twitch API.

    show_name: Whether to show the commenter's name.

    color: If show_name is enabled, color the commenter's name with its user color. Otherwise, color the whole message.

    duration_multiplier: Each chat message's duration is calculated based on the density of the messages at the time after
        applying this multiplier. Basically, if you want more messages simultaneously on screen, increase this number.

    max_duration: Maximum duration in seconds of each chat message after applying the previous multiplier. This exists to prevent
        messages to stay forever in "cold" segments.

    max_message_length: Break long messages into lines with at most this much length. Specify 0 to disable line breaking.

    fetch_aot: The chat data is downloaded in segments. This script uses timer to fetch new segments this many seconds before the
        current segment is exhausted. Increase this number to avoid interruption if you have slower network to Twitch.

--]]

local TWITCH_GRAPHQL_URL = 'https://gql.twitch.tv/gql'

local o = {
    twitch_client_id = '',  -- replace this with a working Twitch Client ID
    show_name = false,
    color = true,
    duration_multiplier = 10,
    max_duration = 10,
    max_message_length = 40,
    fetch_aot = 1,
}

local options = require 'mp.options'
options.read_options(o)

local utils = require 'mp.utils'

-- sid to be operated on
local chat_sid
-- Twitch video id
local twitch_video_id
-- next segment ID to fetch from Twitch
local twitch_cursor
-- two fifo segments for cycling the subtitle text
local curr_segment
local next_segment
-- SubRip sequence counter
local seq_counter
-- timer to fetch new segments of the chat data
local timer
-- delimiters to specify where to allow lines to add graceful line breaks at
local delimiter_pattern = ' %.,%-!%?'

local function split_string(input)
    local splits = {}

    for input in string.gmatch(input, '[^' .. delimiter_pattern .. ']+[' .. delimiter_pattern .. ']*') do
        table.insert(splits, input)
    end

    return splits
end

local function break_message_body(message_body)
    if o.max_message_length <= 0 then
        return message_body
    end

    local length_sofar = 0
    local ret = ''

    for _, v in ipairs(split_string(message_body)) do
        length_sofar = length_sofar + #v

        if length_sofar > o.max_message_length then
            -- assume #v is always < o.max_message_length for simplicity
            ret = ret .. '\n' .. v
            length_sofar = #v
        else
            ret = ret .. v
        end
    end

    return ret
end

local function load_twitch_chat(is_new_session)
    if not chat_sid or not twitch_video_id  then
        return
    end

    local request_body = {
        ['operationName'] = 'VideoCommentsByOffsetOrCursor',
        ['variables'] = {
            ['videoID'] = twitch_video_id
        },
        ['extensions'] = {
            ['persistedQuery'] = {
                ['version'] = 1,
                ['sha256Hash'] = 'b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a'
            }
        }
    }

    if is_new_session then
        local time_pos = mp.get_property_native('time-pos')
        if not time_pos then
            return
        end

        request_body.variables.contentOffsetSeconds = math.max(math.floor(time_pos), 0)
        next_segment = ''
        seq_counter = 0
    else
        request_body.variables.cursor = twitch_cursor
    end

    local sp_ret = mp.command_native({
        name = 'subprocess',
        capture_stdout = true,
        args = {'curl', '--request', 'POST', '--header', 'Client-ID: ' .. o.twitch_client_id, '--data', utils.format_json(request_body), '--silent', TWITCH_GRAPHQL_URL},
    })

    if sp_ret.status ~= 0 then
        mp.msg.error('Error curl exit code: ' .. sp_ret.status)
        return
    end

    local resp_json = utils.parse_json(sp_ret.stdout)
    if resp_json.error then
        mp.msg.error(string.format('Error from Twitch: HTTP %d %s: %s', resp_json.status, resp_json.error, resp_json.message))
        return
    end

    local comments = resp_json.data.video.comments.edges
    if not comments then
        mp.msg.error('Failed to download comments JSON: ' .. sp_ret.stdout)
        return
    end

    twitch_cursor = comments[1].cursor
    curr_segment = next_segment
    next_segment = ''

    local last_msg_offset = comments[#comments].node.contentOffsetSeconds
    local segment_duration = last_msg_offset - comments[1].node.contentOffsetSeconds
    local per_msg_duration = math.min(segment_duration * o.duration_multiplier / #comments, o.max_duration)

    for i, curr_comment in ipairs(comments) do
        local curr_comment_node = curr_comment.node

        local msg_time_from = curr_comment_node.contentOffsetSeconds
        local msg_time_from_ms = math.floor(msg_time_from * 1000) % 1000
        local msg_time_from_sec = math.floor(msg_time_from) % 60
        local msg_time_from_min = math.floor(msg_time_from / 60) % 60
        local msg_time_from_hour = math.floor(msg_time_from / 3600)

        local msg_time_to = msg_time_from + per_msg_duration
        local msg_time_to_ms = math.floor(msg_time_to * 1000) % 1000
        local msg_time_to_sec = math.floor(msg_time_to) % 60
        local msg_time_to_min = math.floor(msg_time_to / 60) % 60
        local msg_time_to_hour = math.floor(msg_time_to / 3600)

        local msg_text = ''
        for j, frag in ipairs(curr_comment_node.message.fragments) do
            msg_text = msg_text .. (frag.emote and '<u>' or '') .. frag.text .. (frag.emote and '</u>' or '')
        end

        local msg_part_1, msg_part_2, msg_separator
        if o.show_name and curr_comment_node.commenter then
            msg_part_1 = curr_comment_node.commenter.displayName
            msg_part_2 = break_message_body(msg_text)
            msg_separator = ': '
        else
            msg_part_1 = break_message_body(msg_text)
            msg_part_2 = ''
            msg_separator = ''
        end

        if o.color then
            if curr_comment_node.message.userColor then
                msg_color = curr_comment_node.message.userColor
            elseif curr_comment_node.commenter then
                msg_color = string.format('#%06x', curr_comment_node.commenter.id % 16777216)
            end

            if msg_color then
                msg_part_1 = string.format('<font color="%s">%s</font>', msg_color, msg_part_1)
            end
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

    mp.command_native({
        name = 'sub-remove',
        id = chat_sid
    })
    mp.command_native({
        name = 'sub-add',
        url = 'memory://' .. curr_segment .. next_segment,
        title = 'Twitch Chat'
    })
    chat_sid = mp.get_property_native('sid')

    return last_msg_offset
end

local function init()
    twitch_video_id = nil
end

local function timer_callback(is_new_session)
    local last_msg_offset = load_twitch_chat(is_new_session)
    if last_msg_offset then
        local fetch_delay = last_msg_offset - mp.get_property_native('time-pos') - o.fetch_aot
        timer = mp.add_timeout(fetch_delay, function()
            timer_callback(false)
        end)
    end
end

local function handle_track_change(name, sid)
    if not sid and timer then
        timer:kill()
        timer = nil
    elseif sid and not timer then
        if not twitch_video_id then
            local sub_filename = mp.get_property_native('current-tracks/sub/external-filename')
            if sub_filename then
                twitch_video_id, twitch_client_id_from_track = sub_filename:match('https://api%.twitch%.tv/v5/videos/(%d+)/comments%?client_id=(%w+)')

                if twitch_client_id_from_track and o.twitch_client_id == '' then
                    o.twitch_client_id = twitch_client_id_from_track
                end
            end
        end

        if twitch_video_id then
            chat_sid = sid
            mp.command_native({'sub-remove', chat_sid})
            timer_callback(true)
        end
    end
end

local function handle_seek()
    if mp.get_property_native('sid') then
        load_twitch_chat(true)
    end
end

local function handle_pause(name, paused)
    if timer then
        if paused then
            timer:stop()
        else
            timer:resume()
        end
    end
end

mp.register_event('start-file', init)
mp.observe_property('current-tracks/sub/id', 'native', handle_track_change)
mp.register_event('seek', handle_seek)
mp.observe_property('pause', 'native', handle_pause)
