local M = {}

--- Connection state: "unknown", "connected", or "disconnected"
M.state = "unknown"

--- Resolved connected mode configuration (cached after first resolve)
M._resolved = nil

--- Read and parse .sonarlint/connectedMode.json from the project root.
--- @param root string|nil The project root directory
--- @return table|nil Parsed JSON table, or nil if not found/invalid
local function read_project_file(root)
    if not root then
        return nil
    end

    local filepath = root .. "/.sonarlint/connectedMode.json"
    local stat = vim.loop.fs_stat(filepath)
    if not stat then
        return nil
    end

    local fd = vim.loop.fs_open(filepath, "r", 438)
    if not fd then
        return nil
    end

    local content = vim.loop.fs_read(fd, stat.size, 0)
    vim.loop.fs_close(fd)

    if not content or content == "" then
        return nil
    end

    local ok, parsed = pcall(vim.fn.json_decode, content)
    if not ok or type(parsed) ~= "table" then
        vim.notify(
            "SonarQube: Failed to parse .sonarlint/connectedMode.json, skipping project file",
            vim.log.levels.WARN
        )
        return nil
    end

    return parsed
end

--- Resolve connected mode configuration from multiple sources.
--- Priority: .sonarlint/connectedMode.json > plugin setup() config (projects match > top-level)
--- Token is always read from SONARQUBE_TOKEN environment variable.
--- @param plugin_config table The connected_mode table from plugin setup()
--- @param root string|nil The project root directory
--- @return table|nil Resolved config table { server_url, project_key, connection_id, token } or nil
function M.resolve_config(plugin_config, root)
    local project_file = read_project_file(root)

    -- Resolve each field with project file taking precedence
    local server_url = nil
    local project_key = nil
    local connection_id = "default"

    if project_file then
        server_url = project_file.serverUrl or project_file.server_url
        project_key = project_file.projectKey or project_file.project_key
        if project_file.connectionId or project_file.connection_id then
            connection_id = project_file.connectionId or project_file.connection_id
        end
    end

    -- Fall back to plugin config for any missing fields
    if plugin_config then
        -- Check if there's a per-project entry matching the current root
        local matched_project = nil
        if plugin_config.projects and root then
            -- Normalize root path (remove trailing slash)
            local norm_root = root:gsub("/$", "")
            for dir, project_cfg in pairs(plugin_config.projects) do
                local norm_dir = vim.fn.expand(dir):gsub("/$", "")
                if norm_root == norm_dir then
                    matched_project = project_cfg
                    break
                end
            end
        end

        if matched_project then
            server_url = server_url or matched_project.server_url
            project_key = project_key or matched_project.project_key
            if matched_project.connection_id and connection_id == "default" then
                connection_id = matched_project.connection_id
            end
        end

        -- Fall back to top-level config
        server_url = server_url or plugin_config.server_url
        project_key = project_key or plugin_config.project_key
        if plugin_config.connection_id and connection_id == "default" then
            connection_id = plugin_config.connection_id
        end
    end

    -- If essential fields are missing, connected mode is not configured
    if not server_url or not project_key then
        return nil
    end

    -- Read token from environment variable
    local token = os.getenv("SONARQUBE_TOKEN")
    if not token or token == "" then
        vim.notify(
            "SonarQube: SONARQUBE_TOKEN environment variable is not set. "
                .. "Connected mode requires a token to authenticate with the server.",
            vim.log.levels.WARN
        )
        return nil
    end

    local resolved = {
        server_url = server_url,
        project_key = project_key,
        connection_id = connection_id,
        token = token,
    }

    M._resolved = resolved
    return resolved
end

--- Get the cached resolved config (nil if not configured or not yet resolved)
--- @return table|nil
function M.get_config()
    return M._resolved
end

--- Get a display-safe version of the resolved config (token redacted)
--- @return table|nil
function M.get_display_config()
    if not M._resolved then
        return nil
    end

    return {
        server_url = M._resolved.server_url,
        project_key = M._resolved.project_key,
        connection_id = M._resolved.connection_id,
        token = "***",
    }
end

return M
