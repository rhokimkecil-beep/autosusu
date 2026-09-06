script_name("AutoSusu_CPRP")
script_author("PrimeSamp - cleaned by dev")
script_version("4.9")

require("lib.moonloader")
local sampEvents = require("lib.samp.events")
local imgui      = require("mimgui")
local encoding   = require("encoding")
encoding.default = "CP1251"
local utf8 = encoding.UTF8

local ffi = require("ffi")
pcall(function()
    ffi.cdef([[void _Z12AND_OpenLinkPKc(const char* link);]])
end)

local function openLink(url)
    if not pcall(function() ffi.load("GTASA")._Z12AND_OpenLinkPKc(url) end) then
        os.execute("am start -a android.intent.action.VIEW -d '" .. url .. "'")
    end
end

-- ════════════════════════════════════════════════
--  KONFIGURASI
-- ════════════════════════════════════════════════
local ROUTE_FILE  = getWorkingDirectory() .. "/config/autosusu_route.json"
local ROUTE_DIR   = getWorkingDirectory() .. "/config/autosusu_routes/"
local ROUTE_INDEX = getWorkingDirectory() .. "/config/autosusu_routes/index.json"

-- ════════════════════════════════════════════════
--  STATE
-- ════════════════════════════════════════════════
local showPanel    = imgui.new.bool(false)
local botRunning   = false
local botPaused    = false
local isRecording  = false
local silentCheck  = false

local moveSpeed    = imgui.new.int(7)
local milkDelay    = imgui.new.int(15000)
local actionDelay  = imgui.new.int(3000)

local rawMilk      = 0
local processedMilk= 0
local route        = {}
local themeColor   = imgui.new.float[4](0, 0.65, 0.85, 1)
local themeApplied = false
local botThread    = nil

-- [TAMBAHAN] state kelola route
local routeNameBuf  = imgui.new.char[64]()
local routeList     = {}   -- {"nama1","nama2",...} dari index.json
local selectedRoute = -1

-- ════════════════════════════════════════════════
--  FIREBASE CONFIG  ← WAJIB DIISI
-- ════════════════════════════════════════════════
local FIREBASE_PROJECT_ID = "autosusu-v2"
local FIREBASE_API_KEY    = "AIzaSyAMYjeaRjEg2fKk7MlI1XWJgpDItKrv9dk"

-- ════════════════════════════════════════════════
--  AUTO UPDATE CONFIG
-- ════════════════════════════════════════════════
local CURRENT_VERSION  = "4.9"   -- versi script ini (admin update via panel)
local GITHUB_RAW_URL   = "https://raw.githubusercontent.com/prime22299/autosusu/main/Autosusu.lua"
local UPDATE_CHECK_DOC = "config/version" -- Firestore path untuk versi terbaru

-- ════════════════════════════════════════════════
--  LICENSE SYSTEM (Firebase Edition)
-- ════════════════════════════════════════════════
local LICENSE_FILE = getWorkingDirectory() .. "/config/autosusu_license.json"

local licenseState = {
    verified    = false,
    key         = "",
    expiredAt   = 0,
    activatedAt = 0,
    errorMsg    = "",
    label       = "",
}
local keyInputBuf    = imgui.new.char[32]()
local showLicense    = imgui.new.bool(false)
local licenseLoaded  = false
local isValidating   = false   -- flag cegah double submit

-- ════════════════════════════════════════════════
--  HELPERS
-- ════════════════════════════════════════════════
local function removeHex(s)
    return (s or ""):gsub("{.-}", "")
end

local function distToCoord(x, y, z)
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    return getDistanceBetweenCoords3d(px, py, pz, x, y, z)
end

local function chat(msg)
    sampAddChatMessage(msg, -1)
end

-- ════════════════════════════════════════════════
--  LICENSE HELPERS
-- ════════════════════════════════════════════════
local function getUnixTime()
    return os.time()
end

local function formatCountdown(secs)
    if secs <= 0 then return "EXPIRED" end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    return string.format("%d Hari %02d Jam %02d Menit %02d Detik", d, h, m, s)
end

local function getRemainingSeconds()
    if licenseState.expiredAt == 0 then return -1 end
    return math.max(0, licenseState.expiredAt - getUnixTime())
end

local function isLicenseExpired()
    if licenseState.expiredAt == 0 then return false end
    return getUnixTime() > licenseState.expiredAt
end

-- ════════════════════════════════════════════════
--  DEVICE ID
-- ════════════════════════════════════════════════
local function getDeviceId()
    local h = io.popen("getprop gsm.imei 2>/dev/null")
    if h then
        local imei = h:read("*l"); h:close()
        if imei and #imei > 5 then return "IMEI_" .. imei:sub(1,10) end
    end
    local h2 = io.popen("getprop ro.product.model 2>/dev/null")
    if h2 then
        local model = h2:read("*l"); h2:close()
        if model and #model > 0 then
            return "DEV_" .. model:gsub("%s+","_"):sub(1,20)
        end
    end
    return "DEV_" .. tostring(math.random(100000,999999))
end
local DEVICE_ID = getDeviceId()

-- ════════════════════════════════════════════════
--  FIREBASE HTTP HELPERS (curl via io.popen)
-- ════════════════════════════════════════════════
local function fbDocUrl(key)
    return string.format(
        "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/keys/%s?key=%s",
        FIREBASE_PROJECT_ID, key, FIREBASE_API_KEY
    )
end

-- ──────────────────────────────────────────────
--  AUTO UPDATE SYSTEM
-- ──────────────────────────────────────────────

-- ── HTTP via requests library (support HTTPS, tidak crash GTA) ──
local requests = require('requests')

local function curlGET(url, callback)
    lua_thread.create(function()
        local ok, result = pcall(function()
            local resp = requests.get(url)
            return resp.text
        end)
        if callback then callback(ok and result or nil) end
    end)
end

local function curlPATCH(url, bodyStr, callback)
    lua_thread.create(function()
        local ok, result = pcall(function()
            local resp = requests.request('PATCH', url, {
                headers = {['Content-Type'] = 'application/json'},
                data    = bodyStr,
            })
            return resp.text
        end)
        if callback then callback(ok and result or nil) end
    end)
end

