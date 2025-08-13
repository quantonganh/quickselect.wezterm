local M = {}

local wezterm = require("wezterm")
local act = wezterm.action

function string.startswith(str, prefix)
    return string.sub(str, 1, string.len(prefix)) == prefix
end

local function extract_filename(uri)
    local start, match_end = uri:find("$EDITOR:")
    if start == 1 then
        return uri:sub(match_end + 1)
    end

    return nil
end

local function is_editable(filename, text_extensions)
    local ext = filename:match("%.([^.:/\\]+):%d+.*$")
    if ext then
        wezterm.log_info(string.format("extension is [%s]", ext))
        return text_extensions[ext] or false
    end

    return false
end

local function get_extension(filename)
    return filename:match("%.([^.:/\\]+):%d+:%d+$")
end

local function basename(s)
    return string.gsub(s, "(.*[/\\])(.*)", "%2")
end

function M.open_with_hx(window, pane, url, opts)
    local filename = extract_filename(url)
    if not filename then
        wezterm.log_error(url .. " is not a valid filename")
        return
    end
    if not is_editable(filename, opts.text_extensions) then
        wezterm.log_info(filename .. " is not editable")
        return -- let default action handle it
    end

    wezterm.log_info(filename .. " is editable")
    if get_extension(filename) == "rs" then
        local pwd = string.gsub(tostring(pane:get_current_working_dir()), "file://.-(/.+)", "%1")
        filename = pwd .. "/" .. filename
    end

    local hx_pane = pane:tab():get_pane_direction(opts.direction)
    if not hx_pane then
        local action = act({
            SplitPane = {
                direction = opts.direction,
                command = { args = { "hx", filename } },
            },
        })
        window:perform_action(action, pane)
        hx_pane = pane:tab():get_pane_direction(opts.direction).activate()
    else
        local process = basename(hx_pane:get_foreground_process_name())
        local command
        if process == "hx" then
            command = ":open " .. filename .. "\r\n"
        else
            command = "hx " .. filename .. "\r\n"
        end
        wezterm.log_info("process: " .. process .. ", action: " .. command)
        local action = act.SendString(command)
        window:perform_action(action, hx_pane)
    end
    hx_pane:activate()

    -- prevent the default action from opening in a browser
end

M.filters = {}
function M.filters.startswith(str)
    return function(selection)
        return selection:startswith(str)
    end
end

function M.filters.match(str)
    return function(selection)
        return selection:match(str)
    end
end

function M.apply_to_config(config, opts)
    if not opts then
        opts = {}
    end
    opts.key = opts.key or "s"
    opts.mods = opts.mods or "CMD|SHIFT"
    opts.text_extensions = opts.text_extensions
        or {
            md = true,
            c = true,
            go = true,
            scm = true,
            rkt = true,
            rs = true,
            java = true,
        }
    opts.patterns = opts.patterns
        or {
            "https?://\\S+",
            "^/[^/\r\n]+(?:/[^/\r\n]+)*:\\d+:\\d+",
            "[^\\s]+\\.rs:\\d+:\\d+",
            "rustc --explain E\\d+",
            "[^\\s]+\\.go:\\d+",
            "[^\\s]+\\.go:\\d+:\\d+",
            "[^\\s]+\\.java:\\[\\d+,\\d+\\]",
            "[^{]*{.*}",
        }
    opts.actions = opts.actions
        or {
            {
                filter = M.filters.startswith("http"),
                action = function(_, _, selection, _)
                    wezterm.open_with(selection)
                end,
            },
            {
                filter = M.filters.startswith("rustc --explain"),
                action = function(window, pane, selection, _)
                    local code = selection:match("(%S+)$")
                    window:perform_action(
                        act.SplitPane({
                            direction = "Right",
                            command = {
                                args = {
                                    "/bin/sh",
                                    "-c",
                                    "rustc --explain " .. code .. " | mdcat -p",
                                },
                            },
                        }),
                        pane
                    )
                end,
            },
            {
                filter = M.filters.match("[^{]*{.*}"),
                action = function(window, pane, selection, _)
                    local json = selection:match("{.*}")
                    local cmd = "echo '" .. json .. "' | jq -C . | less -R"
                    window:perform_action(
                        act.SplitPane({
                            direction = "Right",
                            command = { args = { "/bin/sh", "-c", cmd } },
                        }),
                        pane
                    )
                end,
            },
            {
                filter = M.filters.match("[^:%s]+%.java):%[(%d+),%d+%]"),
                action = function(window, pane, selection, opts)
                    local file, line = selection:match("([^:%s]+%.java):%[(%d+),%d+%]")
                    if file and line then
                        selection = "$EDITOR:" .. file .. ":" .. line
                    else
                        selection = "$EDITOR:" .. selection
                    end
                    return M.open_with_hx(window, pane, selection, opts)
                end,
            },
        }
    opts.direction = opts.direction or "Up"

    config.keys = config.keys or {}
    table.insert(config.keys, {
        key = opts.key,
        mods = opts.mods,
        action = act.QuickSelectArgs({
            label = "open url",
            patterns = opts.patterns,
            action = wezterm.action_callback(function(window, pane)
                local selection = window:get_selection_text_for_pane(pane)
                wezterm.log_info("opening: " .. selection)

                -- use custom action
                for _, custom in ipairs(opts.actions) do
                    if custom.filter(selection) then
                        return custom.action(window, pane, selection, opts)
                    end
                end

                -- if not suitable custom action, fallback to default
                selection = "$EDITOR:" .. selection
                return M.open_with_hx(window, pane, selection, opts)
            end),
        }),
    })
end

return M
