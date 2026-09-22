local M = {}

M.setup = function(opts)
    -- stylua: ignore start
    if opts.csharp.enabled then require("sonarqube.csharp").setup(opts.csharp) end
    if opts.go.enabled then require("sonarqube.go").setup(opts.go) end
    if opts.html.enabled then require("sonarqube.html").setup(opts.html) end
    if opts.iac.enabled then require("sonarqube.iac").setup(opts.iac) end
    if opts.java.enabled then require("sonarqube.java").setup(opts.java) end
    if opts.javascript.enabled then require("sonarqube.javascript").setup(opts.javascript) end
    if opts.php.enabled then require("sonarqube.php").setup(opts.php) end
    if opts.python.enabled then require("sonarqube.python").setup(opts.python) end
    if opts.text.enabled then require("sonarqube.text").setup(opts.text) end
    if opts.xml.enabled then require("sonarqube.xml").setup(opts.xml) end
    -- stylua: ignore end

    local rules = require("sonarqube.rules")
    rules.setup(opts.rules)

    local server = require("sonarqube.lsp.server")
    server.setup(opts.lsp)

    -- Resolve connected mode configuration
    local connected = require("sonarqube.connected")
    local connected_config = nil

    vim.api.nvim_create_autocmd("FileType", {
        pattern = server.filetypes,
        callback = function(opt)
            local client = vim.lsp.get_clients({ name = "sonarqube" })
            if #client > 0 then
                vim.lsp.buf_attach_client(opt.buf, client[1].id)
                return
            end

            local root = vim.fs.dirname(vim.fs.find(server.root_files, { upward = true })[1])
                or vim.fn.getcwd()

            -- Resolve connected mode now that we have the project root
            connected_config = connected.resolve_config(opts.connected_mode, root)
            if connected_config then
                server.configure_connected_mode(connected_config)
            end

            local cfg = {
                name = "sonarqube",
                cmd = opts.lsp.cmd,
                commands = server.commands,
                root_dir = root,
                capabilities = opts.lsp.capabilities,
                filetypes = server.filetypes,
                init_options = server.init_options,
                handlers = server.handlers,
                settings = server.settings,
                autostart = true,
                on_attach = function(lsp_client)
                    server.did_change_configuration(lsp_client)

                    -- If connected mode is configured, notify the LS about bindings
                    if connected_config then
                        vim.defer_fn(function()
                            server.notify_binding()
                        end, 1000)
                    end
                end,
            }

            vim.lsp.start(cfg, {
                bufnr = opt.buf,
                silent = true,
            })

            vim.api.nvim_create_user_command("SonarQubeListAllRules", rules.list_all_rules, {})

            -- Connected mode commands
            vim.api.nvim_create_user_command("SonarQubeConnectedModeStatus", function()
                local conn = require("sonarqube.connected")
                local display = conn.get_display_config()
                if not display then
                    vim.notify("SonarQube: Connected mode is not configured", vim.log.levels.INFO)
                    return
                end

                local lines = {
                    "SonarQube Connected Mode Status",
                    "================================",
                    "State:         " .. conn.state,
                    "Server URL:    " .. display.server_url,
                    "Project Key:   " .. display.project_key,
                    "Connection ID: " .. display.connection_id,
                    "Token:         " .. display.token,
                }
                vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
            end, {})

            vim.api.nvim_create_user_command("SonarQubeCheckConnection", function()
                local conn = require("sonarqube.connected")
                local cfg_resolved = conn.get_config()
                if not cfg_resolved then
                    vim.notify("SonarQube: Connected mode is not configured", vim.log.levels.WARN)
                    return
                end

                local lsp_client = vim.lsp.get_clients({ name = "sonarqube" })[1]
                if not lsp_client then
                    vim.notify("SonarQube: LSP client is not running", vim.log.levels.ERROR)
                    return
                end

                vim.notify("SonarQube: Checking connection...", vim.log.levels.INFO)
                lsp_client.request("sonarlint/checkConnection", {
                    connectionId = cfg_resolved.connection_id,
                }, function(err, result)
                    if err then
                        vim.notify(
                            "SonarQube: Connection check failed - " .. tostring(err),
                            vim.log.levels.ERROR
                        )
                        return
                    end
                    if result and result.success then
                        conn.state = "connected"
                        vim.notify("SonarQube: Connection successful ✓", vim.log.levels.INFO)
                    else
                        conn.state = "disconnected"
                        local reason = (result and result.reason) or "Unknown error"
                        vim.notify(
                            "SonarQube: Connection failed - " .. reason,
                            vim.log.levels.ERROR
                        )
                    end
                end)
            end, {})

            vim.api.nvim_create_user_command("SonarQubeUpdateBinding", function()
                local conn = require("sonarqube.connected")
                local cfg_resolved = conn.get_config()
                if not cfg_resolved then
                    vim.notify("SonarQube: Connected mode is not configured", vim.log.levels.WARN)
                    return
                end

                local lsp_client = vim.lsp.get_clients({ name = "sonarqube" })[1]
                if not lsp_client then
                    vim.notify("SonarQube: LSP client is not running", vim.log.levels.ERROR)
                    return
                end

                vim.notify("SonarQube: Updating binding...", vim.log.levels.INFO)

                -- Send updated settings with connection info
                server.notify_binding()

                -- Also trigger a re-analysis of the current buffer
                vim.defer_fn(function()
                    local bufnr = vim.api.nvim_get_current_buf()
                    local uri = vim.uri_from_bufnr(bufnr)

                    -- Force the LS to re-analyze by simulating a didChange
                    lsp_client.notify("textDocument/didClose", {
                        textDocument = { uri = uri },
                    })
                    vim.defer_fn(function()
                        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                        lsp_client.notify("textDocument/didOpen", {
                            textDocument = {
                                uri = uri,
                                languageId = vim.bo[bufnr].filetype,
                                version = 0,
                                text = table.concat(lines, "\n"),
                            },
                        })
                        vim.notify(
                            "SonarQube: Binding updated, re-analysis triggered ✓",
                            vim.log.levels.INFO
                        )
                    end, 500)
                end, 1000)
            end, {})

            vim.api.nvim_create_user_command("SonarQubeRestart", function()
                local lsp_client = vim.lsp.get_clients({ name = "sonarqube" })[1]
                if not lsp_client then
                    vim.notify("SonarQube: LSP client is not running", vim.log.levels.WARN)
                    return
                end

                vim.notify("SonarQube: Restarting...", vim.log.levels.INFO)

                -- Stop the client
                lsp_client.stop(true)

                -- Wait for the client to fully shut down, then restart
                vim.defer_fn(function()
                    -- Re-resolve connected mode config
                    local conn = require("sonarqube.connected")
                    conn.state = "unknown"
                    conn._resolved = nil

                    local restart_root = vim.fs.dirname(
                        vim.fs.find(server.root_files, { upward = true })[1]
                    ) or vim.fn.getcwd()

                    connected_config = connected.resolve_config(opts.connected_mode, restart_root)
                    if connected_config then
                        server.configure_connected_mode(connected_config)
                    end

                    local restart_cfg = {
                        name = "sonarqube",
                        cmd = opts.lsp.cmd,
                        commands = server.commands,
                        root_dir = restart_root,
                        capabilities = opts.lsp.capabilities,
                        filetypes = server.filetypes,
                        init_options = server.init_options,
                        handlers = server.handlers,
                        settings = server.settings,
                        autostart = true,
                        on_attach = function(new_client)
                            server.did_change_configuration(new_client)
                            if connected_config then
                                vim.defer_fn(function()
                                    server.notify_binding()
                                end, 1000)
                            end
                        end,
                    }

                    vim.lsp.start(restart_cfg, {
                        bufnr = vim.api.nvim_get_current_buf(),
                        silent = true,
                    })

                    vim.notify("SonarQube: Restarted ✓", vim.log.levels.INFO)
                end, 1000)
            end, {})
        end,
    })
end

return M
