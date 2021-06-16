local _M = {}


local semaphore = require("ngx.semaphore")
local ws_server = require("resty.websocket.server")
local ssl = require("ngx.ssl")
local ocsp = require("ngx.ocsp")
local http = require("resty.http")
local cjson = require("cjson.safe")
local declarative = require("kong.db.declarative")
local utils = require("kong.tools.utils")
local constants = require("kong.constants")
local openssl_x509 = require("resty.openssl.x509")
local string = string
local setmetatable = setmetatable
local type = type
local math = math
local pcall = pcall
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local ngx = ngx
local ngx_log = ngx.log
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local kong = kong
local ngx_exit = ngx.exit
local exiting = ngx.worker.exiting
local ngx_time = ngx.time
local ngx_now = ngx.now
local ngx_var = ngx.var
local table_insert = table.insert
local table_remove = table.remove
local table_concat = table.concat
local deflate_gzip = utils.deflate_gzip


local KONG_VERSION = kong.version
local ngx_DEBUG = ngx.DEBUG
local ngx_INFO = ngx.INFO
local ngx_NOTICE = ngx.NOTICE
local ngx_WARN = ngx.WARN
local ngx_ERR = ngx.ERR
local ngx_OK = ngx.OK
local ngx_CLOSE = ngx.HTTP_CLOSE
local MAX_PAYLOAD = constants.CLUSTERING_MAX_PAYLOAD
local WS_OPTS = {
  timeout = constants.CLUSTERING_TIMEOUT,
  max_payload_len = MAX_PAYLOAD,
}
local PING_INTERVAL = constants.CLUSTERING_PING_INTERVAL
local PING_WAIT = PING_INTERVAL * 1.5
local OCSP_TIMEOUT = constants.CLUSTERING_OCSP_TIMEOUT
local CLUSTERING_SYNC_STATUS = constants.CLUSTERING_SYNC_STATUS
local MAJOR_MINOR_PATTERN = "^(%d+)%.(%d+)%.%d+"


local function extract_major_minor(version)
  if type(version) ~= "string" then
    return nil, nil
  end

  local major, minor = version:match(MAJOR_MINOR_PATTERN)
  if not major then
    return nil, nil
  end

  major = tonumber(major, 10)
  minor = tonumber(minor, 10)

  return major, minor
end


local function plugins_list_to_map(plugins_list)
  local versions = {}
  for _, plugin in ipairs(plugins_list) do
    local name = plugin.name
    local version = plugin.version
    local major, minor = extract_major_minor(plugin.version)

    if major and minor then
      versions[name] = {
        major   = major,
        minor   = minor,
        version = version,
      }

    else
      versions[name] = {}
    end
  end
  return versions
end


local function is_timeout(err)
  return err and string.sub(err, -7) == "timeout"
end


function _M.new(parent)
  local self = {
    clients = setmetatable({}, { __mode = "k", })
  }

  return setmetatable(self, {
    __index = function(tab, key)
      return _M[key] or parent[key]
    end,
  })
end


function _M:export_deflated_reconfigure_payload()
  local config_table, err = declarative.export_config()
  if not config_table then
    return nil, err
  end

  self.plugins_configured = {}
  if config_table.plugins then
    for _, plugin in pairs(config_table.plugins) do
      self.plugins_configured[plugin.name] = true
    end
  end

  local payload, err = cjson_encode({
    type = "reconfigure",
    timestamp = ngx_now(),
    config_table = config_table,
  })
  if not payload then
    return nil, err
  end

  payload, err = deflate_gzip(payload)
  if not payload then
    return nil, err
  end

  self.deflated_reconfigure_payload = payload

  return payload
end


function _M:push_config()
  local payload, err = self:export_deflated_reconfigure_payload()
  if not payload then
    ngx_log(ngx_ERR, "unable to export config from database: " .. err)
    return
  end

  local n = 0
  for _, queue in pairs(self.clients) do
    table_insert(queue, payload)
    queue.post()
    n = n + 1
  end

  ngx_log(ngx_DEBUG, "config pushed to ", n, " clients")
end


function _M:validate_shared_cert()
  local cert = ngx_var.ssl_client_raw_cert

  if not cert then
    return nil, "data plane failed to present client certificate during handshake"
  end

  local err
  cert, err = openssl_x509.new(cert, "PEM")
  if not cert then
    return nil, "unable to load data plane client certificate during handshake: " .. err
  end

  local digest, err = cert:digest("sha256")
  if not digest then
    return nil, "unable to retrieve data plane client certificate digest during handshake: " .. err
  end

  if digest ~= self.cert_digest then
    return nil, "data plane presented incorrect client certificate during handshake (expected: " ..
                self.cert_digest .. ", got: " .. digest .. ")"
  end

  return true