-- ── AUTO UPDATE SYSTEM ──
local isUpdating   = false
local updateStatus = ''
local lastUpdateCheck = 0
local UPDATE_INTERVAL = 10 * 60  -- cek setiap 10 menit (detik)

local function getVersionDocUrl()
    return string.format(
        'https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s?key=%s',
        FIREBASE_PROJECT_ID, UPDATE_CHECK_DOC, FIREBASE_API_KEY
    )
end

local function downloadAndUpdate(dlUrl)
    isUpdating = true
    updateStatus = 'Mengunduh update...'
    chat('{00D4FF}[PrimeBot]{FFFFFF} Mengunduh update dari server...')
    curlGET(dlUrl, function(body)
        if not body or #body < 100 then
            updateStatus = 'Gagal download!'
            chat('{FF0000}[PrimeBot]{FFFFFF} Gagal download update.')
            isUpdating = false
            return
        end
        local wd = getWorkingDirectory()
        local scriptFile = wd .. '\\Autosusu.lua'
        local t = io.open(wd .. '\\autosusu.lua', 'r')
        if t then t:close(); scriptFile = wd .. '\\autosusu.lua' end
        local f = io.open(scriptFile, 'w')
        if not f then
            updateStatus = 'Gagal tulis file!'
            chat('{FF0000}[PrimeBot]{FFFFFF} Gagal menulis file update.')
            isUpdating = false
            return
        end
        f:write(body); f:close()
        updateStatus = 'Selesai! Reload...'
        chat('{00FF88}[PrimeBot]{FFFFFF} Update berhasil! Reload otomatis dalam 2 detik...')
        lua_thread.create(function()
            -- STEP 1: stop bot dulu supaya tidak ada thread yang masih jalan
            botRunning = false
            botPaused  = false

            -- STEP 2: tutup SEMUA panel imgui sebelum reload
            -- tanpa ini imgui OnFrame crash saat Lua state lama di-destroy
            if showPanel   then showPanel[0]   = false end
            if showLicense then showLicense[0] = false end

            -- STEP 3: tunggu imgui selesai render 1-2 frame dengan state false
            wait(300)

            -- STEP 4: bersihkan task player
            pcall(clearCharTasks, PLAYER_PED)

            -- STEP 5: tunggu cukup lama biar semua thread bersih
            wait(1800)

            -- STEP 6: reload aman
            thisScript():reload()
        end)
    end)
end

local function checkForUpdate(silent)
    if isUpdating then return end
    lastUpdateCheck = os.time()
    curlGET(getVersionDocUrl(), function(body)
        if not body or #body == 0 then return end
        if body:find('"NOT_FOUND"') or body:find('"error"') then return end
        local latestVer = body:match('"version"%s*:%s*{%s*"stringValue"%s*:%s*"([^"]*)"')
        local dlUrl     = body:match('"downloadUrl"%s*:%s*{%s*"stringValue"%s*:%s*"([^"]*)"')
        if not latestVer then return end
        if not dlUrl or dlUrl == '' then dlUrl = GITHUB_RAW_URL end
        if latestVer ~= CURRENT_VERSION then
            -- Notifikasi ada update
            chat(string.format(
                '{FFFF00}[PrimeBot]{FFFFFF} >> UPDATE TERSEDIA! v%s >> v%s <<',
                CURRENT_VERSION, latestVer))
            chat('{FFFF00}[PrimeBot]{FFFFFF} Download otomatis dalam 3 detik...')
            lua_thread.create(function()
                wait(3000)
                downloadAndUpdate(dlUrl)
            end)
        elseif not silent then
            chat('{00FF88}[PrimeBot]{FFFFFF} Script sudah versi terbaru (v' .. CURRENT_VERSION .. ')')
        end
    end)
end

-- Timer: cek update di background setiap 10 menit
lua_thread.create(function()
    wait(5000)  -- tunggu 5 detik dulu setelah script load
    while true do
        wait(60000)  -- cek setiap 1 menit apakah sudah waktunya
        if licenseState.verified then  -- hanya cek kalau sudah login
            local now = os.time()
            if now - lastUpdateCheck >= UPDATE_INTERVAL then
                checkForUpdate(true)  -- silent=true, tidak muncul pesan kalau sudah update
            end
        end
    end
end)



-- Firestore JSON parsers (tanpa library JSON)
local function parseIntField(raw, field)
    local v = raw:match('"'..field..'":%s*{%s*"integerValue"%s*:%s*"(%d+)"')
    return v and tonumber(v) or nil
end
local function parseStringField(raw, field)
    return raw:match('"'..field..'":%s*{%s*"stringValue"%s*:%s*"([^"]*)"')
end
local function parseBoolField(raw, field)
    return raw:match('"'..field..'":%s*{%s*"booleanValue"%s*:%s*(%a+)') == "true"
end
local function parseArrayField(raw, field)
    local arr = {}
    local block = raw:match('"'..field..'":%s*{%s*"arrayValue"%s*:%s*(%b{})}')
    if block then
        for sv in block:gmatch('"stringValue"%s*:%s*"([^"]*)"') do
            table.insert(arr, sv)
        end
    end
    return arr
end

-- ════════════════════════════════════════════════
--  SIMPAN / MUAT LICENSE LOKAL
-- ════════════════════════════════════════════════
local function saveLicense()
    local dir = getWorkingDirectory() .. "/config"
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local f = io.open(LICENSE_FILE, "w")
    if f then
        f:write(encodeJson({
            key         = licenseState.key,
            expiredAt   = licenseState.expiredAt,
            activatedAt = licenseState.activatedAt,
            label       = licenseState.label,
            deviceId    = DEVICE_ID,
        }))
        f:close()
    end
end

local function loadLicense()
    local f = io.open(LICENSE_FILE, "r")
    if not f then return false end
    local data = f:read("*a"); f:close()
    if not data or #data == 0 then return false end
    local ok, t = pcall(decodeJson, data)
    if not ok or type(t) ~= "table" then return false end

    local key = t.key or ""
    local exp = t.expiredAt or 0

    if #key < 5 then return false end
    if exp ~= 0 and getUnixTime() > exp then
        licenseState.errorMsg = "Key sudah EXPIRED! Hubungi admin untuk perpanjang."
        return false
    end

    licenseState.verified    = true
    licenseState.key         = key
    licenseState.expiredAt   = exp
    licenseState.activatedAt = t.activatedAt or 0
    licenseState.label       = t.label or ""
    return true
