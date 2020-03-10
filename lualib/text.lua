local text = {
    regex = {
        host_port = "^([%w%.%-]+):?(%d*)$",
        http_host_port = "^(https?://)([%w%.%-]+):?(%d*).*$",
        websocket = "^(wss?)://([^/]+)(.*)$",
        tpl_full_name = "^[%l%d_]+_v_[%d_]+$",
        version = "^[%d%l]+$",
        valid_cmd = "^[%g%s]+$",
        cmd_with_table_arg = "(%g+)%s+(%g+)%s+({[%s%g]*})",
        cmd_with_arg = "(%g+)%s+(%g+)%s*(%g*)"
    },
    app = {
        unknown_cmd = "unknown command",
        no_conf_handler = "no conf handler",
        no_data_handler = "no data handler",
        conf_fail = "configure failed",
        pack_fail = "pack failed"
    },
    sysmgr = {
        unknown_cmd = "unknown command",
        config_load_suc = "Config loaded",
        config_load_fail = "Config load failed",
        config_update_suc = "Config updated",
        config_update_fail = "Config update failed",
        read_only = "read-only config",
        invalid_auth = "invalid SW repository uri or auth",
        dup_tpl = "Duplicate APP template",
        dup_app = "Duplicate APP",
        download_fail = "SW download failed",
        unzip_fail = "SW unzip failed",
        invalid_meta = "invalid SW metadata",
        invalid_app = "invalid APP",
        tpl_replace = "APP template to be replaced",
        core_replace = "core to be replaced",
        install_fail = "new system install failed",
        configure_fail = "new system configure failed",
        sys_exit = "system exited",
    },
    appmgr = {
        unknown_cmd = "unknown command",
        invalid_arg = "invalid argument",
        invalid_tpl = "invalid APP template",
        dup_tpl_install = "another install in progress",
        invalid_version = "invalid system version",
        dup_upgrade_version = "system version same as current",
        invalid_repo = "SW repository not set",
        unknown_pipe = "unknown PIPE",
        pipe_load_suc = "PIPE loaded",
        pipe_running = "PIPE is running",
        pipe_stopped = "PIPE stopped",
        pipe_start_suc = "PIPE started",
        pipe_stop_suc = "PIPE stopped",
        unknown_app = "unknown APP",
        load_suc = "APP loaded",
        load_fail = "APP load failed",
        sysapp_remove = "System APP can't be removed",
        app_exit = "APP exited",
        app_in_use = "APP used by PIPE",
        loop = "endless loop detected",
        locked = "system in maintenance",
        cleaned = "all configuration cleaned"
    },
    gateway = {
        unknown_request = "unknown device or cmd",
        invalid_dev = "invalid DEVICE name or description",
        dup_dev = "DEVICE name already used",
        dev_registered = "new DEVICE registered",
        dev_unregistered = "DEVICE unregistered",
        unknown_app = "unknown APP",
        invalid_cmd = "invalid CMD name or description",
        dup_cmd = "CMD name already used",
        cmd_registered = "new CMD registered",
        no_conf = "not configured",
    },
    console = {
        prompt = ">> ",
        sep = "",
        welcome = "Welcome to IoTEdge",
        tip = "'help' for command list",
        not_auth = "Not authorized",
        max = "Max connection reached",
        username = "Username: ",
        password = "Password: "
    },
    mqtt = {
        invalid_req = "invalid request received",
        invalid_post = "invalid post received",
        dup_req = "duplicated request received",
        pack_fail = "pack failed",
        unpack_fail = "unpack failed",
        unknown_dev = "unknown device",
        no_conf = "not configured",
    }
}

return setmetatable({}, {
  __index = text,
  __newindex = function(t, k, v)
                 error("Attempt to modify read-only table")
               end,
  __metatable = false
})