end


local check_for_revocation_status
do
  local get_full_client_certificate_chain = require("resty.kong.tls").get_full_client_certificate_chain
  check_for_revocation_status = function()
    local cert, err = get_full_client_certificate_chain()
    if not cert then
      return nil, err
    end

    local der_cert
    der_cert, err = ssl.cert_pem_to_der(cert)
    if not der_cert then
      return nil, "failed to convert certificate chain from PEM to DER: " .. err
    end

    local ocsp_url
    ocsp_url, err = ocsp.get_ocsp_responder_from_der_chain(der_cert)
    if not ocsp_url then
      return nil, err or "OCSP responder endpoint can not be determined, " ..
                         "maybe the client certificate is missing the " ..
                         "required extensions"
    end

    local ocsp_req
    ocsp_req, err = ocsp.create_ocsp_request(der_cert)
    if not ocsp_req then
      return nil, "failed to create OCSP request: " .. err
    end

    local c = http.new()
    local res
    res, err = c:request_uri(ocsp_url, {
      headers = {
        ["Content-Type"] = "application/ocsp-request"
      },
      timeout = OCSP_TIMEOUT,
      method = "POST",
      body = ocsp_req,
    })

    if not res then
      return nil, "failed sending request to OCSP responder: " .. tostring(err)
    end
    if res.status ~= 200 then
      return nil, "OCSP responder returns bad HTTP status code: " .. res.status
    end

    local ocsp_resp = res.body
    if not ocsp_resp or #ocsp_resp == 0 then
      return nil, "unexpected response from OCSP responder: empty body"
    end

    res, err = ocsp.validate_ocsp_response(ocsp_resp, der_cert)
    if not res then
      return false, "failed to validate OCSP response: " .. err
    end

    return true
  end
end


function _M:check_version_compatibility(dp_version, dp_plugin_map, dp)
  local major_cp, minor_cp = extract_major_minor(KONG_VERSION)
  local major_dp, minor_dp = extract_major_minor(dp_version)

  if not major_cp then
    return nil, "data plane version " .. dp_version .. " is incompatible with control plane version",
                CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE
  end

  if not major_dp then
    return nil, "data plane version is incompatible with control plane version " ..
                KONG_VERSION .. " (" .. major_cp .. ".x.y are accepted)",
                CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE
  end

  if major_cp ~= major_dp then
    return nil, "data plane version " .. dp_version ..
                " is incompatible with control plane version " ..
                KONG_VERSION .. " (" .. major_cp .. ".x.y are accepted)",
                CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE
  end

  if minor_cp ~= minor_dp then
    local difference = math.abs(minor_cp - minor_dp)
    if difference > 0 then
      local msg = "data plane minor version " .. dp_version ..
                  " is different to control plane minor version " ..
                  KONG_VERSION

      if difference == 1 then
        ngx_log(ngx_DEBUG, msg, dp)
      elseif difference == 2 then
        ngx_log(ngx_INFO, msg, dp)
      elseif difference == 3 then
        ngx_log(ngx_NOTICE, msg, dp)
      else
        ngx_log(ngx_WARN, msg, dp)
      end
    end
  end

  for _, plugin in ipairs(self.plugins_list) do
    local name = plugin.name
    local cp_plugin = self.plugins_map[name]
    local dp_plugin = dp_plugin_map[name]

    if not dp_plugin then
      if cp_plugin.version then
        ngx_log(ngx_WARN, name, " plugin ", cp_plugin.version, " is missing from data plane", dp)
      else
        ngx_log(ngx_WARN, name, " plugin is missing from data plane", dp)
      end

    else
      if cp_plugin.version and dp_plugin.version then
        local msg = "data plane " .. name .. " plugin version " .. dp_plugin.version ..
                    " is different to control plane plugin version " .. cp_plugin.version

        if cp_plugin.major ~= dp_plugin.major then
          ngx_log(ngx_WARN, msg, cp_plugin.version, dp)

        else
          local difference = math.abs(cp_plugin.minor - dp_plugin.minor)
          if difference > 0 then
            if difference == 1 then
              ngx_log(ngx_DEBUG, msg, dp)
            elseif difference == 2 then
              ngx_log(ngx_INFO, msg, dp)
            else
              ngx_log(ngx_NOTICE, msg, dp)
            end
          end
        end

      elseif dp_plugin.version then
        ngx_log(ngx_NOTICE, "data plane ", name, " plugin version ", dp_plugin.version,
                            " has unspecified version on control plane", dp)

      elseif cp_plugin.version then
        ngx_log(ngx_NOTICE, "data plane ", name, " plugin version is unspecified, ",
                            "and is different to control plane plugin version ",
                            cp_plugin.version, dp)
      end
    end
  end

  return true, nil, CLUSTERING_SYNC_STATUS.NORMAL