end

-- ════════════════════════════════════════════════
--  REGISTER DEVICE KE FIREBASE (async)
-- ════════════════════════════════════════════════
local function registerDevice(key, existingDevices)
    for _, d in ipairs(existingDevices) do
        if d == DEVICE_ID then
            chat("{00D4FF}[PrimeBot]{FFFFFF} Device sudah terdaftar.")
            return
        end
    end
    table.insert(existingDevices, DEVICE_ID)
    local vals = {}
    for _, d in ipairs(existingDevices) do
        table.insert(vals, string.format('{"stringValue":"%s"}', d))
    end
    local arrayJson = '{"arrayValue":{"values":[' .. table.concat(vals,",") .. ']}}'
    local url  = fbDocUrl(key) .. "&updateMask.fieldPaths=devices"
    local body = '{"fields":{"devices":' .. arrayJson .. '}}'
    curlPATCH(url, body, function(resp)
        if resp and resp:find("stringValue") then
            chat("{00FF88}[PrimeBot]{FFFFFF} Device tercatat: " .. DEVICE_ID)
        else
            chat("{FFFF00}[PrimeBot]{FFFFFF} Gagal catat device (cek internet).")
        end
    end)
end

-- ════════════════════════════════════════════════
--  VALIDASI KEY VIA FIREBASE (async)
-- ════════════════════════════════════════════════
local function validateKey(raw)
    if isValidating then
        licenseState.errorMsg = "Sedang memvalidasi, tunggu..."
        return
    end
    local key = raw:match("^%s*(.-)%s*$")  -- trim saja, tidak upper
    if #key < 5 then
        licenseState.errorMsg = "Key tidak boleh kosong!"
        return
    end
    if not key:upper():match("^PRIME%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w$") then
        licenseState.errorMsg = "Format salah! Gunakan: Prime-XXXX-XXXX-XXXX"
        return
    end

    isValidating = true
    licenseState.errorMsg = "Memvalidasi ke server..."

    curlGET(fbDocUrl(key), function(body)
        isValidating = false
        if not body or #body == 0 then
            licenseState.errorMsg = "Gagal konek ke server! Cek internet."
            return
        end
        if body:find('"NOT_FOUND"') or body:find('"error"') then
            licenseState.errorMsg = "Key tidak ditemukan / tidak terdaftar!"
            return
        end
        if not parseBoolField(body, "active") then
            licenseState.errorMsg = "Key dinonaktifkan oleh admin!"
            return
        end
        local exp = parseIntField(body, "expiredAt") or 0
        local now = getUnixTime()
        if exp ~= 0 and now > exp then
            licenseState.errorMsg = "Key sudah EXPIRED! Hubungi admin."
            return
        end

        -- ✅ Key valid
        local lbl     = parseStringField(body, "label") or ""
        local devices = parseArrayField(body, "devices")

        licenseState.verified    = true
        licenseState.key         = key
        licenseState.expiredAt   = exp
        licenseState.activatedAt = now
        licenseState.errorMsg    = ""
        licenseState.label       = lbl
        saveLicense()

        -- Tutup window license, buka panel
        showLicense[0] = false
        showPanel[0]   = true

        local expStr = exp == 0 and "PERMANENT" or os.date("%d/%m/%Y", exp)
        chat(string.format(
            "{00FF88}[PrimeBot]{FFFFFF} Key VALID! Label: %s | Expired: %s",
            lbl ~= "" and lbl or "-", expStr))

        -- Cek update setelah login
        lua_thread.create(function()
            wait(2000)
            checkForUpdate()
        end)

        -- Daftarkan device ke Firebase
        registerDevice(key, devices)
    end)
end

-- ════════════════════════════════════════════════
--  REVOKE LICENSE
-- ════════════════════════════════════════════════
local function revokeLicense()
    licenseState.verified    = false
    licenseState.key         = ""
    licenseState.expiredAt   = 0
    licenseState.activatedAt = 0
    licenseState.errorMsg    = ""
    licenseState.label       = ""
    os.remove(LICENSE_FILE)
    ffi.fill(keyInputBuf, ffi.sizeof(keyInputBuf))
    showPanel[0]   = false
    showLicense[0] = true
    chat("{FFFF00}[PrimeBot]{FFFFFF} Lisensi dilepas. Masukkan key baru untuk melanjutkan.")
end

-- ════════════════════════════════════════════════
--  THEME
-- ════════════════════════════════════════════════
local function applyTheme()
    local style  = imgui.GetStyle()
    local colors = style.Colors
    local c      = themeColor

    style.WindowRounding   = 10
    style.ChildRounding    = 8
    style.FrameRounding    = 6
    style.PopupRounding    = 6
    style.ScrollbarRounding= 8
    style.GrabRounding     = 6
    style.TabRounding      = 6
    style.WindowBorderSize = 1.5
    style.FrameBorderSize  = 0
    style.WindowPadding    = imgui.ImVec2(12, 12)
    style.FramePadding     = imgui.ImVec2(8, 5)

    colors[imgui.Col.WindowBg]       = imgui.ImVec4(0.07,0.08,0.11,0.95)
    colors[imgui.Col.ChildBg]        = imgui.ImVec4(0.11,0.12,0.16,0.8)
    colors[imgui.Col.TitleBg]        = imgui.ImVec4(0.05,0.06,0.08,1)
    colors[imgui.Col.TitleBgActive]  = imgui.ImVec4(c[0]*0.6,c[1]*0.6,c[2]*0.6,1)
    colors[imgui.Col.FrameBg]        = imgui.ImVec4(0.14,0.16,0.22,1)
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.18,0.21,0.28,1)
    colors[imgui.Col.FrameBgActive]  = imgui.ImVec4(0.22,0.25,0.34,1)
    colors[imgui.Col.Button]         = imgui.ImVec4(c[0]*0.7,c[1]*0.7,c[2]*0.7,0.85)
    colors[imgui.Col.ButtonHovered]  = imgui.ImVec4(c[0],c[1],c[2],1)
    colors[imgui.Col.ButtonActive]   = imgui.ImVec4(c[0]*0.8,c[1]*0.8,c[2]*0.8,1)
    colors[imgui.Col.Header]         = imgui.ImVec4(c[0]*0.5,c[1]*0.5,c[2]*0.5,0.6)
    colors[imgui.Col.HeaderHovered]  = imgui.ImVec4(c[0]*0.8,c[1]*0.8,c[2]*0.8,0.8)
    colors[imgui.Col.HeaderActive]   = imgui.ImVec4(c[0],c[1],c[2],1)
    colors[imgui.Col.Tab]            = imgui.ImVec4(0.12,0.14,0.18,1)
    colors[imgui.Col.TabHovered]     = imgui.ImVec4(c[0]*0.8,c[1]*0.8,c[2]*0.8,0.8)
    colors[imgui.Col.TabActive]      = imgui.ImVec4(c[0]*0.6,c[1]*0.6,c[2]*0.6,1)
    colors[imgui.Col.Border]         = imgui.ImVec4(c[0],c[1],c[2],0.6)
    colors[imgui.Col.Text]           = imgui.ImVec4(0.95,0.96,0.98,1)
