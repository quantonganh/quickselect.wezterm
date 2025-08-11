local M = {}

local wezterm = require('wezterm')
local act = wezterm.action

local function startswith(str, prefix)
    return string.sub(str, 1, string.len(prefix)) == prefix
end

local function extract_filename(uri)
    local start, match_end = uri:find("$EDITOR:");
    if start == 1 then
        return uri:sub(match_end+1)
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
    return string.gsub(s, '(.*[/\\])(.*)', '%2')
end

function M.Open_with_hx(window, pane, url, text_extensions)
    local filename = extract_filename(url)
    if not (filename and is_editable(filename, text_extensions)) then
        return -- let default action handle it
    end

    wezterm.log_info('editable')
    if get_extension(filename) == "rs" then
        local pwd = string.gsub(tostring(pane:get_current_working_dir()), "file://.-(/.+)", "%1")
        filename = pwd .. "/" .. filename
    end

    local direction = 'Up'
    local hx_pane = pane:tab():get_pane_direction(direction)
    wezterm.log_info("fg process: " .. hx_pane:get_foreground_process_name())
    if hx_pane == nil then
        local action = act{
            SplitPane={
                direction = direction,
                command = { args = { 'hx', filename } }
            };
        };
        window:perform_action(action, pane);
        pane:tab():get_pane_direction(direction).activate()
    elseif basename(hx_pane:get_foreground_process_name()) == "hx" then
        wezterm.log_info('process = hx')
        local action = act.SendString(':open ' .. filename .. '\r')
        window:perform_action(action, hx_pane);
        -- local zoom_action = wezterm.action.SendString(':sh wezterm cli zoom-pane\r\n')
        -- window:perform_action(zoom_action, hx_pane);
        hx_pane:activate()
    else
        local action = act.SendString('hx ' .. filename .. '\r')
        wezterm.log_info('action: ' .. action)
        window:perform_action(action, hx_pane);
        hx_pane:activate()
    end
    -- prevent the default action from opening in a browser
    return false
end

function M.apply_to_config(config, opts)
    if not opts then
        opts = {}
    end
    local key = opts.key or "s"
    local mods = opts.mods or "CMD|SHIFT"
    local text_extensions = opts.text_extensions or {
        md = true,
        c = true,
        go = true,
        scm = true,
        rkt = true,
        rs = true,
        java = true,
    }
    local patterns = opts.patterns or {
        'https?://\\S+',
        '^/[^/\r\n]+(?:/[^/\r\n]+)*:\\d+:\\d+',
        '[^\\s]+\\.rs:\\d+:\\d+',
        'rustc --explain E\\d+',
        '[^\\s]+\\.go:\\d+',
        '[^\\s]+\\.go:\\d+:\\d+',
        '[^\\s]+\\.java:\\[\\d+,\\d+\\]',
        '[^{]*{.*}',
    }

    config.keys = config.keys or {}
    table.insert(config.keys, {
        key = key,
        mods = mods,
        action = act.QuickSelectArgs {
            label = 'open url',
            patterns = patterns,
            action = wezterm.action_callback(function(window, pane)
                local selection = window:get_selection_text_for_pane(pane)
                wezterm.log_info('opening: ' .. selection)
                if startswith(selection, "http") then
                    wezterm.open_with(selection)
                elseif startswith(selection, "rustc --explain") then
                    local code = selection:match("(%S+)$")
                    window:perform_action(act.SplitPane {
                        direction = 'Right',
                        command = {
                            args = {
                                '/bin/sh', '-c',
                                'rustc --explain ' .. code .. ' | mdcat -p',
                            }
                        }
                    }, pane)
                elseif selection:match('[^{]*{.*}') then
                    local json = selection:match("{.*}")
                    local cmd = "echo '" .. json .. "' | jq -C . | less -R"
                    window:perform_action(act.SplitPane {
                        direction = 'Right',
                        command = { args = { '/bin/sh', '-c', cmd } }
                    }, pane)
                else
                    local file, line = selection:match('([^:%s]+%.java):%[(%d+),%d+%]')
                    if file and line then
                        selection = "$EDITOR:" .. file .. ":" .. line
                    else
                        selection = "$EDITOR:" .. selection
                    end
                    return M.Open_with_hx(window, pane, selection, text_extensions)
                end
            end)
        }
    })
end

return M