end


function _M:check_configuration_compatibility(dp_plugin_map)
  for _, plugin in ipairs(self.plugins_list) do
    if self.plugins_configured[plugin.name] then
      local name = plugin.name
      local cp_plugin = self.plugins_map[name]
      local dp_plugin = dp_plugin_map[name]

      if not dp_plugin then
        if cp_plugin.version then
          return nil, "configured " .. name .. " plugin " .. cp_plugin.version ..
                      " is missing from data plane", CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE
        end

        return nil, "configured " .. name .. " plugin is missing from data plane",
               CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE
      end

      if cp_plugin.version and dp_plugin.version then
        local msg = "configured data plane " .. name .. " plugin version " .. dp_plugin.version ..
                    " is different to control plane plugin version " .. cp_plugin.version

        if cp_plugin.major ~= dp_plugin.major then
          return nil, msg, CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE
        end
      end
    end
  end

  -- TODO: DAOs are not checked in any way at the moment. For example if plugin introduces a new DAO in
  --       minor release and it has entities, that will most likely fail on data plane side, but is not
  --       checked here.

  return true, nil, CLUSTERING_SYNC_STATUS.NORMAL
end

function _M:handle_cp_websocket()
  local dp_id = ngx_var.arg_node_id
  local dp_hostname = ngx_var.arg_node_hostname
  local dp_ip = ngx_var.remote_addr
  local dp_version = ngx_var.arg_node_version

  local dp = {}
  if type(dp_id) == "string" then
    table_insert(dp, "id: " .. dp_id)
  end

  if type(dp_hostname) == "string" then
    table_insert(dp, "host: " .. dp_hostname)
  end

  if type(dp_ip) == "string" then
    table_insert(dp, "ip: " .. dp_ip)
  end

  if type(dp_version) == "string" then
    table_insert(dp, "version: " .. dp_version)
  end

  if #dp > 0 then
    dp = " [" .. table_concat(dp, ", ") .. "]"
  else
    dp = ""
  end

  local ok, err

  -- use mutual TLS authentication
  if self.conf.cluster_mtls == "shared" then
    ok, err = self:validate_shared_cert()

  elseif self.conf.cluster_ocsp ~= "off" then
    ok, err = check_for_revocation_status()
    if ok == false then
      err = "data plane client certificate was revoked: " ..  err

    elseif not ok then
      if self.conf.cluster_ocsp == "on" then
        err = "data plane client certificate revocation check failed: " .. err

      else
        ngx_log(ngx_WARN, "data plane client certificate revocation check failed: ", err, dp)
        err = nil
      end
    end
  end

  if err then
    ngx_log(ngx_ERR, err, dp)
    return ngx_exit(ngx_CLOSE)
  end

  if not dp_id then
    ngx_log(ngx_WARN, "data plane didn't pass the id", dp)
    ngx_exit(400)
  end

  if not dp_version then
    ngx_log(ngx_WARN, "data plane didn't pass the version", dp)
    ngx_exit(400)
  end

  local wb, err = ws_server:new(WS_OPTS)
  if not wb then
    ngx_log(ngx_ERR, "failed to perform server side websocket handshake: ", err, dp)
    return ngx_exit(ngx_CLOSE)
  end

  -- connection established
  -- receive basic info
  local data, typ
  data, typ, err = wb:recv_frame()
  if err then
    err = "failed to receive websocket basic info frame: " .. err

  elseif typ == "binary" then
    if not data then
      err = "failed to receive websocket basic info data"

    else
      data, err = cjson_decode(data)
      if type(data) ~= "table" then
        if err then
          err = "failed to decode websocket basic info data: " .. err
        else
          err = "failed to decode websocket basic info data"
        end

      else
        if data.type ~= "basic_info" then
          err =  "invalid basic info data type: " .. (data.type  or "unknown")

        else
          if type(data.plugins) ~= "table" then
            err =  "missing plugins in basic info data"
          end
        end
      end
    end
  end

  if err then
    ngx_log(ngx_ERR, err, dp)
    wb:send_close()
    return ngx_exit(ngx_CLOSE)
  end

  local dp_plugins_map = plugins_list_to_map(data.plugins)
  local config_hash = "unknown"
  local last_seen = ngx_time()
  local sync_status = CLUSTERING_SYNC_STATUS.UNKNOWN
  local purge_delay = self.conf.cluster_data_plane_purge_delay
  local update_sync_status = function()
    last_seen = ngx_time()
    ok, err = kong.db.clustering_data_planes:upsert({ id = dp_id, }, {
      last_seen = last_seen,
      config_hash = config_hash ~= "" and config_hash or nil,
      hostname = dp_hostname,
      ip = dp_ip,
      version = dp_version,
      sync_status = sync_status, -- TODO: import may have been failed though
    }, { ttl = purge_delay })
    if not ok then
      ngx_log(ngx_ERR, "unable to update clustering data plane status: ", err, dp)
    end
  end

  ok, err, sync_status = self:check_version_compatibility(dp_version, dp_plugins_map, dp)
  if not ok then
    update_sync_status()
    ngx_log(ngx_ERR, err, dp)
    wb:send_close()
    return ngx_exit(ngx_CLOSE)
  end

  ngx.log(ngx.DEBUG, "data plane connected", dp)

  local queue
  do
    local queue_semaphore = semaphore.new()
    queue = {
      wait = function(...)
        return queue_semaphore:wait(...)
      end,
      post = function(...)
        return queue_semaphore:post(...)
      end
    }
  end

  self.clients[wb] = queue

  if not self.deflated_reconfigure_payload then
    ok, err = self:export_deflated_reconfigure_payload()
  end

  if self.deflated_reconfigure_payload then
    table_insert(queue, self.deflated_reconfigure_payload)
    queue.post()

  else
    ngx_log(ngx_ERR, "unable to send initial configuration to data plane: ", err, dp)
  end

  -- how control plane connection management works:
  -- two threads are spawned, when any of these threads exits,
  -- it means a fatal error has occurred on the connection,
  -- and the other thread is also killed
  --
  -- * read_thread: it is the only thread that receives websocket frames from the
  --                data plane and records the current data plane status in the
  --                database, and is also responsible for handling timeout detection
  -- * write_thread: it is the only thread that sends websocket frames to the data plane
  --                 by grabbing any messages currently in the send queue and
  --                 send them to the data plane in a FIFO order. Notice that the
  --                 PONG frames are also sent by this thread after they are
  --                 queued by the read_thread

  local read_thread = ngx.thread.spawn(function()
    while not exiting() do
      local data, typ, err = wb:recv_frame()

      if exiting() then
        return
      end

      if err then
        if not is_timeout(err) then
          return nil, err
        end

        local waited = ngx_time() - last_seen
        if waited > PING_WAIT then
          return nil, "did not receive ping frame from data plane within " ..
            PING_WAIT .. " seconds"
        end

      else
        if typ == "close" then
          return
        end

        if not data then
          return nil, "did not receive ping frame from data plane"
        end

        -- dps only send pings
        if typ ~= "ping" then
          return nil, "invalid websocket frame received from data plane: " .. typ
        end

        config_hash = data

        -- queue PONG to avoid races
        table_insert(queue, "PONG")
        queue.post()

        update_sync_status()
      end
    end
  end)

  local write_thread = ngx.thread.spawn(function()
    while not exiting() do
      local ok, err = queue.wait(5)
      if exiting() then
        return
      end
      if ok then
        local payload = table_remove(queue, 1)
        if not payload then
          return nil, "config queue can not be empty after semaphore returns"
        end

        if payload == "PONG" then
          local _, err = wb:send_pong()
          if err then
            if not is_timeout(err) then
              return nil, "failed to send PONG back to data plane: " .. err
            end

            ngx_log(ngx_NOTICE, "failed to send PONG back to data plane: ", err, dp)

          else
            ngx_log(ngx_DEBUG, "sent PONG packet to data plane", dp)
          end

        else
          ok, err, sync_status = self:check_configuration_compatibility(dp_plugins_map)
          if ok then
            -- config update
            local _, err = wb:send_binary(payload)
            if err then
              if not is_timeout(err) then
                return nil, "unable to send updated configuration to data plane: " .. err
              end

              ngx_log(ngx_NOTICE, "unable to send updated configuration to data plane: ", err, dp)

            else
              ngx_log(ngx_DEBUG, "sent config update to data plane", dp)
            end

          else
            ngx_log(ngx_WARN, "unable to send updated configuration to data plane: ", err, dp)
          end
        end

      elseif err ~= "timeout" then
        return nil, "semaphore wait error: " .. err
      end
    end
  end)

  local perr
  ok, err, perr = ngx.thread.wait(write_thread, read_thread)

  ngx.thread.kill(write_thread)
  ngx.thread.kill(read_thread)

  wb:send_close()

  --TODO: should we update disconnect data plane status?
  --sync_status = CLUSTERING_SYNC_STATUS.UNKNOWN
  --update_sync_status()

  if not ok then
    ngx_log(ngx_ERR, err, dp)
    return ngx_exit(ngx_ERR)
  end

  if perr then
    ngx_log(ngx_ERR, perr, dp)
    return ngx_exit(ngx_ERR)
  end

  return ngx_exit(ngx_OK)