end

-- ════════════════════════════════════════════════
--  KEY INJECTION
-- ════════════════════════════════════════════════
local function sendKeyMemory(keyVal, keyOffset)
    local ok, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not ok then return end
    local mem = allocateMemory(68)
    sampStorePlayerOnfootData(pid, mem)
    setStructElement(mem, keyOffset, keyOffset == 36 and 1 or 2, keyVal, false)
    sampSendOnfootData(mem)
    freeMemory(mem)
end

local KEY_MAP = {
    Y     = {val=64,   off=36},
    N     = {val=128,  off=36},
    H     = {val=192,  off=36},
    ALT   = {val=1024, off=4},
    ENTER = {val=16,   off=4},
    F     = {val=16,   off=4},
    SPC   = {val=8,    off=36},
}

local function pressKey(key)
    local k = KEY_MAP[key] or KEY_MAP.Y
    clearCharTasks(PLAYER_PED)
    wait(300)
    for _ = 1, 6 do
        sendKeyMemory(k.val, k.off)
        wait(80)
    end
    wait(200)
end

-- ════════════════════════════════════════════════
--  ROUTE ASLI
-- ════════════════════════════════════════════════
local function saveRoute()
    local f = io.open(ROUTE_FILE, "w")
    if f then
        f:write(encodeJson(route))
        f:close()
        chat("{00FF00}[PrimeBot]{FFFFFF} Rute berhasil disimpan!")
    end
end

local function loadRoute()
    local f = io.open(ROUTE_FILE, "r")
    if f then
        local data = f:read("*a")
        f:close()
        if data and #data > 0 then
            route = decodeJson(data) or {}
        end
    end
end

