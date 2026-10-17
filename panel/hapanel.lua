-- HAPanel services (loaded with lua-load in haproxy.cfg)
--   lua.dashboard : the page (/hapanel/), with the server name filled in
--   lua.live      : Server-Sent Events stream, one update per second (/hapanel/live)
--   lua.static    : PWA files (manifest with the server name, service worker, icons)
--   lua.settings  : save settings (POST /hapanel/settings)
--   lua.login     : sign-in page + POST handler (/hapanel/login)
--   lua.logout    : end the session server-side (POST /hapanel/logout)
--   lua.session_ok: fetch used by haproxy.cfg to gate every /hapanel/ request

-- Files are read once at startup (before chroot); reload HAProxy after editing them.
local DIR = "/etc/haproxy/hapanel/"
local function load(name)
  local f = io.open(DIR .. name, "rb")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local page = load("index.html") or "dashboard page missing"
local login_page = load("login.html") or "login page missing"

-- Runtime paths, relative to HAProxy's chroot (/var/lib/haproxy).
local SYS_FILE = "/hapanel/sys.json"            -- written by hapanel-collector
local NAME_FILE = "/hapanel/state/name"           -- written by lua.settings (dir owned by haproxy)
local DEFAULT_NAME = "HAPanel"
local MAX_NAME = 32
local STREAM_SECONDS = 120   -- browsers reconnect automatically (and land on a fresh process after reloads)

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local function server_name()
  local name = read_file(NAME_FILE)
  return (name and name ~= "") and name or DEFAULT_NAME
end

-- Escaping helpers
local function enc_str(s)
  return '"' .. (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end)) .. '"'
end