end


local function push_config_loop(premature, self, push_config_semaphore, delay)
  if premature then
    return
  end

  local _, err = self:export_deflated_reconfigure_payload()
  if err then
    ngx_log(ngx_ERR, "unable to export initial config from database: " .. err)
  end

  while not exiting() do
    local ok, err = push_config_semaphore:wait(1)
    if exiting() then
      return
    end
    if ok then
      ok, err = pcall(self.push_config, self)
      if ok then
        local sleep_left = delay
        while sleep_left > 0 do
          if sleep_left <= 1 then
            ngx.sleep(sleep_left)
            break
          end

          ngx.sleep(1)

          if exiting() then
            return
          end

          sleep_left = sleep_left - 1
        end

      else
        ngx_log(ngx_ERR, "export and pushing config failed: ", err)
      end

    elseif err ~= "timeout" then
      ngx_log(ngx_ERR, "semaphore wait error: ", err)
    end
  end
end


function _M:init_worker()
  -- ROLE = "control_plane"

  self.plugins_map = plugins_list_to_map(self.plugins_list)

  self.deflated_reconfigure_payload = nil
  self.plugins_configured = {}
  self.plugin_versions = {}

  for i = 1, #self.plugins_list do
    local plugin = self.plugins_list[i]
    self.plugin_versions[plugin.name] = plugin.version
  end

  local push_config_semaphore = semaphore.new()

  -- Sends "clustering", "push_config" to all workers in the same node, including self
  local function post_push_config_event()
    local res, err = kong.worker_events.post("clustering", "push_config")
    if not res then
      ngx_log(ngx_ERR, "unable to broadcast event: ", err)
    end
  end

  -- Handles "clustering:push_config" cluster event
  local function handle_clustering_push_config_event(data)
    ngx_log(ngx_DEBUG, "received clustering:push_config event for ", data)
    post_push_config_event()
  end


  -- Handles "dao:crud" worker event and broadcasts "clustering:push_config" cluster event
  local function handle_dao_crud_event(data)
    if type(data) ~= "table" or data.schema == nil or data.schema.db_export == false then
      return
    end

    kong.cluster_events:broadcast("clustering:push_config", data.schema.name .. ":" .. data.operation)

    -- we have to re-broadcast event using `post` because the dao
    -- events were sent using `post_local` which means not all workers
    -- can receive it
    post_push_config_event()
  end

  -- The "clustering:push_config" cluster event gets inserted in the cluster when there's
  -- a crud change (like an insertion or deletion). Only one worker per kong node receives
  -- this callback. This makes such node post push_config events to all the cp workers on
  -- its node
  kong.cluster_events:subscribe("clustering:push_config", handle_clustering_push_config_event)

  -- The "dao:crud" event is triggered using post_local, which eventually generates an
  -- ""clustering:push_config" cluster event. It is assumed that the workers in the
  -- same node where the dao:crud event originated will "know" about the update mostly via
  -- changes in the cache shared dict. Since data planes don't use the cache, nodes in the same
  -- kong node where the event originated will need to be notified so they push config to
  -- their data planes
  kong.worker_events.register(handle_dao_crud_event, "dao:crud")

  -- When "clustering", "push_config" worker event is received by a worker,
  -- it loads and pushes the config to its the connected data planes
  kong.worker_events.register(function(_)
    if push_config_semaphore:count() <= 0 then
      -- the following line always executes immediately after the `if` check
      -- because `:count` will never yield, end result is that the semaphore
      -- count is guaranteed to not exceed 1
      push_config_semaphore:post()
    end
  end, "clustering", "push_config")

  ngx.timer.at(0, push_config_loop, self, push_config_semaphore,
               self.conf.db_update_frequency)
end


return _M