local function addWaypoint(action)
    local x, y, z = getCharCoordinates(PLAYER_PED)
    table.insert(route, {
        x      = math.floor(x * 100) / 100,
        y      = math.floor(y * 100) / 100,
        z      = math.floor(z * 100) / 100,
        action = action or "NONE",
    })
    local tag = action ~= "NONE"
        and string.format(" {FFFF00}[+AKSI %s]", action) or ""
    chat(string.format("{00FF00}[PrimeBot]{FFFFFF} Stage %d ditambahkan!%s", #route, tag))
end

-- ════════════════════════════════════════════════
--  [TAMBAHAN] ROUTE BERNAMA — pakai index.json
--  TIDAK ada io.popen, TIDAK ada os.execute scan
-- ════════════════════════════════════════════════

-- Baca index dari file
local function loadIndex()
    local f = io.open(ROUTE_INDEX, "r")
    if f then
        local data = f:read("*a")
        f:close()
        if data and #data > 0 then
            local ok, result = pcall(decodeJson, data)
            if ok and type(result) == "table" then
                return result
            end
        end
    end
    return {}
end

-- Tulis index ke file
local function saveIndex(idx)
    if not doesDirectoryExist(ROUTE_DIR) then
        createDirectory(ROUTE_DIR)
    end
    local f = io.open(ROUTE_INDEX, "w")
    if f then
        f:write(encodeJson(idx))
        f:close()
    end
end

-- Muat ulang routeList dari index.json ke memory
local function refreshRouteList()
    local idx = loadIndex()
    routeList = {}
    for _, name in ipairs(idx) do
        table.insert(routeList, name)
    end
end

-- Cek apakah nama sudah ada di index
local function indexHasName(idx, name)
    for _, v in ipairs(idx) do
        if v == name then return true end
    end
    return false
end

-- Simpan route dengan nama ke folder routes/
local function saveRouteNamed(name)
    name = name:match("^%s*(.-)%s*$")
    if name == "" then
        chat("{FF0000}[PrimeBot]{FFFFFF} Nama route tidak boleh kosong!")
        return
    end
    name = name:gsub('[/\\:*?"<>|]', "_")

    if not doesDirectoryExist(ROUTE_DIR) then
        createDirectory(ROUTE_DIR)
    end

    local path = ROUTE_DIR .. name .. ".json"
    local f = io.open(path, "w")
    if f then
        f:write(encodeJson(route))
        f:close()

        -- daftarkan ke index kalau belum ada
        local idx = loadIndex()
        if not indexHasName(idx, name) then
            table.insert(idx, name)
            saveIndex(idx)
        end

        refreshRouteList()
        chat("{00FF00}[PrimeBot]{FFFFFF} Route disimpan: " .. name
            .. " (" .. #route .. " stage)")
    else
        chat("{FF0000}[PrimeBot]{FFFFFF} Gagal menulis file route!")
    end
end

-- Muat route dari nama
local function loadRouteNamed(name)
    local path = ROUTE_DIR .. name .. ".json"
    local f = io.open(path, "r")
    if f then
        local data = f:read("*a")
        f:close()
        if data and #data > 0 then
            local ok, result = pcall(decodeJson, data)
            if ok and type(result) == "table" then
                route = result
                chat("{00FF00}[PrimeBot]{FFFFFF} Route dimuat: "
                    .. name .. " (" .. #route .. " stage)")
            else
                chat("{FF0000}[PrimeBot]{FFFFFF} Data route rusak: " .. name)
            end
        end
    else
        chat("{FF0000}[PrimeBot]{FFFFFF} File tidak ditemukan: " .. name)
    end
end

-- Hapus route dari folder dan index
local function deleteRouteNamed(name)
    local path = ROUTE_DIR .. name .. ".json"
    os.remove(path)

    local idx = loadIndex()
    for i, v in ipairs(idx) do
        if v == name then
            table.remove(idx, i)
            break
        end
    end
    saveIndex(idx)
    refreshRouteList()
    chat("{FFFF00}[PrimeBot]{FFFFFF} Route dihapus: " .. name)
end

-- ════════════════════════════════════════════════
--  BOT CORE
-- ════════════════════════════════════════════════
local function requestItemsCheck()
    sampSendChat("/items")
end

local function startBot()
    if isRecording then isRecording = false end
    if #route == 0 then
        chat("{FF0000}[PrimeBot]{FFFFFF} Rute kosong!")
        return
    end

    botRunning = true
    botPaused  = false
    chat("{00FF00}[PrimeBot]{FFFFFF} Auto Susu berjalan!")
    requestItemsCheck()

    botThread = lua_thread.create(function()
        while botRunning do
            for i, wp in ipairs(route) do
                if not botRunning then break end
                while botPaused do wait(500) end

                -- Set task SEKALI ke waypoint, lalu tunggu sampai sampai
                taskGoStraightToCoord(
                    PLAYER_PED, wp.x, wp.y, wp.z, moveSpeed[0], 60000)

                -- Sprint key: set SEKALI lalu release setelah sampai
                if moveSpeed[0] == 7 then
                    setGameKeyState(16, 255)
                end

                -- Tunggu sampai di waypoint — cek jarak saja, task tidak di-reset
                local timeout = 0
                while distToCoord(wp.x, wp.y, wp.z) > 1.5 do
                    if not botRunning then break end
                    while botPaused do
                        -- Release key saat pause
                        if moveSpeed[0] == 7 then setGameKeyState(16, 0) end
                        clearCharTasks(PLAYER_PED)
                        wait(500)
                        if botRunning and not botPaused then
                            taskGoStraightToCoord(
                                PLAYER_PED, wp.x, wp.y, wp.z,
                                moveSpeed[0], 60000)
                            if moveSpeed[0] == 7 then setGameKeyState(16, 255) end
                        end
                    end

                    timeout = timeout + 1
                    -- Kalau stuck lebih dari 10 detik, reset task
                    if timeout > 100 then
                        clearCharTasks(PLAYER_PED)
                        wait(100)
                        taskGoStraightToCoord(
                            PLAYER_PED, wp.x, wp.y, wp.z, moveSpeed[0], 60000)
                        if moveSpeed[0] == 7 then setGameKeyState(16, 255) end
                        timeout = 0
                    end

                    wait(100)
                end

                -- [FIX KRITIS] Release sprint key segera setelah sampai
                if moveSpeed[0] == 7 then
                    setGameKeyState(16, 0)
                end

                -- Eksekusi action kalau ada
                if botRunning and not botPaused
                    and wp.action and wp.action ~= "NONE" then

                    clearCharTasks(PLAYER_PED)
                    wait(150)

                    chat(string.format(
                        "{00FF00}[PrimeBot]{FFFFFF} Injeksi [%s] Stage %d...",
                        wp.action, i))
                    pressKey(wp.action)
                    wait(actionDelay[0])
                end
            end

            -- Selesai satu putaran
            if botRunning and not botPaused then
                -- Pastikan key benar-benar release sebelum idle
                setGameKeyState(16, 0)
                clearCharTasks(PLAYER_PED)
                requestItemsCheck()
                wait(milkDelay[0])
            end
        end

        -- Cleanup saat bot berhenti
        setGameKeyState(16, 0)
        clearCharTasks(PLAYER_PED)
    end)
end

local function stopBot()
    botRunning = false
    botPaused  = false
    if botThread then botThread:terminate() end
    clearCharTasks(PLAYER_PED)
    chat("{FF0000}[PrimeBot]{FFFFFF} Auto Susu dihentikan.")
end

local function togglePause()
    if not botRunning then return end
    botPaused = not botPaused
    if botPaused then
        clearCharTasks(PLAYER_PED)
        chat("{FFFF00}[PrimeBot]{FFFFFF} Dijeda.")
    else
        chat("{00FF00}[PrimeBot]{FFFFFF} Dilanjutkan.")
    end
end

-- [TAMBAHAN] smooth recording: interval 150ms, threshold 1.5
local function toggleRecording()
    if botRunning then
        chat("{FF0000}[PrimeBot]{FFFFFF} Matikan BOT dulu sebelum merekam!")
        return
    end
    isRecording = not isRecording
    if isRecording then
        chat("{0088FF}[PrimeBot]{FFFFFF} Perekam Aktif (Smooth)! Jalan ke lokasi...")
        lua_thread.create(function()
            while isRecording do
                local x, y, z = getCharCoordinates(PLAYER_PED)
                local last = route[#route]
                if not last or
                    getDistanceBetweenCoords3d(x,y,z,last.x,last.y,last.z) >= 1.5 then
                    addWaypoint("NONE")
                end
                wait(150)
            end
        end)
    else
        chat("{FFFF00}[PrimeBot]{FFFFFF} Perekam dimatikan.")
        saveRoute()
    end
end

-- ════════════════════════════════════════════════
--  SAMPEV
-- ════════════════════════════════════════════════
function sampEvents.onShowDialog(id, style, title, b1, b2, text)
    local cleanText  = removeHex(text  or "")
    local cleanTitle = removeHex(title or "")

    local relevant = cleanText:lower():find("susu")
        or cleanTitle:lower():find("item")
        or cleanTitle:lower():find("inventory")
        or cleanTitle:lower():find("barang")

    if not relevant then return end

    for line in cleanText:gmatch("[^\r\n]+") do
        local cleanLine = removeHex(line):lower()
        if cleanLine:find("murni") then
            local n = line:match("(%d+)")
            if n then rawMilk = tonumber(n) end
        end
        if cleanLine:find("olahan") then
            local n = line:match("(%d+)")
            if n then processedMilk = tonumber(n) end
        end
    end

    if silentCheck or botRunning then
        silentCheck = false
        sampSendDialogResponse(id, 0, 0, "")
        return false
    end
end

-- ════════════════════════════════════════════════
--  MAIN
-- ════════════════════════════════════════════════
function main()
    while not isSampAvailable() do wait(100) end

    -- Pastikan folder ada
    if not doesDirectoryExist(ROUTE_DIR) then
        createDirectory(ROUTE_DIR)
    end

    loadRoute()
    refreshRouteList()

    -- Load saved license
    licenseLoaded = loadLicense()

    sampRegisterChatCommand("autosusu", function()
        if licenseState.verified and not isLicenseExpired() then
            showPanel[0] = not showPanel[0]
        else
            showLicense[0] = true
            showPanel[0]   = false
        end
    end)

    chat("{00FF00}[PrimeBot v4.9]{FFFFFF} Panel Ready! Ketik {00FF00}/autosusu")

    wait(1000)
    silentCheck = true
    requestItemsCheck()
    wait(-1)
end

-- ════════════════════════════════════════════════
--  GUI — LICENSE WINDOW
-- ════════════════════════════════════════════════
imgui.OnFrame(
    function() return showLicense[0] end,
    function()
        if not themeApplied then applyTheme() themeApplied = true end

        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(sw/2, sh/2), imgui.Cond.Always, imgui.ImVec2(0.5,0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(420, 320), imgui.Cond.Always)
        imgui.Begin(utf8("AutoSusu — Aktivasi Key"), showLicense,
            imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
            imgui.WindowFlags.NoCollapse)

        imgui.Spacing()
        imgui.TextColored(imgui.ImVec4(0,0.85,1,1), utf8("AutoSusu CPRP v4.9 — Key License"))
        imgui.Separator()
        imgui.Spacing()

        imgui.TextColored(imgui.ImVec4(0.8,0.8,0.8,1),
            utf8("Masukkan key aktivasi untuk menggunakan script."))
        imgui.Spacing()

        -- Show error if any
        if licenseState.errorMsg ~= "" then
            imgui.TextColored(imgui.ImVec4(1,0.25,0.25,1), utf8(licenseState.errorMsg))
            imgui.Spacing()
        end

        imgui.Text(utf8("Key Aktivasi:"))
        imgui.PushItemWidth(300)
        imgui.InputText("##keyinput", keyInputBuf, 32)
        imgui.PopItemWidth()
        imgui.SameLine()

        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0,0.55,0.75,1))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0.75,1,1))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0,0.45,0.65,1))
        -- Tombol disabled saat sedang validasi
        if isValidating then
            imgui.BeginDisabled()
        end
        if imgui.Button(
            utf8(isValidating and "MEMERIKSA..." or "AKTIVASI"),
            imgui.ImVec2(110,28)) then
            -- validateKey sekarang async — window ditutup otomatis oleh callback
            validateKey(ffi.string(keyInputBuf))
        end
        if isValidating then
            imgui.EndDisabled()
        end
        imgui.PopStyleColor(3)

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1),
            utf8("Format Key: Prime-XXXX-XXXX-XXXX"))
        imgui.Spacing()
        imgui.TextColored(imgui.ImVec4(0.6,0.6,0.6,1),
            utf8("Belum punya key? Hubungi admin di tab Kontak & Media."))

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.12,0.65,0.3,0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.15,0.85,0.4,1))
        if imgui.Button(utf8("WhatsApp Admin"), imgui.ImVec2(180,32)) then
            openLink("https://wa.me/6283166173686")
        end
        imgui.PopStyleColor(2)
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.12,0.65,0.3,0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.15,0.85,0.4,1))
        if imgui.Button(utf8("Grup WhatsApp"), imgui.ImVec2(180,32)) then
            openLink("https://chat.whatsapp.com/DJZYWR1HMbdLgHzORbSzNk")
        end
        imgui.PopStyleColor(2)

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.55,0.08,0.08,0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.8,0.1,0.1,1))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.4,0.05,0.05,1))
        if imgui.Button(utf8("TUTUP"), imgui.ImVec2(-1, 32)) then
            showLicense[0] = false
        end
        imgui.PopStyleColor(3)

        imgui.End()
    end
)