local function html_escape(s)
  return (s:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- App identity derived from the server name: renaming makes browsers treat it as a fresh app
-- (Android Chrome otherwise keeps the name it recorded at first install).
local function app_id(name)
  local h = 5381
  for i = 1, #name do h = (h * 33 + name:byte(i)) & 0xffffffff end
  return string.format("%08x", h)
end

-- Replace the __SERVER_NAME__ / __APP_ID__ placeholders (function replacement: no % pattern surprises)
local function fill(template, value, name)
  local id = app_id(name)
  return (template:gsub("__SERVER_NAME__", function() return value end):gsub("__APP_ID__", function() return id end))
end

local function send(applet, status, ctype, body, cache)
  applet:set_status(status)
  applet:add_header("content-type", ctype)
  applet:add_header("cache-control", cache or "no-store")
  applet:add_header("content-length", tostring(#body))
  applet:start_response()
  applet:send(body)
end

local STATIC = {
  ["/hapanel/manifest.webmanifest"] = { "manifest.webmanifest", "application/manifest+json" },
  ["/hapanel/sw.js"]                = { "sw.js", "text/javascript" },
  ["/hapanel/icon-192.png"]         = { "icon-192.png", "image/png" },
  ["/hapanel/icon-512.png"]         = { "icon-512.png", "image/png" },
  ["/hapanel/apple-touch-icon.png"] = { "apple-touch-icon.png", "image/png" },
}
for _, spec in pairs(STATIC) do spec.body = load(spec[1]) end

core.register_service("static", "http", function(applet)
  local spec = STATIC[applet.path]
  if not spec or not spec.body then return send(applet, 404, "text/plain", "not found\n") end
  if applet.path == "/hapanel/manifest.webmanifest" then
    -- enc_str adds quotes; the template already has them
    local name = server_name()
    return send(applet, 200, spec[2], fill(spec.body, enc_str(name):sub(2, -2), name), "no-store")
  end
  send(applet, 200, spec[2], spec.body, applet.path == "/hapanel/sw.js" and "no-cache" or "public, max-age=3600")
end)

-- ---------- Sessions ----------
-- Token = 32 random bytes (hex) in an HttpOnly cookie; only its SHA-256 is kept, in memory and in
-- SESSIONS_FILE so sessions survive reloads. Signing out deletes the entry: the cookie is dead everywhere.
local SESSION_COOKIE = "hapanel_session"
local SESSION_TTL = 14 * 86400
local SESSIONS_FILE = "/hapanel/state/sessions"                       -- after chroot
local SESSIONS_FILE_BOOT = "/var/lib/haproxy/hapanel/state/sessions"  -- at startup (before chroot)
local AUTH_FILE = "/hapanel/state/auth"                               -- "user v1 iterations salt HEXHASH"
local MAX_FAILS, LOCK_SECONDS = 5, 900
local urandom = io.open("/dev/urandom", "rb")                    -- opened before chroot, stays usable
local sessions = {}   -- sha256(token) -> { exp, created, ip }
local fails = {}      -- client ip -> { n, locked_until }

do
  local f = io.open(SESSIONS_FILE_BOOT, "r")
  if f then
    for line in f:lines() do
      local h, exp, created, ip = line:match("^(%x+) (%d+) (%d+) (%S*)$")
      if h and tonumber(exp) > os.time() then
        sessions[h] = { exp = tonumber(exp), created = tonumber(created), ip = ip }
      end
    end
    f:close()
  end
end

local function save_sessions()
  local t, tmp = os.time(), SESSIONS_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  for h, s in pairs(sessions) do
    if s.exp > t then f:write(string.format("%s %d %d %s\n", h, s.exp, s.created, s.ip)) else sessions[h] = nil end
  end
  f:close()
  os.rename(tmp, SESSIONS_FILE)
end

local function session_count()
  local t, n = os.time(), 0
  for _, s in pairs(sessions) do if s.exp > t then n = n + 1 end end
  return n
end

local function to_hex(bytes)
  return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function token_hash(conv, token)
  return conv:hex(conv:sha2(token, 256))
end

-- Returns the session key when the token is valid (and not expired)
local function session_valid(conv, token)
  if not token or not token:match("^%x+$") or #token ~= 64 then return nil end
  local h = token_hash(conv, token)
  local s = sessions[h]
  if s and s.exp > os.time() then return h end
  if s then sessions[h] = nil end
  return nil
end

local function get_cookie(header, name)
  for _, value in pairs(header or {}) do
    for k, v in value:gmatch("([^=;%s]+)=([^;]*)") do
      if k == name then return v end
    end
  end
end

core.register_fetches("session_ok", function(txn)
  return session_valid(txn.c, txn.f:req_cook(SESSION_COOKIE)) and "1" or "0"
end)

local function check_password(conv, user, pw)
  local line = read_file(AUTH_FILE)
  if not line then return false end
  local u, n, salt, want = line:match("^(%S+) v1 (%d+) (%x+) (%x+)")
  if not u then return false end
  local h = conv:hex(conv:sha2(salt .. pw, 256))
  for _ = 2, tonumber(n) do h = conv:hex(conv:sha2(h .. salt .. pw, 256)) end
  local diff = (#h == #want and user == u) and 0 or 1
  for i = 1, math.min(#h, #want) do if h:byte(i) ~= want:byte(i) then diff = 1 end end
  return diff == 0
end

local function urldecode(s)
  return (s:gsub("%+", " "):gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
end

local function parse_form(body)
  local t = {}
  for k, v in body:gmatch("([^&=]+)=([^&]*)") do t[urldecode(k)] = urldecode(v) end
  return t
end

local function csrf_ok(applet)
  local h = applet.headers["x-hapanel"]
  return h and h[0] == "1"
end

local function cookie_header(token, max_age)
  return string.format("%s=%s; Path=/hapanel/; Max-Age=%d; HttpOnly; Secure; SameSite=Lax", SESSION_COOKIE, token, max_age)
end

core.register_service("login", "http", function(applet)
  if applet.method == "GET" then
    if session_valid(applet.c, get_cookie(applet.headers["cookie"], SESSION_COOKIE)) then
      applet:set_status(302)
      applet:add_header("location", "/hapanel/")
      applet:add_header("content-length", "0")
      applet:start_response()
      return
    end
    local name = server_name()
    return send(applet, 200, "text/html; charset=utf-8", fill(login_page, html_escape(name), name))
  end
  if applet.method ~= "POST" then return send(applet, 405, "application/json", '{"error":"POST only"}') end
  if not csrf_ok(applet) then return send(applet, 403, "application/json", '{"error":"forbidden"}') end

  local ip, t = tostring(applet.f:src() or "?"), os.time()
  local fl = fails[ip]
  if fl and fl.locked_until and fl.locked_until > t then
    local mins = math.ceil((fl.locked_until - t) / 60)
    return send(applet, 429, "application/json", string.format('{"error":"Too many attempts. Try again in %d min."}', mins))
  end

  local form = parse_form(applet:receive() or "")
  if urandom and check_password(applet.c, form.username or "", form.password or "") then
    fails[ip] = nil
    local token = to_hex(urandom:read(32))
    sessions[token_hash(applet.c, token)] = { exp = t + SESSION_TTL, created = t, ip = ip }
    save_sessions()
    local body = '{"ok":true}'
    applet:set_status(200)
    applet:add_header("content-type", "application/json")
    applet:add_header("cache-control", "no-store")
    applet:add_header("set-cookie", cookie_header(token, SESSION_TTL))
    applet:add_header("content-length", tostring(#body))
    applet:start_response()
    applet:send(body)
    return
  end

  fl = fl or { n = 0 }
  fl.n = fl.n + 1
  if fl.n >= MAX_FAILS then fl.n, fl.locked_until = 0, t + LOCK_SECONDS end
  fails[ip] = fl
  core.msleep(600)   -- slow down guessing
  if fl.locked_until and fl.locked_until > t then
    return send(applet, 429, "application/json", '{"error":"Too many attempts. Try again in 15 min."}')
  end
  send(applet, 401, "application/json", '{"error":"Wrong username or password."}')
end)

-- POST /hapanel/logout ; body "all=1" signs out every device
core.register_service("logout", "http", function(applet)
  if applet.method ~= "POST" then return send(applet, 405, "application/json", '{"error":"POST only"}') end
  if not csrf_ok(applet) then return send(applet, 403, "application/json", '{"error":"forbidden"}') end
  local all = (applet:receive() or ""):find("all=1", 1, true)
  local h = session_valid(applet.c, get_cookie(applet.headers["cookie"], SESSION_COOKIE))
  if all then sessions = {} elseif h then sessions[h] = nil end
  save_sessions()
  local body = '{"ok":true}'
  applet:set_status(200)
  applet:add_header("content-type", "application/json")
  applet:add_header("cache-control", "no-store")
  applet:add_header("clear-site-data", '"cache"')
  applet:add_header("set-cookie", cookie_header("", 0))
  applet:add_header("content-length", tostring(#body))
  applet:start_response()
  applet:send(body)
end)

-- POST /hapanel/password ; body "current=...&new=..." (session required, enforced in haproxy.cfg).
-- Rewrites AUTH_FILE with a fresh salt and signs out every other session.
local HASH_ROUNDS, MIN_PASSWORD, MAX_PASSWORD = 5000, 10, 128

local function hash_password(conv, salt, pw)
  local h = conv:hex(conv:sha2(salt .. pw, 256))
  for _ = 2, HASH_ROUNDS do h = conv:hex(conv:sha2(h .. salt .. pw, 256)) end
  return h
end

core.register_service("password", "http", function(applet)
  if applet.method ~= "POST" then return send(applet, 405, "application/json", '{"error":"POST only"}') end
  if not csrf_ok(applet) then return send(applet, 403, "application/json", '{"error":"forbidden"}') end
  local ip, t = tostring(applet.f:src() or "?"), os.time()
  local fl = fails[ip]
  if fl and fl.locked_until and fl.locked_until > t then
    return send(applet, 429, "application/json", '{"error":"Too many wrong attempts. Try again later."}')
  end

  local form = parse_form(applet:receive() or "")
  local current, new = form.current or "", form.new or ""
  local user = (read_file(AUTH_FILE) or ""):match("^(%S+)") or "admin"
  if not check_password(applet.c, user, current) then
    fl = fl or { n = 0 }
    fl.n = fl.n + 1
    if fl.n >= MAX_FAILS then fl.n, fl.locked_until = 0, t + LOCK_SECONDS end
    fails[ip] = fl
    core.msleep(600)
    return send(applet, 400, "application/json", '{"error":"Current password is wrong."}')
  end
  local len = utf8.len(new)
  if not len or len < MIN_PASSWORD then
    return send(applet, 400, "application/json", string.format('{"error":"New password must be at least %d characters."}', MIN_PASSWORD))
  end
  if len > MAX_PASSWORD then return send(applet, 400, "application/json", '{"error":"New password is too long."}') end
  if new == current then return send(applet, 400, "application/json", '{"error":"New password must be different."}') end
  if not urandom then return send(applet, 500, "application/json", '{"error":"no randomness source"}') end

  local salt = to_hex(urandom:read(16))
  local tmp = AUTH_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return send(applet, 500, "application/json", '{"error":"cannot save password"}') end
  f:write(string.format("%s v1 %d %s %s\n", user, HASH_ROUNDS, salt, hash_password(applet.c, salt, new)))
  f:close()
  os.rename(tmp, AUTH_FILE)
  fails[ip] = nil

  -- Keep only the session making this change
  local keep = session_valid(applet.c, get_cookie(applet.headers["cookie"], SESSION_COOKIE))
  for h in pairs(sessions) do if h ~= keep then sessions[h] = nil end end
  save_sessions()
  send(applet, 200, "application/json", '{"ok":true}')
end)

core.register_service("dashboard", "http", function(applet)
  local name = server_name()
  send(applet, 200, "text/html; charset=utf-8", fill(page, html_escape(name), name))
end)

-- Settings: POST /hapanel/settings with the new server name as the plain-text body.
-- Basic auth is enforced in haproxy.cfg; the custom header blocks cross-site (CSRF) requests,
-- because browsers can't send it cross-origin without a CORS preflight we never answer.
core.register_service("settings", "http", function(applet)
  if applet.method ~= "POST" then return send(applet, 405, "application/json", '{"error":"POST only"}') end
  local h = applet.headers["x-hapanel"]
  if not h or h[0] ~= "1" then return send(applet, 403, "application/json", '{"error":"forbidden"}') end
  local body = applet:receive() or ""
  -- Trim, drop control characters, cap at MAX_NAME characters (UTF-8 aware)
  local name = body:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if not utf8.len(name) then return send(applet, 400, "application/json", '{"error":"invalid text"}') end
  if utf8.len(name) > MAX_NAME then name = name:sub(1, utf8.offset(name, MAX_NAME + 1) - 1) end
  if name == "" then return send(applet, 400, "application/json", '{"error":"name is required"}') end
  local f = io.open(NAME_FILE, "w")
  if not f then return send(applet, 500, "application/json", '{"error":"cannot save settings"}') end
  f:write(name)
  f:close()
  send(applet, 200, "application/json", '{"name":' .. enc_str(name) .. '}')
end)

local function read_sys()
  local body = read_file(SYS_FILE)
  return (body and body ~= "") and body or '{"error":"collector not running"}'
end

local function enc_val(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    return tostring(v)
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "string" then return enc_str(v)
  end
  return "null"
end

local function enc_obj(tbl)
  local parts = {}
  for k, v in pairs(tbl) do
    if type(v) ~= "table" and type(v) ~= "function" then
      parts[#parts + 1] = enc_str(tostring(k)) .. ":" .. enc_val(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function stats_row(stats, pxname, svname)
  stats.pxname, stats.svname = pxname, svname
  return enc_obj(stats)
end

-- One snapshot: HAProxy counters (from memory) + process info + settings + collector JSON
local function snapshot()
  local rows = {}
  for name, fe in pairs(core.frontends) do
    rows[#rows + 1] = stats_row(fe:get_stats(), name, "FRONTEND")
  end
  for name, be in pairs(core.backends) do
    rows[#rows + 1] = stats_row(be:get_stats(), name, "BACKEND")
    for sname, srv in pairs(be.servers) do
      rows[#rows + 1] = stats_row(srv:get_stats(), name, sname)
    end
  end
  return '{"rows":[' .. table.concat(rows, ",") .. '],"info":' .. enc_obj(core.get_info()) ..
         ',"settings":{"name":' .. enc_str(server_name()) .. ',"sessions":' .. session_count() ..
         '},"sys":' .. read_sys() .. '}'
end

core.register_service("live", "http", function(applet)
  applet:set_status(200)
  applet:add_header("content-type", "text/event-stream")
  applet:add_header("cache-control", "no-store")
  applet:add_header("x-accel-buffering", "no")
  applet:start_response()
  applet:send("retry: 2000\n\n")
  local deadline = core.now().sec + STREAM_SECONDS
  while core.now().sec < deadline do
    applet:send("data: " .. snapshot() .. "\n\n")
    core.msleep(1000)
  end
end)