-- ════════════════════════════════════════════════
--  GUI — MAIN PANEL
-- ════════════════════════════════════════════════
imgui.OnFrame(
    function() return showPanel[0] end,
    function()
        if not themeApplied then
            applyTheme()
            themeApplied = true
        end

        imgui.SetNextWindowSize(imgui.ImVec2(490, 560), imgui.Cond.FirstUseEver)
        imgui.Begin(utf8("AutoSusu CPRP v4.9 (Prime Edit)"), showPanel)

        local statusLabel = botRunning
            and (botPaused and "DIJEDA" or "BOT BERJALAN")
            or isRecording and "MEREKAM RUTE..." or "BERHENTI"
        local statusColor = botRunning and imgui.ImVec4(0,1,0,1)
            or isRecording and imgui.ImVec4(0,0.8,1,1)
            or imgui.ImVec4(1,0,0,1)

        imgui.TextUnformatted(utf8("Status: "))
        imgui.SameLine()
        imgui.TextColored(statusColor, utf8(statusLabel))
        imgui.TextColored(
            imgui.ImVec4(1,0.8,0.2,1),
            utf8(string.format("Susu Murni: %d | Susu Olahan: %d",
                rawMilk, processedMilk))
        )
        imgui.Separator()

        if imgui.BeginTabBar("Tabs") then

            -- ── TAB 1: UTAMA & BOT ──
            if imgui.BeginTabItem(utf8("Utama & Bot")) then
                imgui.Spacing()

                imgui.Text(utf8("Kecepatan Gerak:"))
                if imgui.RadioButtonIntPtr(utf8("Jalan (4)"),  moveSpeed, 4) then end
                imgui.SameLine()
                if imgui.RadioButtonIntPtr(utf8("Lari (6)"),   moveSpeed, 6) then end
                imgui.SameLine()
                if imgui.RadioButtonIntPtr(utf8("Sprint (7)"), moveSpeed, 7) then end

                imgui.Spacing()
                imgui.PushItemWidth(160)
                imgui.InputInt(utf8("Delay Aksi Tombol (ms)"), actionDelay, 500, 2000)
                imgui.InputInt(utf8("Delay Otot (ms)"),        milkDelay,   1000, 5000)
                imgui.PopItemWidth()

                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()

                if imgui.Button(utf8(botRunning and "STOP BOT" or "START BOT"),
                    imgui.ImVec2(200,42)) then
                    if botRunning then stopBot() else startBot() end
                end
                imgui.SameLine()
                if imgui.Button(utf8(botPaused and "RESUME" or "PAUSE"),
                    imgui.ImVec2(200,42)) then
                    togglePause()
                end

                imgui.Spacing()

                if imgui.Button(utf8("TEST INJEKSI OTOT [ Y ]"),
                    imgui.ImVec2(220,35)) then
                    lua_thread.create(function()
                        chat("{FFFF00}[PrimeBot]{FFFFFF} Injeksi Y...")
                        pressKey("Y")
                    end)
                end
                imgui.SameLine()
                if imgui.Button(utf8("Sync Susu (/items)"), imgui.ImVec2(160,35)) then
                    silentCheck = true
                    requestItemsCheck()
                end

                imgui.EndTabItem()
            end

            -- ── TAB 2: SET RUTE & TOMBOL ──
            if imgui.BeginTabItem(utf8("Set Rute & Tombol")) then
                imgui.Spacing()
                imgui.Text(utf8(string.format(
                    "Total Titik Terpasang: %d Stage", #route)))

                if imgui.Button(
                    utf8(isRecording and "STOP REKAM" or "REKAM JALAN OTOMATIS"),
                    imgui.ImVec2(210,35)) then
                    toggleRecording()
                end
                imgui.SameLine()
                if imgui.Button(utf8("SIMPAN RUTE"), imgui.ImVec2(180,35)) then
                    saveRoute()
                end

                imgui.Spacing()
                imgui.Text(utf8("Tambah Spot Aksi Tombol:"))

                local actionBtns = {
                    {"[ Y ]","Y",65},{"[ N ]","N",65},{"[ ALT ]","ALT",75},
                    {"[ H ]","H",65},{"[ ENTER ]","ENTER",85},
                }
                for i, btn in ipairs(actionBtns) do
                    if imgui.Button(utf8(btn[1]), imgui.ImVec2(btn[3],32)) then
                        addWaypoint(btn[2])
                    end
                    if i < #actionBtns then imgui.SameLine() end
                end

                imgui.Spacing()
                if imgui.Button(utf8("+ Tambah Jalan Biasa"), imgui.ImVec2(200,30)) then
                    addWaypoint("NONE")
                end
                imgui.SameLine()
                if imgui.Button(utf8("Reset Rute"), imgui.ImVec2(100,30)) then
                    route = {}
                    saveRoute()
                end

                imgui.Spacing()
                imgui.BeginChild("CoordList", imgui.ImVec2(0,140), true)
                for i, wp in ipairs(route) do
                    local actionTag = wp.action and wp.action ~= "NONE"
                        and string.format(" [INJECT %s]", wp.action) or ""
                    imgui.Text(string.format(
                        "Stage %d%s: X=%.1f Y=%.1f", i, actionTag, wp.x, wp.y))
                    imgui.SameLine(310)
                    if imgui.Button(utf8("Hapus##" .. i)) then
                        table.remove(route, i)
                        saveRoute()
                        break
                    end
                end
                imgui.EndChild()
                imgui.EndTabItem()
            end

            -- ── [TAMBAHAN] TAB 3: KELOLA ROUTE ──
            if imgui.BeginTabItem(utf8("Kelola Route")) then
                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(0,0.8,1,1),
                    utf8("Simpan & Muat Route per Job"))
                imgui.Separator()
                imgui.Spacing()

                -- Input nama + tombol simpan
                imgui.Text(utf8("Nama Route:"))
                imgui.PushItemWidth(260)
                imgui.InputText("##routename", routeNameBuf, 64)
                imgui.PopItemWidth()
                imgui.SameLine()
                if imgui.Button(utf8("Simpan##named"), imgui.ImVec2(90,28)) then
                    local name = ffi.string(routeNameBuf):match("^%s*(.-)%s*$")
                    saveRouteNamed(name)
                end

                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(0.7,0.7,0.7,1),
                    utf8(string.format("Route aktif: %d stage", #route)))
                imgui.Separator()
                imgui.Spacing()

                -- Daftar route — dari index.json, tidak ada scan filesystem
                imgui.Text(utf8(string.format(
                    "Daftar Route Tersimpan (%d):", #routeList)))
                imgui.Spacing()

                imgui.BeginChild("RouteList", imgui.ImVec2(0,200), true)
                if #routeList == 0 then
                    imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1),
                        utf8("Belum ada route. Simpan route terlebih dahulu."))
                else
                    for i, name in ipairs(routeList) do
                        local isSelected = (selectedRoute == i)
                        if imgui.Selectable(
                            utf8(string.format("[%d] %s", i, name) .. "##sel" .. i),
                            isSelected,
                            0,
                            imgui.ImVec2(240, 0)) then
                            selectedRoute = i
                        end
                        imgui.SameLine(260)
                        -- Muat
                        if imgui.Button(utf8("Muat##" .. i),
                            imgui.ImVec2(60,22)) then
                            loadRouteNamed(name)
                            selectedRoute = i
                        end
                        imgui.SameLine()
                        -- Hapus
                        imgui.PushStyleColor(imgui.Col.Button,
                            imgui.ImVec4(0.65,0.1,0.1,0.9))
                        imgui.PushStyleColor(imgui.Col.ButtonHovered,
                            imgui.ImVec4(0.85,0.15,0.15,1))
                        if imgui.Button(utf8("Hapus##r" .. i),
                            imgui.ImVec2(60,22)) then
                            deleteRouteNamed(name)
                            if selectedRoute == i then selectedRoute = -1 end
                        end
                        imgui.PopStyleColor(2)
                    end
                end
                imgui.EndChild()

                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1),
                    utf8("Lokasi: config/autosusu_routes/"))

                imgui.EndTabItem()
            end

            -- ── TAB 4: TAMPILAN ──
            if imgui.BeginTabItem(utf8("Tampilan Panel")) then
                imgui.Spacing()
                imgui.Text(utf8("Pilih Warna Tema Neon Modern:"))
                if imgui.ColorEdit4(utf8("Warna Utama"), themeColor) then
                    applyTheme()
                end

                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                imgui.Text(utf8("🎨 Preset Warna Gradient Fantasi:"))
                imgui.Spacing()

                local presets = {
                    {"Cyan Neon",       0,    0.65, 0.85},
                    {"Purple Cyber",    0.6,  0.15, 0.85},
                    {"Red Blood",       0.85, 0.1,  0.15},
                    {"Emerald",         0.1,  0.85, 0.4},
                    {"Rainbow Dream",   1,    0.2,  0.8},
                    {"Galaxy Night",    0.2,  0.1,  0.6},
                    {"Neon Pink",       1,    0.1,  0.6},
                    {"Ocean Blue",      0,    0.5,  1},
                    {"Mystic Purple",   0.7,  0.2,  0.9},
                    {"Fire Orange",     1,    0.5,  0},
                    {"Forest Green",    0.2,  0.7,  0.3},
                    {"Gold Aurora",     1,    0.8,  0.1},
                    {"Sakura Pink",     1,    0.6,  0.8},
                    {"Ice Blue",        0.4,  0.8,  1},
                    {"Void Dark",       0.1,  0.1,  0.2},
                    {"Sunset Warm",     1,    0.4,  0.2},
                }
                
                -- Display in grid (2 per row)
                local btnWidth = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x) / 2
                for i, p in ipairs(presets) do
                    imgui.PushStyleColor(imgui.Col.Button, 
                        imgui.ImVec4(p[2]*0.8, p[3]*0.8, p[4]*0.8, 0.8))
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, 
                        imgui.ImVec4(p[2], p[3], p[4], 1))
                    
                    if imgui.Button(utf8(p[1]), imgui.ImVec2(btnWidth, 40)) then
                        themeColor[0]=p[2]
                        themeColor[1]=p[3]
                        themeColor[2]=p[4]
                        applyTheme()
                        chat("{00FF88}[Theme]{FFFFFF} Changed to: " .. p[1])
                    end
                    imgui.PopStyleColor(2)
                    
                    if i % 2 == 0 then
                        imgui.Spacing()
                    else
                        imgui.SameLine()
                    end
                end
                imgui.EndTabItem()
            end

            -- ── TAB 5: CHEAT MENU ──
            if imgui.BeginTabItem(utf8("🎮 Cheat Menu")) then
                imgui.Spacing()
                imgui.Text(utf8("Cheat Menu - Coming Soon"))
                imgui.Spacing()
                
                imgui.EndTabItem()
            end

            -- ── TAB 6: KONTAK ──
            if imgui.BeginTabItem(utf8("Kontak & Media")) then
                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(0.2,0.7,1,1),
                    utf8("Dukungan & Komunitas Developer"))
                imgui.Separator()
                imgui.Spacing()

                -- ── LICENSE INFO BLOCK ──
                imgui.BeginChild("LicenseInfo", imgui.ImVec2(0, 110), true)
                imgui.TextColored(imgui.ImVec4(0,0.85,1,1), utf8("Status Lisensi"))
                imgui.Separator()
                imgui.Spacing()

                if licenseState.verified and not isLicenseExpired() then
                    imgui.TextColored(imgui.ImVec4(0,1,0.4,1), utf8("Status: AKTIF"))
                    imgui.Text(utf8("Key: " .. licenseState.key))

                    if licenseState.expiredAt == 0 then
                        imgui.TextColored(imgui.ImVec4(0.9,0.8,0,1),
                            utf8("Masa Berlaku: PERMANENT"))
                    else
                        local rem = getRemainingSeconds()
                        local expColor = rem < 86400
                            and imgui.ImVec4(1,0.3,0.3,1)
                            or  imgui.ImVec4(1,0.75,0,1)
                        imgui.TextColored(expColor,
                            utf8("Expired dalam: " .. formatCountdown(rem)))
                        local expDate = os.date("%d/%m/%Y %H:%M:%S",
                            licenseState.expiredAt)
                        imgui.TextColored(imgui.ImVec4(0.6,0.6,0.6,1),
                            utf8("Tanggal Expired: " .. expDate))
                    end

                    imgui.Spacing()
                    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.55,0.08,0.08,0.9))
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.8,0.1,0.1,1))
                    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.4,0.05,0.05,1))
                    if imgui.Button(utf8("EXIT LICENSE"), imgui.ImVec2(-1, 26)) then
                        revokeLicense()
                    end
                    imgui.PopStyleColor(3)
                else
                    imgui.TextColored(imgui.ImVec4(1,0.2,0.2,1), utf8("Status: TIDAK AKTIF / EXPIRED"))
                    imgui.Spacing()
                    if imgui.Button(utf8("Buka Aktivasi Key"), imgui.ImVec2(180,28)) then
                        showPanel[0]   = false
                        showLicense[0] = true
                    end
                end

                imgui.EndChild()
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()

                local btnW = (imgui.GetContentRegionAvail().x
                    - imgui.GetStyle().ItemSpacing.x * 2) / 3

                local contacts = {
                    {label="WA Admin",
                     url="https://wa.me/6283166173686",
                     msg="Membuka WhatsApp Admin...",
                     color={0.12,0.65,0.3}},
                    {label="Grup WA",
                     url="https://chat.whatsapp.com/DJZYWR1HMbdLgHzORbSzNk",
                     msg="Membuka Grup WhatsApp...",
                     color={0.12,0.65,0.3}},
                    {label="YouTube",
                     url="https://youtube.com/@Primesamp",
                     msg="Membuka Channel YouTube...",
                     color={0.8,0.12,0.12}},
                }

                for i, c in ipairs(contacts) do
                    imgui.PushStyleColor(imgui.Col.Button,
                        imgui.ImVec4(c.color[1],c.color[2],c.color[3],0.9))
                    imgui.PushStyleColor(imgui.Col.ButtonHovered,
                        imgui.ImVec4(c.color[1]*1.2,c.color[2]*1.2,c.color[3]*1.2,1))
                    imgui.PushStyleColor(imgui.Col.ButtonActive,
                        imgui.ImVec4(c.color[1]*0.8,c.color[2]*0.8,c.color[3]*0.8,1))
                    if imgui.Button(utf8(c.label), imgui.ImVec2(btnW,38)) then
                        openLink(c.url)
                        chat("{00FF00}[PrimeBot] {FFFFFF}" .. c.msg)
                    end
                    imgui.PopStyleColor(3)
                    if i < #contacts then imgui.SameLine() end
                end
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
        imgui.End()
    end
)
