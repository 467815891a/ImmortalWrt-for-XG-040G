-- xpon-luci：PON设置 配置面板（LOID/SN/MAC/VLAN/业务）
-- 手写 HTML 表单模式（stock 21.02 裁剪版无 luci.model.cbi 库），
-- 结构参考 8311-was-110-firmware-builder 的 controller/8311.lua。

module("luci.controller.xpon", package.seeall)

local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci"
local uci_native = require "uci"
local ltemplate = require "luci.template"
local fs = require "nixio.fs"

local formvalue = http.formvalue

-- build_url() 只接受路径段，不能把含 ? 的完整路径作为单个参数传入；
-- 否则该参数会被丢弃并跳到 /cgi-bin/luci，看起来像 session 被登出。
local function xpon_url(page, query)
	local url = dispatcher.build_url("admin", "xpon", page)
	return query and (url .. "?" .. query) or url
end

-- 业务标识与中文名（顺序即页面展示顺序）
local service_defs = {
	{ id = "tr069",   name = "TR069 管理" },
	{ id = "internet", name = "INTERNET 上网" },
	{ id = "iptv",    name = "IPTV 电视" },
	{ id = "voice",   name = "VOICE 语音" },
}

-- 目标接口名（netifd 原生接口，device 指向 pon.<vid>）
local service_ifaces = {
	tr069 = "tr069",
	internet = "wan",
	iptv = "iptv",
	voice = "voice",
}

-- PON 模式（onu_type bootarg 字节）：
--   bits[1:0]=ONU 类型：0=unknown 1=SFU 2=HGU（ra_nat_multicast.c 只在 HGU=0x2 时做组播收敛）
--   bit2=ComboPon  bit3=bbf247
--   bits[7:4]=PON 模式：1=GPON 2=EPON(1G) 3=10G/1G-EPON 4=10G/10G-EPON 5=1G/1G-EPON
--               6=XGPON(10G/2.5G) 7=XGSPON(10G 对称) 8~A=NGPON2 B=GPON-SYM C=TURBO-EPON
-- 设备 PON MAC 支持 XEPON 的 10G LLID/MPCP/FEC/DPoE 路径，
-- module_sel.c 按高半字节选择固定 PON 模式；2/3/4/5/C 均为 EPON 引擎。
-- 光模块 EN7572 BOB 为 10G PON 模块（1577/1270nm 与 XEPON 同波长），
-- 但固件 S00 无 XEPON 专用分支（按 XGSPON 加载），且 OAM 引擎需 pon_mode=EPON 才拉起——
-- 故 XEPON 标记为实验性，需 10G-EPON OLT 实测。
-- 本机 TTL 当前 61 = SFU+XGPON（uboot 仓库 README 的“61=HGU”有误）；
-- 联通 HGU 家庭网关（LAN 桥接+VEIP+IPTV 组播）应切 62。
local pon_modes = {
	{ id = "62", name = "HGU + XGPON",  desc = "推荐（HGU 家庭网关）：10G/2.5G 不对称，LAN 桥接+VEIP+组播完整" },
	{ id = "61", name = "SFU + XGPON",  desc = "本机 TTL 当前值：SFU 桥形态，无 VEIP/组播引擎，仅适合纯桥/实验" },
	{ id = "72", name = "HGU + XGSPON", desc = "10G 对称（XGS-PON 端口）；出厂默认 71 的 HGU 对应值" },
	{ id = "71", name = "SFU + XGSPON", desc = "出厂默认：SFU 桥形态 + 10G 对称" },
	{ id = "12", name = "HGU + GPON",   desc = "GPON-only 端口（需 OLT 为 GPON）" },
	{ id = "11", name = "SFU + GPON",   desc = "GPON-only 端口（需 OLT 为 GPON）" },
	{ id = "42", name = "HGU + 10G/10G-EPON", desc = "XEPON 对称（IEEE 802.3av 10G-EPON），需 OLT 10G-EPON 口 + OAM 认证" },
	{ id = "41", name = "SFU + 10G/10G-EPON", desc = "XEPON 对称 SFU 形态" },
	{ id = "32", name = "HGU + 10G/1G-EPON",  desc = "XEPON 不对称（10G 下行/1G 上行）" },
	{ id = "31", name = "SFU + 10G/1G-EPON",  desc = "XEPON 不对称 SFU 形态" },
}

-- 认证页“PON 模式”技术选型（onu_type bits[7:4]）：
--   2=EPON、3=10G/1G-EPON、4=10G/10G-EPON、5=1G/1G-EPON、C=TURBO-EPON 属 OAM 族。
-- 具体 HGU/SFU 形态（61/62/71/72/…）由“模式”页 onu_type 决定，本页只管技术族。
local pon_techs = {
	{ id = "GPON",         name = "GPON 2.5G/1.25G不对称",             desc = "bits[7:4]=1；OLT 为 GPON 口时选择" },
	{ id = "XGPON",        name = "XGPON 10G/2.5G不对称",    desc = "bits[7:4]=6；本机 TTL 当前 61/62" },
	{ id = "XGSPON",       name = "XGSPON 10G/10G 对称",              desc = "bits[7:4]=7；出厂默认 71/72" },
	{ id = "EPON",         name = "EPON 1G/1G（常用）",                    desc = "bits[7:4]=2；EPON OAM 认证" },
	{ id = "EPON_10G_1G",  name = "10G/1G-EPON 10G/1G不对称",    desc = "bits[7:4]=3；EPON OAM 认证" },
	{ id = "EPON_10G_10G", name = "10G/10G-EPON 10G/10G对称",     desc = "bits[7:4]=4；EPON OAM 认证" },
	{ id = "EPON_1G_1G",   name = "EPON 1G/1G（备用）",                 desc = "bits[7:4]=5；EPON OAM 认证，备用/兼容枚举" },
	{ id = "EPON_TURBO",   name = "TURBO-EPON",                 desc = "bits[7:4]=C；EPON OAM 认证" },
}

-- 技术 ID <-> onu_type bits[7:4]
local pon_tech_bits = {
	GPON = 1, EPON = 2, XGPON = 6, XGSPON = 7,
	EPON_10G_1G = 3, EPON_10G_10G = 4, EPON_1G_1G = 5, EPON_TURBO = 12,
}
local pon_tech_by_bits = {}
for _id, _bits in pairs(pon_tech_bits) do pon_tech_by_bits[_bits] = _id end
local pon_tech_short_names = {
	GPON = "GPON",
	XGPON = "XGPON",
	XGSPON = "XGSPON",
	EPON = "1G-EPON",
	EPON_10G_1G = "10G/1G-EPON",
	EPON_10G_10G = "10G/10G-EPON",
	EPON_1G_1G = "1G/1G-EPON",
	EPON_TURBO = "TURBO-EPON",
}

-- 组合 onu_type = (技术 bits << 4) | ONU 类型（1=SFU 2=HGU）
local function onu_type_hex(tech, low)
	local bits = pon_tech_bits[tech] or 6
	return string.format("%02x", bits * 16 + (tonumber(low) or 1))
end

-- 技术族 -> netifd 引擎值（netifd 二进制只认 GPON/EPON 两个字符串）
local function pon_engine_for(ptech)
	if ptech == "EPON" or ptech == "EPON_10G_1G" or
		ptech == "EPON_10G_10G" or ptech == "EPON_1G_1G" or
		ptech == "EPON_TURBO" then
		return "EPON"
	end
	return "GPON"
end

-- PON 模式名（sys_xpon_mode 取值）
local pon_mode_names = {
	[1]  = "GPON",
	[2]  = "1G-EPON",
	[3]  = "10G/1G-EPON（XEPON 不对称）",
	[4]  = "10G/10G-EPON（XEPON 对称）",
	[5]  = "1G/1G-EPON",
	[6]  = "XGPON（X-GPON 不对称）",
	[7]  = "XGSPON（X-GPON 对称）",
	[8]  = "NGPON2 10G/10G",
	[9]  = "NGPON2 10G/2G",
	[10] = "NGPON2 2G/2G",
	[11] = "GPON-SYM",
	[12] = "TURBO-EPON",
}

-- 解码 onu_type 十六进制为“人话”：
-- 低 2 bit=ONU 形态 1=SFU/2=HGU，高 4 bit=PON 技术）
local function decode_onu(hex)
	local b = tonumber(hex, 16)
	if not b then
		return { form = "未知", form_cn = "未知", tech = "?", tech_cn = "未知", label = "未知" }
	end
	local low = b % 16
	local form = (low == 2 and "HGU") or (low == 1 and "SFU") or "未知"
	local form_cn = (low == 2 and "HGU（家庭网关）") or (low == 1 and "SFU（桥形态）") or "未知"
	local tid = pon_tech_by_bits[math.floor(b / 16)]
	local tech_cn = tid or "未知"
	for _, t in ipairs(pon_techs) do
		if t.id == tid then tech_cn = t.name end
	end
	local tech_short = pon_tech_short_names[tid] or "未知"
	local label = (form ~= "未知" and tech_short ~= "未知") and (form .. " / " .. tech_short) or "未知"
	return { form = form, form_cn = form_cn, tech = tid or "?", tech_cn = tech_cn, label = label }
end

function index()
	entry({"admin", "xpon"}, firstchild(), "光猫", 39).dependent = false
	entry({"admin", "xpon", "auth"}, call("action_auth"), "认证", 1)
	entry({"admin", "xpon", "services"}, call("action_services"), "业务", 2)
	entry({"admin", "xpon", "voice"}, call("action_voice"), "语音", 3)
	entry({"admin", "xpon", "service-vlan"}, post("action_service_vlan")).leaf = true
	entry({"admin", "xpon", "moci"}, call("action_moci"), "OMCI", 4)
	entry({"admin", "xpon", "oam"}, call("action_oam"), "OAM", 5)
	entry({"admin", "xpon", "status"}, call("action_status"), "状态", 6)

	-- 手写表单直接提交各字段，不包含名为 data 的字段；post_on({data=true})
	-- 会导致路由条件不匹配并回到登录页，表现为“被登出且未保存”。
	entry({"admin", "xpon", "save"}, post("action_save")).leaf = true
	entry({"admin", "xpon", "services", "action"}, post("action_service_action")).leaf = true
	entry({"admin", "xpon", "multicast"}, post("action_multicast")).leaf = true
	entry({"admin", "xpon", "status", "data"}, call("action_status_data")).leaf = true
	entry({"admin", "xpon", "status", "details"}, call("action_status_details")).leaf = true
end

------------------------------------------------------------------------
-- 读取辅助
------------------------------------------------------------------------

local function uget(config, section, option)
	return uci.cursor():get(config, section, option)
end

local function ensure_section(u, config, section, stype)
	u = u or uci.cursor()
	if u:get_all(config, section) then
		return true
	end
	local name, err = u:section(config, stype, section, {})
	return name ~= nil and name ~= false, err
end

local lan_port_devices = {
	lan1 = "eth0.8",
	lan2 = "eth0.7",
	lan3 = "eth0.5",
	lan4 = "eth0.4",
}

local function option_list(v)
	if type(v) == "table" then return v end
	local out = {}
	for item in tostring(v or ""):gmatch("%S+") do out[#out + 1] = item end
	return out
end

local function ensure_xpon_config_file()
	local path = "/etc/config/xpon"
	if fs.access(path) then return true end
	local ok = fs.writefile(path, "config auth 'device'\n")
	return ok and fs.access(path) or false
end

local function sh(cmd)
	-- /tmp/ponstatus 的定长记录带大量 NUL 填充；它们没有文本意义，
	-- 且会被 JSON 编码成成百上千个 \u0000。
	local out = sys.exec(cmd .. " 2>&1") or ""
	return util.trim((out:gsub("%z", "")))
end

-- Extract a real registered LLID from mixed driver/cache/log output.  Some
-- snapshots contain an initial `LLID = N/A` followed by a valid proc/log line.
local function parse_epon_llid(text)
	local lower = tostring(text or ""):lower()
	local patterns = {
		"llid%s*%b[]%s*[:=]%s*(0x%x+)",
		"llid%s*%b[]%s*[:=]%s*(%d+)",
		"llid%s*[:=]%s*(0x%x+)",
		"llid%s*[:=]%s*(%d+)",
		"llid%s+(0x%x+)",
		"llid%s+(%d+)",
	}
	for _, pattern in ipairs(patterns) do
		for token in lower:gmatch(pattern) do
			local value = token:match("^0x%x+$") and tonumber(token:sub(3), 16) or tonumber(token)
			if value and value > 0 and value < 65535 then return value end
		end
	end
	return nil
end

local function ponmgr_cache(key)
	if not tostring(key or ""):match("^[%w_]+$") then return "" end
	local out = fs.readfile("/tmp/xpon_ponmgr_cache/" .. key) or ""
	return util.trim((out:gsub("%z", "")))
end

local function onu_boot_values()
	local env_val = sh("fw_printenv onu_type 2>/dev/null")
	local env_bootargs = sh("fw_printenv -n bootargs 2>/dev/null")
	local cmdline_val = sh("grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1")
	cmdline_val = cmdline_val:match("=(.*)$") or cmdline_val
	local env_num = env_val:match("=(.*)$") or env_val
	if not env_num:match("^[0-9a-fA-F][0-9a-fA-F]$") then env_num = "" end
	local bootargs_num = (" " .. env_bootargs .. " "):match("%sonu_type=([0-9a-fA-F][0-9a-fA-F])%s") or ""
	-- Factory U-Boot may boot from legacy bootargs. If it exists, it is the
	-- effective next-boot source; xpon-apply.sh keeps fw_printenv onu_type
	-- synchronized but cannot make it override an existing bootargs value.
	local next_num = (bootargs_num ~= "") and bootargs_num or env_num
	local run_hex = (cmdline_val ~= "") and cmdline_val or next_num
	return {
		env = env_val,
		env_hex = next_num,
		fwenv_hex = env_num,
		bootargs_hex = bootargs_num,
		cmdline = cmdline_val,
		pending = (next_num ~= "" and cmdline_val ~= "" and next_num ~= cmdline_val),
		run_hex = run_hex,
		run_dec = decode_onu(run_hex),
		env_dec = decode_onu(next_num),
	}
end

local function dsd_ascii24_ok(s)
	s = tostring(s or "")
	if #s > 24 then return false end
	for i = 1, #s do
		local b = s:byte(i)
		if b < 32 or b == 127 then return false end
	end
	return true
end

local function dsd_ponmac_ok(s)
	return #(s or "") == 17 and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function dsd_raw_value(key)
	local safe_keys = {
		fsan = true, wan_mac = true, lan_mac = true, serial_number = true,
		manufacturer = true, clei_code = true,
	}
	if not safe_keys[key] then return "" end
	local v = sh("/usr/sbin/gtk_dsd get " .. key .. " 2>/dev/null")
	if v ~= "" then return v end
	return sh([[awk -F"'" '/^]] .. key .. [[=/ {print $2; exit}' /tmp/dsd.env 2>/dev/null]])
end

local function dsd_wan_mac()
	local mac = dsd_raw_value("wan_mac")
	if #mac == 17 and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return mac:upper()
	end
	return ""
end

local function dsd_fsan()
	local fsan = (dsd_raw_value("fsan") or ""):gsub("%s+", ""):upper()
	if #fsan == 12 and fsan:sub(1, 4):match("^[A-Z0-9]+$") and fsan:sub(5, 12):match("^[0-9A-F]+$") then
		return fsan
	end
	return ""
end

local function dsd_clei_code()
	local clei = dsd_raw_value("clei_code")
	if dsd_ascii24_ok(clei) then return clei end
	return ""
end

local function shell_quote(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function apply_dsd_value(key, value)
	local safe_keys = { fsan = true, wan_mac = true, clei_code = true }
	if not safe_keys[key] then return 64 end
	value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if key == "fsan" then
		value = value:gsub("%s+", ""):upper()
		if #value ~= 12 or not value:sub(1, 4):match("^[A-Z0-9]+$") or not value:sub(5, 12):match("^[0-9A-F]+$") then return 64 end
	elseif key == "wan_mac" then
		value = value:gsub("%s+", ""):upper()
		if not dsd_ponmac_ok(value) then return 64 end
	elseif key == "clei_code" then
		if value == "" or not dsd_ascii24_ok(value) then return 64 end
	end
	local qkey = shell_quote(key)
	local qvalue = shell_quote(value)
	local qcmp = shell_quote((key == "fsan" or key == "wan_mac") and value:upper() or value)
	local normalize = (key == "fsan" or key == "wan_mac") and " | tr 'a-z' 'A-Z'" or ""
	local cmd = table.concat({
		"stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null);",
		"[ -n \"$stamp\" ] || stamp=unknown;",
		"mkdir -p /etc/xpon-env-backups || exit 1;",
		"/usr/sbin/gtk_dsd get all > /etc/xpon-env-backups/dsd-get-all-$stamp.txt 2>/dev/null || true;",
		"dd if=/dev/mtdblock2 of=/etc/xpon-env-backups/mtd2-dsd-$stamp.bin bs=128k >/tmp/xpon-dsd-dd.log 2>&1 || exit 1;",
		"/usr/sbin/gtk_dsd set " .. qkey .. " " .. qvalue .. " || exit 1;",
		"/usr/bin/xpon-dsd-env.sh || true;",
		"read_value=$(/usr/sbin/gtk_dsd get " .. qkey .. " 2>/dev/null" .. normalize .. ");",
		"[ \"$read_value\" = " .. qcmp .. " ] || { echo \"DSD " .. key .. " 回读失败：want=" .. value .. " have=${read_value:-空}\"; exit 65; };",
		"echo \"DSD " .. key .. " 已写入并回读成功：" .. value .. " backup=/etc/xpon-env-backups/mtd2-dsd-$stamp.bin\""
	}, " ")
	return sys.call("( " .. cmd .. " ) >/tmp/xpon-dsd-apply.log 2>&1")
end

-- 写系统日志（logread 可查），单引号转义防注入
local function logger(tag, msg)
	sys.call("logger -t " .. tag .. " '" .. (msg or ""):gsub("'", "'\\''") .. "' 2>/dev/null")
end

local function schedule_reboot(delay)
	delay = tonumber(delay) or 8
	local cmd = "touch /tmp/xpon-reboot-pending; " ..
		"( sleep " .. delay .. "; logger -t xpon '认证参数已保存，执行整机重启'; sync; " ..
		"ubus call system reboot >/dev/null 2>&1 || /sbin/reboot ) " ..
		">/dev/null 2>&1 </dev/null &"
	return sys.call(cmd) == 0
end

-- gponmapcmd / ponvlancmd 的 show 结果由内核日志输出（stdout 为空）。
-- 这里记录执行前 dmesg 行数，执行后取增量；同时保留 stdout（双保险）。
local function klog_show(cmd)
	local before = tonumber(sh("dmesg 2>/dev/null | wc -l")) or 0
	local out = sh(cmd)
	local tail = sh("dmesg 2>/dev/null | tail -n +" .. (before + 1) ..
		" | sed 's/^\\[ *[0-9][0-9]*\\.[0-9][0-9]*\\] //'")
	local parts = {}
	if out ~= "" then parts[#parts + 1] = out end
	if tail ~= "" then parts[#parts + 1] = tail end
	return table.concat(parts, "\n")
end

------------------------------------------------------------------------
-- GEM / ponvlan 只读表解析
------------------------------------------------------------------------

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 按空白拆字段
local function fields(line)
	local f = {}
	for w in (line .. " "):gmatch("%S+") do f[#f + 1] = w end
	return f
end

-- 上行映射：表头 tagFlag uni vid dscp pbit gemPort，
-- 每列 = tagCtl 位决定：位 1 显示值，位 0 显示 N/A=通配不参与匹配）
local function parse_gem_up(text)
	local rows, raw = {}, {}
	for line in (text .. "\n"):gmatch("([^\n]+)") do
		line = trim(line)
		if line ~= "" then
			local f = fields(line)
			if #f == 6 and not f[1]:match("^tagFlag") and not f[1]:match("^gemPortmapping") then
				rows[#rows + 1] = {
					tagFlag = f[1], userPort = f[2], vid = f[3], dscp = f[4], pbit = f[5], gemPort = f[6],
				}
			else
				raw[#raw + 1] = line
			end
		end
	end
	return rows, table.concat(raw, "\n")
end

-- 下行映射：`total rule num is N` + `Gem Port:%d, If Mask:%08x, queue Index:%d,
-- trtcm Id:%d, queue_enable:%d, trtcm_enable:%d, down weight:%d`
local function parse_gem_down(text)
	local total, rows, raw = "", {}, {}
	for line in (text .. "\n"):gmatch("([^\n]+)") do
		line = trim(line)
		if line ~= "" then
			local t = line:match("^total rule num is (%d+)")
			if t then
				total = t
			else
				local gp, im, q, tr, qe, te, w = line:match(
					"Gem Port:(%d+), If Mask:(%x+), queue Index:(%d+), trtcm Id:(%d+), queue_enable:(%d+), trtcm_enable:(%d+), down weight:(%d+)")
				if gp then
					rows[#rows + 1] = { gemPort = gp, ifMask = im, queue = q, trtcm = tr, qEnable = qe, tEnable = te, weight = w }
				else
					raw[#raw + 1] = line
				end
			end
		end
	end
	return total, rows, table.concat(raw, "\n")
end

-- 队列映射：`queuemapping-->` + 表头 gemPort pqMode tcont queue tse tsChannelId + 行
local function parse_gem_queue(text)
	local rows, raw = {}, {}
	for line in (text .. "\n"):gmatch("([^\n]+)") do
		line = trim(line)
		if line ~= "" then
			local f = fields(line)
			if f[1] == "gemPort" or f[1] == "queuemapping" or f[1] == "pqMode" then
				raw[#raw + 1] = line
			elseif #f == 6 and f[1]:match("^%d+$") then
				rows[#rows + 1] = {
					gemPort = f[1], pqMode = f[2], tcont = f[3], queue = f[4], tse = f[5], tsChannelId = f[6],
				}
			else
				raw[#raw + 1] = line
			end
		end
	end
	return rows, table.concat(raw, "\n")
end

-- ponmgr GEM 口表。新版输出把 MAC If / Loopback / Encryption 分成多行，
-- 旧版也可能挤在同一行，因此按条目状态增量解析。
-- （G.988 ME 268 GEM port network CTP 的驱动视图）
local function parse_ponmgr_gem(text)
	local rows, current = {}, nil
	for l in (text .. "\n"):gmatch("([^\n]+)") do
		local kind, gp, tcont = l:match("(%a+) GEM Port:%s*(%d+), TCONT:%s*(%d+)")
		if gp then
			current = { gem = gp, tcont = tcont, macif = "", kind = kind or "", loopback = "", encryption = "" }
			rows[#rows + 1] = current
		end
		if current then
			current.macif = l:match("MAC If:%s*([^,%s]+)") or current.macif
			current.loopback = l:match("Loopback:%s*([^,]+)") or current.loopback
			current.encryption = l:match("Encryption:%s*(%S+)") or current.encryption
		end
	end
	table.sort(rows, function(a, b) return tonumber(a.gem) < tonumber(b.gem) end)
	return rows
end

-- ponmgr TCONT 表：索引对应硬件 channel，Alloc-ID 对应 G.988 ME262。
local function parse_ponmgr_tcont(text)
	local rows = {}
	for l in (text .. "\n"):gmatch("([^\n]+)") do
		local idx, alloc, channel = l:match("^%s*(%d+)%s+ALLOC ID:%s*(%d+), Channel:%s*(%d+)")
		if idx then rows[#rows + 1] = { index = idx, alloc = alloc, channel = channel } end
	end
	table.sort(rows, function(a, b) return tonumber(a.index) < tonumber(b.index) end)
	return rows
end

local function command_dump(defs)
	local out = {}
	for _, d in ipairs(defs) do
		out[#out + 1] = "==== " .. d[1] .. " ===="
		local body = sh("timeout 3 " .. d[2])
		out[#out + 1] = body ~= "" and body or "（无输出）"
	end
	return table.concat(out, "\n")
end

local function ponmgr_cache_dump(defs)
	local out = {}
	for _, d in ipairs(defs) do
		out[#out + 1] = "==== " .. d[1] .. "（xpon-app 单写者缓存） ===="
		local body = ponmgr_cache(d[2])
		out[#out + 1] = body ~= "" and body or "（缓存尚未生成）"
	end
	return table.concat(out, "\n")
end

------------------------------------------------------------------------
-- 极简 JSON 编码（不依赖 luci.jsonc，裁剪版也能跑）
------------------------------------------------------------------------

local function json_escape(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
	s = s:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
	s = s:gsub("[%z\1-\31]", function(c) return string.format("\\u%04x", c:byte()) end)
	return s
end

local function encode_json(t)
	local out = {}
	local function enc(v)
		if type(v) == "string" then
			out[#out + 1] = '"' .. json_escape(v) .. '"'
		elseif type(v) == "number" or type(v) == "boolean" then
			out[#out + 1] = tostring(v)
		elseif type(v) == "table" then
			if v[1] ~= nil then
				out[#out + 1] = "["
				for i, e in ipairs(v) do
					if i > 1 then out[#out + 1] = "," end
					enc(e)
				end
				out[#out + 1] = "]"
			else
				out[#out + 1] = "{"
				local first = true
				for k, e in pairs(v) do
					if not first then out[#out + 1] = "," end
					first = false
					out[#out + 1] = '"' .. json_escape(k) .. '":'
					enc(e)
				end
				out[#out + 1] = "}"
			end
		else
			out[#out + 1] = "null"
		end
	end
	enc(t)
	return table.concat(out)
end

local function html_escape(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	s = s:gsub('"', "&quot;"):gsub("'", "&#39;")
	return s
end

local function reboot_return_targets()
	local targets, seen = {}, {}
	local function add(url)
		if url and url ~= "" and not seen[url] then
			seen[url] = true
			targets[#targets + 1] = url
		end
	end

	-- The management endpoint is HTTPS-only; never offer an HTTP return URL.
	local scheme = "https"
	local host = http.getenv("HTTP_HOST") or http.getenv("SERVER_NAME") or ""
	host = host:gsub("[/%s].*$", "")

	local lan_ip = uget("network", "lan", "ipaddr") or ""
	if lan_ip:match("^%d+%.%d+%.%d+%.%d+$") then
		add(scheme .. "://" .. lan_ip .. "/")
		add("https://" .. lan_ip .. "/")
	end
	if host ~= "" then
		add(scheme .. "://" .. host .. "/")
	end
	add("https://192.168.0.1/")
	return targets
end

local function write_reboot_page(result)
	local targets = reboot_return_targets()
	local primary = targets[1] or "/"
	local links = {}
	for i, url in ipairs(targets) do
		links[#links + 1] = "<li><a href='" .. html_escape(url) .. "'>" ..
			html_escape(url) .. "</a>" .. (i == 1 and "（默认）" or "") .. "</li>"
	end
	http.write("<html><head><meta charset='utf-8'>" ..
		"<meta name='viewport' content='width=device-width,initial-scale=1'>" ..
		"<meta http-equiv='refresh' content='150;url=" .. html_escape(primary) .. "'>" ..
		"<style>body{font-family:Arial,sans-serif;margin:28px;line-height:1.6;color:#222}" ..
		".btn{display:inline-block;margin:14px 0;padding:8px 16px;border-radius:4px;background:#0069d9;color:#fff;text-decoration:none}" ..
		".muted{color:#666;font-size:13px}ul{padding-left:20px}</style>" ..
		"<script>var xponReturnTargets=" .. encode_json(targets) .. ";" ..
		"function xponReturnHome(){var i=parseInt(sessionStorage.getItem('xponReturnIndex')||'0',10);" ..
		"var url=xponReturnTargets[i%xponReturnTargets.length];sessionStorage.setItem('xponReturnIndex',String(i+1));location.href=url;return false;}</script>" ..
		"</head><body><h2>" .. html_escape(result) .. "</h2>" ..
		"<p>重启任务已创建，设备将在约 8 秒后整机重启。</p>" ..
		"<p>重启预计耗时 2-3 分钟，恢复后请重新登录核对当前生效值。</p>" ..
		"<a class='btn' href='" .. html_escape(primary) .. "' onclick='return xponReturnHome()'>返回管理首页</a>" ..
		"<p class='muted'>如果设备 LAN IP 已变更，请在恢复后尝试下面的备用入口：</p><ul>" ..
		table.concat(links, "") .. "</ul></body></html>")
end

function auth_values()
	local u = uci.cursor()
	local v = {}
	local private_saved = (uget("xpon", "device", "pon_mode") or "") ~= ""
	-- /etc/config/xpon 是抵抗 S00xponconfig 覆盖的持久源；仅在它没有值时
	-- 才回退到 network.xpon_auth。
	local function saved(field, dflt)
		local s
		if private_saved then
			s = uget("xpon", "device", field)
			if field:match("loid_password$") and s == '""' then s = "" end
			if s ~= nil and s ~= "" then return s end
		end
		s = uget("network", "xpon_auth", field)
		if field:match("loid_password$") and s == '""' then s = "" end
		if s ~= nil and s ~= "" then return s end
		return dflt
	end
	v.pon_mode          = saved("pon_mode", "GPON")
	v.auth_type_g       = saved("auth_type_g", "LOID")
	v.auth_method_g     = saved("auth_method_g", "")
	v.auth_type_e       = saved("auth_type_e", "LOID")
	local function saved_credential(prefix, field, dflt)
		local s
		local active_prefix = (v.pon_mode == "EPON") and "epon" or "gpon"
		if private_saved then
			s = uget("xpon", "device", prefix .. "_" .. field)
			if field == "loid_password" and s == '""' then return "" end
			if s ~= nil and s ~= "" then return s end
			return dflt
		end
		if field == "sn" then
			if prefix == "epon" then return dflt end
			if prefix == active_prefix then
				s = saved("sn", nil)
				if s ~= nil and s ~= "" then return s end
				return saved("def_sn", dflt)
			end
			return dflt
		end
		if prefix == active_prefix then
			return saved(field, dflt)
		end
		return dflt
	end
	v.epon_loid         = saved_credential("epon", "loid", "")
	v.epon_loid_password = saved_credential("epon", "loid_password", "")
	v.epon_sn           = saved_credential("epon", "sn", "")
	v.gpon_loid         = saved_credential("gpon", "loid", "")
	v.gpon_loid_password = saved_credential("gpon", "loid_password", "")
	v.gpon_sn           = saved_credential("gpon", "sn", "")
	if v.pon_mode == "EPON" then
		v.loid          = v.epon_loid
		v.loid_password = v.epon_loid_password
		v.sn            = v.epon_sn
	else
		v.loid          = v.gpon_loid
		v.loid_password = v.gpon_loid_password
		v.sn            = v.gpon_sn
	end
	v.xpon_sn_auth_type = saved("xpon_sn_auth_type", "ascii")
	-- PASSWORD（移动 SN+Password）落库为 SN + regid，读回时还原成独立选项。
	-- 新配置的 auth_method_g 是权威标记，优先于旧的 auth_type_g，避免
	-- network.xpon_auth 中残留的 sn 把页面错误地预选为“SN 密码认证”。
	local saved_method = v.auth_method_g:lower()
	if saved_method == "password" then
		v.auth_type_g = "password"
	elseif saved_method == "loid" then
		v.auth_type_g = "LOID"
	elseif saved_method == "sn" then
		v.auth_type_g = "sn"
	elseif v.auth_type_g:lower() == "sn" and v.xpon_sn_auth_type:lower() == "regid" then
		-- 旧配置没有 auth_method_g 时，按 SN+regid 兼容为 PASSWORD。
		v.auth_type_g = "password"
	end
	v.sn_ascii_password = saved("sn_ascii_password", "")
	v.sn_hex_password   = saved("sn_hex_password", "")
	v.sn_regid_password = saved("sn_regid_password", "")
	-- 页面只保留一个“SN 密码”输入框，格式由 xpon_sn_auth_type 决定（ascii/hex/regid）
	v.sn_password       = ((v.xpon_sn_auth_type == "hex") and v.sn_hex_password or
		(v.xpon_sn_auth_type == "regid") and v.sn_regid_password or v.sn_ascii_password) or ""
	-- 移动 Password = 独立 REG_ID 输入框，存 sn_regid_password（格式 regid）
	v.reg_id            = (v.xpon_sn_auth_type == "regid") and v.sn_regid_password or ""
	v.loid_password_set = v.loid_password ~= ""
	v.vendor_id         = uget("xpon", "device", "vendor_id") or ""
	v.equipment_id      = uget("network", "xpon_auth", "equipment_id") or uget("xpon", "device", "equipment_id") or ""
	v.onu_version       = uget("network", "xpon_auth", "onu_version") or uget("xpon", "device", "onu_version") or ""
	v.omcc_version      = uget("network", "xpon_auth", "omcc_version") or uget("xpon", "device", "omcc_version") or ""
	v.omci_spec_ver     = uget("xpon", "device", "omci_spec_ver") or ""
	v.epon_oui          = uget("xpon", "device", "epon_oui") or ""
	v.epon_ctc_oui      = uget("xpon", "device", "epon_ctc_oui") or ""
	v.epon_ven_info     = uget("xpon", "device", "epon_ven_info") or ""
	v.epon_onu_vendor_id = uget("xpon", "device", "epon_onu_vendor_id") or ""
	v.epon_serial       = uget("xpon", "device", "epon_serial") or ""
	-- 运行时读回（只读展示）：omcicfgCmd get 是 OMCI 层实际生效值，
	-- 输出格式 "field = value" 或 "ONU SN: value"（读不到 = 空串）
	local function omci_get(field)
		local out = sh("/userfs/bin/omcicfgCmd get " .. field .. " 2>&1") .. "\n"
		return out:match("[=:]%s*(.-)%s*\n") or ""
	end
	local function oam_get(field)
		local out = sh("/userfs/bin/oamcfgCmd get " .. field .. " 2>&1") .. "\n"
		return out:match("[=:]%s*(.-)%s*\n") or ""
	end
	local is_epon = v.pon_mode == "EPON"
	local function runtime_mac(s)
		local m = (s or ""):match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
		return m and m:upper() or ""
	end
	local rt = {
		loid         = is_epon and oam_get("loid0") or omci_get("loid"),
		sn           = is_epon and "" or omci_get("sn"),
		vendor_id    = is_epon and "" or omci_get("vendorId"),
		equipment_id = is_epon and "" or omci_get("equipmentId"),
		onu_version  = is_epon and "" or omci_get("onuVersion"),
		omcc_version = is_epon and "" or omci_get("omccVersion"),
		spec_ver     = is_epon and "" or (sh("/userfs/bin/omcicfgCmd get specVer 2>&1"):match("(%d+)") or ""),
		epon_oui     = is_epon and oam_get("localOui"):gsub("^0[xX]", ""):upper() or "",
		epon_ctc_oui = is_epon and oam_get("ctcOui"):gsub("^0[xX]", ""):upper() or "",
		epon_ven_info = is_epon and oam_get("localVenInfo"):gsub("^0[xX]", ""):upper() or "",
		epon_onu_vendor_id = is_epon and oam_get("onuVenID") or "",
		epon_serial = is_epon and runtime_mac(sh("/usr/bin/xpon-epon-sn.sh get 2>/dev/null")) or "",
	}
	local pon_ifconfig = sh("ifconfig pon 2>/dev/null")
	rt.pon_mac = runtime_mac(sh("cat /sys/class/net/pon/address 2>/dev/null"):match("([0-9A-Fa-f:]+)")
		or pon_ifconfig:match("HWaddr%s+([0-9A-Fa-f:]+)")
		or pon_ifconfig:match("ether%s+([0-9A-Fa-f:]+)") or "")
	-- ponmgr 的 devMac 通过 XMCS IO_IOG_ONU_MAC 调用 getPonMacfromflash()；
	-- ARMv8 平台最终仍读取本次启动 early_param("ethaddr") 的值。它是
	-- EPON 驱动生成 LLID 0..N 注册 MAC 的基准值，不是 pon netdev 地址，
	-- 也不是 EPON_ADDR_REG_LOW/HIGH 寄存器的直接读回。
	rt.epon_mac = is_epon and runtime_mac(ponmgr_cache("epon_devMac")) or ""
	if rt.epon_mac == "" then
		rt.epon_mac = runtime_mac(sh("awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ethaddr=/) { print substr($i, 9); exit } }' /proc/cmdline 2>/dev/null"))
	end
	if rt.epon_mac == "" then
		rt.epon_mac = runtime_mac(sh("fw_printenv -n ethaddr 2>/dev/null"))
	end
	-- 打开页面时，PON SN 是唯一的 GPON Vendor ID 输入源；OMCI 身份字段优先
	-- 回填当前运行态，运行态暂不可读时才使用持久值。
	-- 密码类不回显（留空 = 保持原值）。
	local function identity_fb(field, run, dflt)
		local s = uget("network", "xpon_auth", field)
		if s ~= nil and s ~= "" then return s end
		s = uget("xpon", "device", field)
		if s ~= nil and s ~= "" then return s end
		return (run ~= nil and run ~= "") and run or dflt
	end
	local function current_identity_fb(field, run, dflt)
		-- Show what the running OMCI engine currently uses; persisted values are
		-- only a fallback when the driver has not exposed a runtime value yet.
		if run ~= nil and run ~= "" then return run end
		return identity_fb(field, run, dflt)
	end
	-- 输入框默认显示当前系统生效值，用户可直接保存或修改。
	if #v.sn == 12 then
		v.vendor_id = v.sn:sub(1, 4):upper()
	elseif #v.vendor_id == 4 then
		v.vendor_id = v.vendor_id:upper()
	end
	v.equipment_id  = current_identity_fb("equipment_id", rt.equipment_id, "")
	v.onu_version   = current_identity_fb("onu_version", rt.onu_version, "")
	v.omcc_version  = current_identity_fb("omcc_version", rt.omcc_version, "")
	v.omci_spec_ver = current_identity_fb("omci_spec_ver", rt.spec_ver, "")
	if v.epon_ctc_oui == "" then
		v.epon_ctc_oui = "111111"
	end
	if v.epon_serial == "" then v.epon_serial = rt.epon_serial end
	local dsd_mac = dsd_wan_mac()
	local legacy_pon_mac = runtime_mac(uget("xpon", "device", "pon_mac") or "")
	local saved_epon_pon_mac = runtime_mac(uget("xpon", "device", "epon_pon_mac") or "")
	local saved_gpon_pon_mac = runtime_mac(uget("xpon", "device", "gpon_pon_mac") or "")
	-- SDK/固件路径不同：EPON 使用 MPCP ONU 注册 MAC，GPON 系列只设置 pon 业务接口 MAC。
	-- 旧版 pon_mac 仅作为升级兜底，不再让两种模式共用同一个持久值。
	v.epon_pon_mac = saved_epon_pon_mac ~= "" and saved_epon_pon_mac
		or (legacy_pon_mac ~= "" and legacy_pon_mac or (rt.epon_mac ~= "" and rt.epon_mac or dsd_mac))
	v.gpon_pon_mac = saved_gpon_pon_mac ~= "" and saved_gpon_pon_mac
		or (legacy_pon_mac ~= "" and legacy_pon_mac or (rt.pon_mac ~= "" and rt.pon_mac or dsd_mac))
	v.pon_mac = is_epon and v.epon_pon_mac or v.gpon_pon_mac
	v.epon_pon_mac_saved = saved_epon_pon_mac
	v.gpon_pon_mac_saved = saved_gpon_pon_mac
	v.pon_mac_saved = legacy_pon_mac
	if v.loid == "" and rt.loid ~= "" and rt.loid ~= "mtk1111" then v.loid = rt.loid end
	if (v.sn == "" or v.sn == "NoNumber") and rt.sn ~= "" then v.sn = rt.sn end
	v.pon_mac_default = dsd_mac
	v.dsd_fsan = dsd_fsan()
	v.dsd_clei_code = dsd_clei_code()
	v.dsd_lan_mac = dsd_raw_value("lan_mac")
	v.dsd_serial_number = dsd_raw_value("serial_number")
	v.dsd_manufacturer = dsd_raw_value("manufacturer")
	v.rt = rt
	local pmv = ponmode_values()
	local pt = saved("pon_tech", "")
	local pt_valid = false
	for _, t in ipairs(pon_techs) do
		if pt == t.id then pt_valid = true; break end
	end
	if not pt_valid then
		-- Upgrade/旧配置可能没有 pon_tech；优先按当前 onu_type 恢复
		-- 实际技术，避免所有 EPON 设备都被页面误显示成 10G/10G-EPON。
		pt = pon_tech_bits[pmv.run_tech] and pmv.run_tech
			or ((v.pon_mode == "EPON") and "EPON" or "GPON")
	end
	v.pon_tech          = pt
	v.pon_techs         = pon_techs
	v.onu_low           = pmv.cur_low
	v.onu_mode_run      = pmv.run_dec.label
	v.onu_mode_next     = pmv.env_dec.label
	v.onu_type_run      = pmv.run_dec.label
	v.onu_type_env      = pmv.env_dec.label
	v.onu_type_run_hex  = pmv.run_hex
	v.onu_type_env_hex  = pmv.env_hex
	v.onu_type_pending  = pmv.pending
	return v
end

local function service_key_from_section(s)
	local key = s.service_key or (s[".name"] or ""):match("^xpon_service_(.+)$") or s[".name"] or ""
	if #key > 16 or not key:match("^[A-Za-z0-9_]+$") then return nil end
	return key
end

local function service_key_base(access_mode, vlan_id)
	if access_mode == "untagged" then return "untag" end
	local vid = tonumber(vlan_id or "")
	if vid and vid >= 1 and vid <= 4094 then return tostring(vid) end
	return nil
end

local function service_pppname(seq)
	-- Airoha PPE parses nasX_Y as WAN index X*8+Y. Keep the first
	-- managed PPPoE as nas1_0, then advance through nas1_1 ... nas1_7.
	seq = tonumber(seq) or 1
	if seq < 1 then seq = 1 end
	local idx = seq + 7
	return "nas" .. tostring(math.floor(idx / 8)) .. "_" .. tostring(idx % 8)
end

local function service_iface_name(seq)
	return service_pppname(seq)
end

local function service_iface_seq(name)
	local bank, slot = tostring(name or ""):match("^nas([1-9][0-9]*)_([0-9]+)$")
	bank, slot = tonumber(bank), tonumber(slot)
	if not bank or not slot or slot > 7 then return nil end
	local seq = bank * 8 + slot - 7
	if seq < 1 then return nil end
	return seq
end

local function service_values()
	local rows, owners, untag_owner = {}, {}, nil
	local uc = uci.cursor()
	uc:foreach("network", "interface", function(s)
		local dev = s.device or ""
		local vid = dev:match("^pon%.(%d+)$")
		if vid then owners[vid] = s elseif dev == "pon" then untag_owner = s end
	end)
	uc:foreach("network", "xpon_service", function(s)
		local access_mode = s.access_mode == "untagged" and "untagged" or "tagged"
		local vid = tonumber(s.vlan_id or "")
		if s.xpon_managed == "1" and (access_mode == "untagged" or (vid and vid >= 1 and vid <= 4094)) then
			local key = service_key_from_section(s) or ("svc" .. tostring(#rows + 1))
			local shared_owner = access_mode == "untagged" and untag_owner or owners[tostring(vid)]
			local iface = s.interface or (service_iface_seq(key) and key) or service_iface_name(#rows + 1)
			local owner = shared_owner and shared_owner[".name"] == iface and shared_owner or nil
			local raw = sh("ubus call network.interface." .. iface .. " status 2>/dev/null")
			local up = raw:match('"up"%s*:%s*true') ~= nil
			local pending = raw:match('"pending"%s*:%s*true') ~= nil
			local uptime = raw:match('"uptime"%s*:%s*(%d+)') or ""
			local address = raw:match('"address"%s*:%s*"([0-9%.:]+)"') or ""
			local vlan_id = access_mode == "untagged" and "" or tostring(vid)
			local ifdev = access_mode == "untagged" and "pon" or ("pon." .. vlan_id)
			local row = {
				key=key, section=s[".name"], name="业务 " .. tostring(#rows + 1),
				access_mode=access_mode, access_label=access_mode == "untagged" and "untag" or "tag", ifdev=ifdev,
				vlan_id=vlan_id, priority=s.priority or "0", remark=s.remark or "",
				enable=s.enable ~= "0" and "1" or "0", service_type=s.service_type or "internet",
				mode=s.mode or s.payload or "routed", proto=s.proto or (owner and owner.proto) or "dhcp", mtu=s.mtu or (owner and owner.mtu) or "1500",
				username=s.username or (owner and owner.username) or "", ipaddr=s.ipaddr or (owner and owner.ipaddr) or "", netmask=s.netmask or (owner and owner.netmask) or "",
				password_set=((s.password and s.password ~= "") or (owner and owner.password and owner.password ~= "")) and true or nil,
				gateway=s.gateway or (owner and owner.gateway) or "", dns1=s.dns1 or "", dns2=s.dns2 or "",
				lan_port=s.lan_port or "none", mcast_vlan=s.mcast_vlan or "",
				interface=iface, external_owner=owner and owner.xpon_managed ~= "1" and owner[".name"] or nil,
				runtime=up, address=address, uptime=uptime,
				state=up and "已连接" or (pending and "连接中" or (s.enable == "0" and "已禁用" or "未连接"))
			}
			rows[#rows + 1] = row
		end
	end)
	table.sort(rows, function(a,b)
		local av = a.access_mode == "untagged" and -1 or tonumber(a.vlan_id) or 0
		local bv = b.access_mode == "untagged" and -1 or tonumber(b.vlan_id) or 0
		if av == bv then return a.key < b.key end
		return av < bv
	end)
	return rows
end

-- 语音配置。SDK 的启动脚本按 /proc/fxs/fxsNum 设置最大 line/account 数，
-- 并在双 FXS 时打开 VoIPLine2Enable；因此这里使用两个独立的账号 section。
-- 旧的 xpon.voice_auth 仍作为 FXS 1 的兼容 section。
local voice_line_defaults = {
	enable = "1", registrar = "", proxy = "", domain = "", username = "",
	auth_username = "", password = "", display_name = "", transport = "udp",
	port = "5060", expires = "3600", outbound_proxy = "", uri = "",
	register_username = "",
}

local voice_sdk_common_defs = {
	{ section = "VoIPSysParam_Common", stype = "VoIPSysParam_Common", title = "系统与 SIP 栈", fields = {
		{ key = "SC_SYS_CFG_MAX_CALL", label = "最大通话数", kind = "number", min = 1, max = 16, default = "4" },
		{ key = "SC_SYS_CFG_MAX_ACCT", label = "最大账号数", kind = "number", min = 1, max = 8, default = "2" },
		{ key = "SC_SYS_CFG_MAX_LINE", label = "最大线路数", kind = "number", min = 1, max = 8, default = "2" },
		{ key = "SlicFXSNum", label = "FXS 数量", kind = "number", min = 0, max = 8, default = "2" },
		{ key = "SlicFXONum", label = "FXO 数量", kind = "number", min = 0, max = 8, default = "0" },
		{ key = "SC_SYS_SIP_T1_INTERVAL", label = "SIP T1 间隔(ms)", kind = "number", min = 100, max = 10000, default = "1000" },
		{ key = "SC_SYS_SIP_TRANSPORT_TYPE", label = "SIP 传输类型", kind = "select", default = "0", options = { {"0", "UDP"}, {"1", "TCP"}, {"2", "TLS"} } },
		{ key = "SC_SYS_SIP_SUPPORTED", label = "SIP Supported", default = "100rel,timer" },
		{ key = "SC_SYS_SIP_REREG_TIME", label = "重注册提前时间(s)", kind = "number", min = 0, max = 86400, default = "450" },
		{ key = "SC_SYS_SPEED_UP_DIALING", label = "快速拨号", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_SYS_SPEED_UP_DIALING_STR", label = "快速拨号结束符", default = "#" },
		{ key = "SC_SYS_VOICE_JB_TYPE", label = "抖动缓冲类型", kind = "select", default = "1", options = { {"0", "固定"}, {"1", "自适应"} } },
		{ key = "SC_SYS_VOICE_JB_LEN", label = "抖动缓冲长度(ms)", kind = "number", min = 20, max = 1000, default = "200" },
		{ key = "SC_MEDIA_CODEC_TELEVT_PT", label = "电话事件 PT", kind = "number", min = 0, max = 127, default = "101" },
		{ key = "SC_MEDIA_CODEC_G726_16_PT", label = "G.726-16 PT", kind = "number", min = 0, max = 127, default = "96" },
		{ key = "SC_MEDIA_CODEC_G726_40_PT", label = "G.726-40 PT", kind = "number", min = 0, max = 127, default = "99" },
		{ key = "SC_MEDIA_CODEC_ILBC_PT", label = "iLBC PT", kind = "number", min = 0, max = 127, default = "104" },
		{ key = "SC_MEDIA_CODEC_SINGLE_CODEC", label = "单 Codec 协商", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_EMERG_ENABLE", label = "紧急呼叫", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_EMERG_REGISTRATION", label = "紧急呼叫需注册", kind = "select", default = "1", options = { {"1", "是"}, {"0", "否"} } },
		{ key = "SC_EMERG_NUM_GENERIC", label = "通用紧急号码", default = "112,911,119,110,120" },
		{ key = "SC_EMERG_NUM_POLICE", label = "警务紧急号码", default = "112,119,911" },
		{ key = "SC_EMERG_NUM_MEDICAL", label = "医疗紧急号码", default = "120,911" },
		{ key = "SC_EMERG_NUM_FIRE", label = "火警紧急号码", default = "119,911" },
		{ key = "SC_FAX_LEC_FORCE_OFF", label = "传真强制关闭 LEC", kind = "select", default = "1", options = { {"1", "是"}, {"0", "否"} } },
		{ key = "SC_FAX_PASSTHRU_PCMU", label = "传真透传 PCMU", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "SC_FAX_ONLY_TIMER", label = "传真检测时间(s)", kind = "number", min = 0, max = 600, default = "5" },
		{ key = "SC_FAX_REINV_RX", label = "接收传真 ReINVITE", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_FAX_T38_LEC_ON", label = "T.38 LEC", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "SC_FAX_T38_VERSION", label = "T.38 版本", kind = "number", min = 0, max = 3, default = "0" },
		{ key = "SC_FAX_T38_MAXRATE", label = "T.38 最大速率", kind = "number", min = 0, max = 15, default = "5" },
		{ key = "SC_FAX_T38_ECC_TYPE", label = "T.38 ECC 类型", kind = "number", min = 0, max = 3, default = "1" },
		{ key = "SC_FAX_T38_RATE_MGNT", label = "T.38 速率管理", kind = "number", min = 0, max = 3, default = "2" },
		{ key = "SC_FAX_T38_OPMODE", label = "T.38 工作模式", kind = "number", min = 0, max = 3, default = "0" },
		{ key = "SC_FTR_SERVICE_ENABLE", label = "补充业务总开关", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_FTR_HF_AND_DIGIT_ENABLE", label = "拍叉+数字", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_FTR_HOLD_STR", label = "保持特征码", default = "*52#" },
		{ key = "SC_FTR_HOLD_AND_ACCEPT_STR", label = "保持并接听", default = "*3#" },
		{ key = "SC_FTR_HOLD_AND_RETRIEVE_STR", label = "保持并恢复", default = "*4#" },
		{ key = "SC_FTR_RELEASE_AND_ACCEPT_STR", label = "释放并接听", default = "*1#" },
		{ key = "SC_FTR_RELEASE_AND_RETRIEVE_STR", label = "释放并恢复", default = "*2#" },
		{ key = "SC_FTR_CONF_DELETE_STR", label = "会议删除特征码", default = "#41#" },
		{ key = "SC_FTR_RELEASE_HOLD_STR", label = "释放保持特征码", default = "*8#" },
		{ key = "SC_FTR_REJECT_WAIT_STR", label = "拒接等待特征码", default = "*9#" },
	} },
	{ section = "VoIPBasic_Common", stype = "VoIPBasic_Common", title = "SIP 服务器", fields = {
		{ key = "SIPProtocol", label = "SIP 协议", kind = "select", default = "SIP", options = { {"SIP", "SIP"} } },
		{ key = "TelephoneEventPayloadType", label = "DTMF Payload Type", kind = "number", min = 0, max = 127, default = "101" },
		{ key = "LocalSIPPort", label = "本地 SIP 端口", kind = "number", min = 1, max = 65535, default = "5065" },
		{ key = "SIPProxyEnable", label = "SIP Proxy", kind = "select", default = "Yes", options = { {"Yes", "启用"}, {"No", "禁用"} } },
		{ key = "SIPProxyAddr", label = "主用服务器地址", default = "0.0.0.0" },
		{ key = "SIPProxyPort", label = "主用端口号", kind = "number", min = 1, max = 65535, default = "5060" },
		{ key = "RegistrarServer", label = "Registrar/注册服务器地址", default = "0.0.0.0" },
		{ key = "RegistrarServerPort", label = "Registrar/注册服务器端口", kind = "number", min = 1, max = 65535, default = "5060" },
		{ key = "SBSIPProxyAddr", label = "备用服务器地址", default = "0.0.0.0" },
		{ key = "SBSIPProxyPort", label = "备用端口号", kind = "number", min = 1, max = 65535, default = "5060" },
		{ key = "SBRegistrarServer", label = "备用 Registrar 地址", default = "0.0.0.0" },
		{ key = "SBRegistrarServerPort", label = "备用 Registrar 端口", kind = "number", min = 1, max = 65535, default = "5060" },
		{ key = "SIPOutboundProxyEnable", label = "Outbound Proxy", kind = "select", default = "Yes", options = { {"Yes", "启用"}, {"No", "禁用"} } },
		{ key = "SIPOutboundProxyAddr", label = "Outbound 服务器地址", default = "0.0.0.0" },
		{ key = "SIPOutboundProxyPort", label = "Outbound 服务器端口号", kind = "number", min = 1, max = 65535, default = "5060" },
		{ key = "SBOutboundProxyAddr", label = "备用 Outbound 服务器地址", default = "0.0.0.0" },
		{ key = "SBOutboundProxyPort", label = "备用 Outbound 服务器端口号", kind = "number", min = 1, max = 65535, default = "5060" },
		{ key = "ProxyIsOutbound", label = "Proxy 同时作为 Outbound", kind = "select", default = "0", options = { {"0", "否"}, {"1", "是"} } },
		{ key = "SIPDSCPMark", label = "SIP DSCP", kind = "number", min = 0, max = 63, default = "26" },
		{ key = "RTPDSCPMark", label = "RTP DSCP", kind = "number", min = 0, max = 63, default = "44" },
		{ key = "SC_ACCT_SIP_SESSION_FLAG", label = "Session Timer", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SC_ACCT_SIP_SESSION_REFRESHER", label = "Session Refresher", kind = "number", min = 0, max = 2, default = "0" },
		{ key = "SC_ACCT_SIP_SESSION_METHOD", label = "Session 刷新方法", kind = "number", min = 0, max = 2, default = "0" },
		{ key = "SC_ACCT_SIP_SESSION_MIN_EXP", label = "Session 最小周期(s)", kind = "number", min = 0, max = 86400, default = "0" },
		{ key = "SC_ACCT_SIP_SESSION_TIMER", label = "Session 周期(s)", kind = "number", min = 0, max = 86400, default = "0" },
		{ key = "reg_max_retry", label = "注册最大重试", kind = "number", min = 0, max = 999, default = "10" },
		{ key = "HeartbeatSwitch", label = "心跳开关", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "HeartbeatCycle", label = "心跳周期(s)", kind = "number", min = 1, max = 86400, default = "60" },
		{ key = "VoIPLine2Enable", label = "第二路语音", kind = "select", default = "Yes", options = { {"Yes", "启用"}, {"No", "禁用"} } },
	} },
	{ section = "VoIPAdvanced_Common", stype = "VoIPAdvanced_Common", title = "高级 SIP/区域", fields = {
		{ key = "RegistrationExpire", label = "注册有效期(s)", kind = "number", min = 60, max = 86400, default = "3600" },
		{ key = "RegisterRetryInterval", label = "注册重试间隔(s)", kind = "number", min = 1, max = 3600, default = "60" },
		{ key = "MaxStartDelay", label = "最大启动延迟(s)", kind = "number", min = 0, max = 600, default = "10" },
		{ key = "DTMFTransportMode", label = "DTMF 传输", kind = "select", default = "InBand", options = { {"InBand", "InBand"}, {"RFC2833", "RFC2833"}, {"SIPInfo", "SIP INFO"} } },
		{ key = "DTMFRfc283310000", label = "RFC2833 PT 映射", default = "10000;10001" },
		{ key = "FaxPassThruCodec", label = "传真透传 Codec", kind = "select", default = "PCMA", options = { {"PCMA", "PCMA"}, {"PCMU", "PCMU"} } },
		{ key = "FaxCtrlMode", label = "传真控制模式", kind = "select", default = "all", options = { {"all", "全部"}, {"t38", "T.38"}, {"passThrough", "透传"} } },
		{ key = "SIPDomain", label = "归属域名", default = "" },
		{ key = "VoIPRegion", label = "区域", default = "CHN-CHINA" },
		{ key = "VoIPBindWanIf", label = "绑定 WAN/接口", default = "br-lan" },
		{ key = "IPProtocal", label = "IP 协议族", kind = "select", default = "IPV4", options = { {"IPV4", "IPv4"}, {"IPV6", "IPv6"}, {"IPV4V6", "IPv4/IPv6"} } },
		{ key = "NumberMatchMode", label = "号码匹配模式", kind = "number", min = 0, max = 9, default = "2" },
		{ key = "VoiceCodecPriorityCtrl", label = "Codec 优先级控制", kind = "select", default = "0", options = { {"0", "默认"}, {"1", "启用"} } },
	} },
	{ section = "VoIPMedia_Common", stype = "VoIPMedia_Common", title = "媒体与 QoS", fields = {
		{ key = "LocalRTPPort", label = "RTP 起始端口", kind = "number", min = 1, max = 65535, default = "41000" },
		{ key = "LocalRTPPortEnd", label = "RTP 结束端口", kind = "number", min = 1, max = 65535, default = "42000" },
		{ key = "SC_SF_CS_PROTOCOL", label = "媒体协议标识", kind = "number", min = 0, max = 255, default = "0" },
		{ key = "SC_ACCT_MEDIA_G723_RATE", label = "G.723 速率", kind = "select", default = "0", options = { {"0", "6.3k"}, {"1", "5.3k"} } },
		{ key = "FaxCodec", label = "Fax Codec", kind = "number", min = 0, max = 255, default = "0" },
		{ key = "EchoCancellationEnable", label = "回声消除", kind = "select", default = "Yes", options = { {"Yes", "启用"}, {"No", "禁用"} } },
		{ key = "EchoCancellationLowSpeedFax", label = "低速传真回声消除", kind = "select", default = "", options = { {"", "默认"}, {"Yes", "启用"}, {"No", "禁用"} } },
	} },
	{ section = "VoIPDigitMap_Entry", stype = "VoIPDigitMap_Entry", title = "拨号规则", fields = {
		{ key = "DigitMapEnable", label = "DigitMap", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "DigitMapSpecialEnable", label = "特殊 DigitMap", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "PBXPrefixEnable", label = "PBX 前缀", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "NoAnswerTimer", label = "无应答时间(s)", kind = "number", min = 1, max = 600, default = "60" },
		{ key = "InterDigitTimerShort", label = "短位间超时(s)", kind = "number", min = 1, max = 60, default = "3" },
		{ key = "InterDigitTimerLong", label = "长位间超时(s)", kind = "number", min = 1, max = 120, default = "10" },
		{ key = "StartDigitTimer", label = "首位超时(s)", kind = "number", min = 1, max = 120, default = "10" },
		{ key = "BusyToneTimer", label = "忙音时间(s)", kind = "number", min = 1, max = 600, default = "40" },
		{ key = "DigitMap1", label = "DigitMap1", default = "" },
		{ key = "DigitMap2", label = "DigitMap2", default = "" },
		{ key = "ServiceMap", label = "ServiceMap", default = "" },
		{ key = "PBXPrefix", label = "PBXPrefix", default = "" },
	} },
}

local voice_line_sdk_defs = {
	{ prefix = "VoIPCallCtrl_Entry", stype = "VoIPCallCtrl_Entry", title = "补充业务", fields = {
		{ key = "SIPMWIEnable", label = "MWI 消息灯", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "SIPDNDEnable", label = "免打扰", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "SIPCallWaitingEnable", label = "呼叫等待", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SyncCallerTimeEnable", label = "来电时间同步", kind = "select", default = "1", options = { {"1", "启用"}, {"0", "禁用"} } },
		{ key = "SIPCallerIdEnable", label = "主叫号码显示", kind = "select", default = "2", options = { {"0", "禁用"}, {"1", "启用"}, {"2", "自动"} } },
		{ key = "SIPCallTransfer", label = "呼叫转移/转接", kind = "select", default = "Yes", options = { {"Yes", "启用"}, {"No", "禁用"} } },
		{ key = "SIP3wayConf", label = "三方通话", kind = "select", default = "Yes", options = { {"Yes", "启用"}, {"No", "禁用"} } },
		{ key = "HotLineEnable", label = "热线", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "HotLineDelayTime", label = "热线延迟(s)", kind = "number", min = 0, max = 600, default = "5" },
		{ key = "NoAnswerNCFWaitTime", label = "无应答前转等待(s)", kind = "number", min = 1, max = 600, default = "60" },
		{ key = "MTKUCFEnable", label = "无条件前转", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "MTKSIPUCFNumber", label = "无条件前转号码", default = "" },
		{ key = "MTKBCFEnable", label = "遇忙前转", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "MTKSIPBCFNumber", label = "遇忙前转号码", default = "" },
		{ key = "MTKNCFEnable", label = "无应答前转", kind = "select", default = "0", options = { {"0", "禁用"}, {"1", "启用"} } },
		{ key = "MTKSIPNCFNumber", label = "无应答前转号码", default = "" },
		{ key = "HotLineNumber", label = "热线号码", default = "*53#" },
		{ key = "SIPBlindTransferNumber", label = "盲转特征码", default = "*12*" },
		{ key = "SIPAttendedTransferNumber", label = "咨询转特征码", default = "*12#" },
		{ key = "SIP3wayConfNumber", label = "三方通话特征码", default = "*333" },
		{ key = "HookMaxInterval", label = "拍叉最大(ms)", kind = "number", min = 1, max = 5000, default = "500" },
		{ key = "HookMinInterval", label = "拍叉最小(ms)", kind = "number", min = 1, max = 5000, default = "90" },
		{ key = "HookReleaseMin", label = "挂机最小(ms)", kind = "number", min = 1, max = 5000, default = "550" },
	} },
	{ prefix = "VoIPAdvanced_Entry", stype = "VoIPAdvanced_Entry", title = "线路电气/音量", fields = {
		{ key = "SubscribeType", label = "订阅类型", kind = "number", min = 0, max = 9, default = "0" },
		{ key = "SubscribeExpire", label = "订阅周期(s)", kind = "number", min = 0, max = 86400, default = "0" },
		{ key = "SC_LINE_CID_PWR", label = "来显功率", kind = "number", min = 0, max = 20, default = "6" },
		{ key = "VoiceVolumeSpeak", label = "发送音量", kind = "number", min = -12, max = 12, default = "0" },
		{ key = "VoiceVolumeListen", label = "接收音量", kind = "number", min = -12, max = 12, default = "0" },
	} },
	{ prefix = "VoIPMedia_Entry", stype = "VoIPMedia_Entry", title = "线路媒体", fields = {
		{ key = "SilenceCompressionEnable", label = "静音压缩", kind = "select", default = "No", options = { {"No", "禁用"}, {"Yes", "启用"} } },
		{ key = "SIPSupportedCodecs0", label = "支持 Codec 0", default = "" },
		{ key = "SIPSupportedCodecs1", label = "支持 Codec 1", default = "" },
		{ key = "SIPSupportedCodecs2", label = "支持 Codec 2", default = "" },
		{ key = "SIPSupportedCodecs3", label = "支持 Codec 3", default = "" },
		{ key = "SIPSupportedCodecs4", label = "支持 Codec 4", default = "" },
	} },
}

local voice_codec_names = {
	"G.722", "G.711 U-law", "G.729", "G.711 A-law", "G.723",
	"G.726 - 16", "G.726 - 24", "G.726 - 32", "G.726 - 40",
}

local function voice_field_name(section, key)
	return "sdk_" .. section .. "_" .. key
end

local function voice_line_sdk_section(def, line)
	return def.prefix .. tostring(line - 1)
end

local voice_line_account_tcapi_fields = {
	"SC_ACCT_NAT_TYPE", "Enable", "SIPDisplayName", "SIPAuthenticationName",
	"SIPPassword", "SIPURI", "SIPRegisterUserName", "SIPUserName",
}

local function voice_line_values(u, section, legacy, line)
	local result = {}
	local account_section = line and ("VoIPBasic_Entry" .. tostring(line - 1)) or nil
	local function account_value(key)
		return account_section and u:get("xpon", account_section, key) or nil
	end
	for name, default in pairs(voice_line_defaults) do
		local value = u:get("xpon", section, name)
		if value == nil and legacy then value = u:get("xpon", legacy, name) end
		if value == nil and account_section then
			if name == "enable" then
				local enabled = account_value("Enable")
				if enabled ~= nil then value = enabled == "Yes" and "1" or "0" end
			elseif name == "uri" then
				value = account_value("SIPURI")
			elseif name == "register_username" then
				value = account_value("SIPRegisterUserName")
			elseif name == "username" then
				value = account_value("SIPUserName") or account_value("SIPRegisterUserName")
			elseif name == "auth_username" then
				value = account_value("SIPAuthenticationName")
			elseif name == "password" then
				value = account_value("SIPPassword")
			elseif name == "display_name" then
				value = account_value("SIPDisplayName")
			end
		end
		result[name] = value ~= nil and value or default
	end
	if section == "voice_auth_line2" and u:get("xpon", section, "enable") == nil
		and u:get("xpon", legacy or "", "enable") ~= nil then
		result.enable = "0"
	end
	result.password_set = result.password ~= ""
	return result
end

local function voice_line_count()
	local fxs = tonumber(sh("cat /proc/fxs/fxsNum 2>/dev/null | head -1")) or 0
	local fxo = tonumber(sh("cat /proc/fxs/fxoNum 2>/dev/null | head -1")) or 0
	local line_count = fxs + fxo
	if line_count < 1 then
		-- SDK 设备缺少 /proc/fxs 时，按本项目目标 MTK 双 FXS 预留两路。
		line_count = 2
	end
	return math.min(line_count, 2)
end

local function voice_sdk_section_values(u, section, fields)
	local out = {}
	for _, f in ipairs(fields or {}) do
		local value = u:get("xpon", section, f.key)
		out[f.key] = value ~= nil and value or (f.default or "")
	end
	return out
end

local function voice_codec_values(u, pvc)
	local rows = {}
	local pvc_section = "VoIPCodecs_PVC" .. tostring(pvc)
	for i, codec in ipairs(voice_codec_names) do
		local idx = i - 1
		local section = "VoIPCodecs_PVC" .. tostring(pvc) .. "_Entry" .. tostring(idx)
		rows[#rows + 1] = {
			section = section,
			codec = u:get("xpon", section, "codec") or codec,
			Enable = u:get("xpon", section, "Enable") or (pvc == 0 and (idx == 1 or idx == 2) and "Yes" or (pvc == 1 and "Yes" or "No")),
			priority = u:get("xpon", section, "priority") or ((pvc == 0 and (idx == 1 or idx == 2) or (pvc == 1 and idx >= 1 and idx <= 4)) and tostring(idx) or "0"),
		}
	end
	return { ptime = u:get("xpon", pvc_section, "SIPPacketizationTime") or "20", rows = rows }
end

local function voice_values()
	local u = uci.cursor()
	local status = sh("pidof sipclient 2>/dev/null")
	local service_vlan = u:get("xpon", "voice", "vlan")
		or u:get("network", "xpon_voice", "vlan_id")
		  or ""
	local sdk_common, sdk_lines = {}, {}
	for _, def in ipairs(voice_sdk_common_defs) do
		sdk_common[def.section] = voice_sdk_section_values(u, def.section, def.fields)
	end
	for line = 1, 2 do
		sdk_lines[line] = {}
		for _, def in ipairs(voice_line_sdk_defs) do
			local section = voice_line_sdk_section(def, line)
			sdk_lines[line][section] = voice_sdk_section_values(u, section, def.fields)
		end
	end
	return {
		lines = {
			voice_line_values(u, "voice_auth", nil, 1),
			voice_line_values(u, "voice_auth_line2", "voice_auth", 2),
		},
		line_count = voice_line_count(),
		vlan = service_vlan,
		running = status ~= "",
		pid = status,
		sdk_common_defs = voice_sdk_common_defs,
		sdk_line_defs = voice_line_sdk_defs,
		sdk_common = sdk_common,
		sdk_lines = sdk_lines,
		codecs = { voice_codec_values(u, 0), voice_codec_values(u, 1) },
	}
end

local function voice_host_ok(value, optional)
	value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if optional and value == "" then return true end
	if #value == 0 or #value > 255 then return false end
	for i = 1, #value do
		local b = value:byte(i)
		if not b or b < 33 or b > 126 or value:sub(i, i) == "'" then return false end
	end
	return true
end

local function voice_text_ok(value, max_len, optional)
	value = value or ""
	if optional and value == "" then return true end
	if #value == 0 or #value > max_len then return false end
	for i = 1, #value do
		local b = value:byte(i)
		if not b or b < 32 or b > 126 or value:sub(i, i) == "'" then return false end
	end
	return true
end

local function voice_sdk_value_ok(value, f)
	value = value or ""
	if #value > (f.max_len or 255) then return false end
	for i = 1, #value do
		local b = value:byte(i)
		if not b or b < 32 or b > 126 or value:sub(i, i) == "'" then return false end
	end
	if f.kind == "number" then
		local n = tonumber(value)
		if not n then return false end
		if f.min and n < f.min then return false end
		if f.max and n > f.max then return false end
	elseif f.kind == "select" then
		local found = false
		for _, opt in ipairs(f.options or {}) do
			if value == opt[1] then found = true; break end
		end
		if not found then return false end
	end
	return true
end

local function save_voice_sdk_field(u, section, stype, f, fv)
	local value = (fv(voice_field_name(section, f.key)) or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if not voice_sdk_value_ok(value, f) then return nil, section .. "_" .. f.key end
	if not ensure_section(u, "xpon", section, stype) then return nil, "voice_sdk_section" end
	u:set("xpon", section, f.key, value)
	return true
end

local function voice_tcapi_apply_cmd()
	local cmds = { "if [ -x /userfs/bin/tcapi ]; then" }
	local function add(section, key)
		cmds[#cmds + 1] = "/userfs/bin/tcapi set " .. section .. " " .. key ..
			" \"$(uci -q get xpon." .. section .. "." .. key .. ")\" >/dev/null 2>&1"
	end
	for _, def in ipairs(voice_sdk_common_defs) do
		for _, f in ipairs(def.fields or {}) do add(def.section, f.key) end
	end
	for line = 1, 2 do
		for _, def in ipairs(voice_line_sdk_defs) do
			local section = voice_line_sdk_section(def, line)
			for _, f in ipairs(def.fields or {}) do add(section, f.key) end
		end
		local account_section = "VoIPBasic_Entry" .. tostring(line - 1)
		for _, key in ipairs(voice_line_account_tcapi_fields) do add(account_section, key) end
	end
	for pvc = 0, 1 do
		local pvc_section = "VoIPCodecs_PVC" .. tostring(pvc)
		add(pvc_section, "SIPPacketizationTime")
		for i = 1, #voice_codec_names do
			local section = pvc_section .. "_Entry" .. tostring(i - 1)
			add(section, "codec")
			add(section, "Enable")
			add(section, "priority")
		end
	end
	cmds[#cmds + 1] = "fi"
	return table.concat(cmds, "; ")
end

local function save_voice(fv)
	local u = uci_native.cursor()
	local function save_line(index, section, legacy)
		local function value(name)
			return (fv("line" .. index .. "_" .. name) or ""):gsub("^%s+", ""):gsub("%s+$", "")
		end
		local enabled = value("enable") == "1" and "1" or "0"
		local registrar, proxy = value("registrar"), value("proxy")
		local domain, username = value("domain"), value("username")
		local uri, register_username = value("uri"), value("register_username")
		local auth_username, display_name = value("auth_username"), value("display_name")
		local outbound_proxy, transport = value("outbound_proxy"), value("transport"):lower()
		local port, expires = tonumber(value("port")), tonumber(value("expires"))
		local old_password = u:get("xpon", section, "password")
			or (legacy and u:get("xpon", legacy, "password"))
			or ""
		local password = value("password")
		if password == "" then password = old_password end

		if enabled == "1" and not voice_host_ok(registrar, false) then return nil, "line" .. index .. "_registrar" end
		if not voice_host_ok(proxy, true) then return nil, "line" .. index .. "_proxy" end
		if not voice_host_ok(domain, true) then return nil, "line" .. index .. "_domain" end
		if not voice_host_ok(outbound_proxy, true) then return nil, "line" .. index .. "_outbound_proxy" end
		if not voice_text_ok(uri, 128, true) then return nil, "line" .. index .. "_uri" end
		if not voice_text_ok(register_username, 128, true) then return nil, "line" .. index .. "_register_username" end
		if username == "" then username = register_username end
		if auth_username == "" then auth_username = register_username ~= "" and register_username or username end
		if enabled == "1" and not voice_text_ok(username, 128, false) then return nil, "line" .. index .. "_username" end
		if not voice_text_ok(auth_username, 128, true) then return nil, "line" .. index .. "_auth_username" end
		if not voice_text_ok(display_name, 64, true) then return nil, "line" .. index .. "_display_name" end
		if transport ~= "udp" and transport ~= "tcp" and transport ~= "tls" then return nil, "line" .. index .. "_transport" end
		if not port or port < 1 or port > 65535 then return nil, "line" .. index .. "_port" end
		if not expires or expires < 60 or expires > 86400 then return nil, "line" .. index .. "_expires" end
		if not voice_text_ok(password, 128, true) then return nil, "line" .. index .. "_password" end

		if not ensure_section(u, "xpon", section, "voice_auth") then return nil, "voice_section" end
		local fields = {
			enable = enabled, registrar = registrar, proxy = proxy, domain = domain,
			username = username, auth_username = auth_username, password = password,
			uri = uri, register_username = register_username,
			display_name = display_name, transport = transport, port = tostring(port),
			expires = tostring(expires), outbound_proxy = outbound_proxy,
		}
		for name, field_value in pairs(fields) do u:set("xpon", section, name, field_value) end

		local account_section = "VoIPBasic_Entry" .. tostring(index - 1)
		if not ensure_section(u, "xpon", account_section, "VoIPBasic_Entry") then return nil, "voice_account_section" end
		u:set("xpon", account_section, "SC_ACCT_NAT_TYPE", u:get("xpon", account_section, "SC_ACCT_NAT_TYPE") or "0")
		u:set("xpon", account_section, "Enable", enabled == "1" and "Yes" or "No")
		u:set("xpon", account_section, "SIPDisplayName", display_name ~= "" and display_name or uri)
		u:set("xpon", account_section, "SIPAuthenticationName", auth_username)
		u:set("xpon", account_section, "SIPPassword", password)
		u:set("xpon", account_section, "SIPURI", uri)
		u:set("xpon", account_section, "SIPRegisterUserName", register_username)
		u:set("xpon", account_section, "SIPUserName", username)
		return true
	end

	local ok, why = save_line(1, "voice_auth", nil)
	if not ok then return nil, why end
	ok, why = save_line(2, "voice_auth_line2", "voice_auth")
	if not ok then return nil, why end
	if not ensure_section(u, "xpon", "voice", "service") then return nil, "voice_service" end
	for _, def in ipairs(voice_sdk_common_defs) do
		for _, f in ipairs(def.fields or {}) do
			ok, why = save_voice_sdk_field(u, def.section, def.stype, f, fv)
			if not ok then return nil, why end
		end
	end
	if not ensure_section(u, "xpon", "VoIPBasic_Common", "VoIPBasic_Common") then return nil, "voice_sdk_section" end
	u:set("xpon", "VoIPBasic_Common", "VoIPLine2Enable", fv("line2_enable") == "1" and "Yes" or "No")
	for line = 1, 2 do
		for _, def in ipairs(voice_line_sdk_defs) do
			local section = voice_line_sdk_section(def, line)
			for _, f in ipairs(def.fields or {}) do
				ok, why = save_voice_sdk_field(u, section, def.stype, f, fv)
				if not ok then return nil, why end
			end
		end
	end
	for pvc = 0, 1 do
		local ptime = (fv("codec_pvc" .. pvc .. "_ptime") or "20"):gsub("^%s+", ""):gsub("%s+$", "")
		local ptime_num = tonumber(ptime)
		if not ptime_num or ptime_num < 10 or ptime_num > 200 then return nil, "codec_pvc" .. pvc .. "_ptime" end
		local pvc_section = "VoIPCodecs_PVC" .. tostring(pvc)
		if not ensure_section(u, "xpon", pvc_section, pvc_section) then return nil, "voice_codec_section" end
		u:set("xpon", pvc_section, "SIPPacketizationTime", tostring(ptime_num))
		for i, codec in ipairs(voice_codec_names) do
			local idx = i - 1
			local section = "VoIPCodecs_PVC" .. tostring(pvc) .. "_Entry" .. tostring(idx)
			local enable = fv("codec_pvc" .. pvc .. "_entry" .. idx .. "_enable") == "Yes" and "Yes" or "No"
			local priority = tonumber(fv("codec_pvc" .. pvc .. "_entry" .. idx .. "_priority") or "0")
			if not priority or priority < 0 or priority > 9 then return nil, "codec_pvc" .. pvc .. "_entry" .. idx .. "_priority" end
			if not ensure_section(u, "xpon", section, section) then return nil, "voice_codec_entry" end
			u:set("xpon", section, "codec", codec)
			u:set("xpon", section, "Enable", enable)
			u:set("xpon", section, "priority", tostring(priority))
		end
	end
	local ok, commit_ok = pcall(function()
		u:save("xpon")
		commit_ok = u:commit("xpon")
	end)
	if not ok or commit_ok == false then return nil, "voice_commit" end
	return true
end

local function kernel_vlan_values()
	local rows, by_vid, refs = {}, {}, {}
	local function ref(vid, text)
		vid = tostring(vid or "")
		if vid ~= "" then refs[vid] = refs[vid] or {}; refs[vid][#refs[vid] + 1] = text end
	end
	local uc = uci.cursor()
	uc:foreach("network", nil, function(s)
		if s[".type"] == "xpon_service" then ref(s.vlan_id, "业务 " .. (s.remark or s.service_key or s[".name"])) end
		if s[".type"] == "wan_vlan" then ref(s.vlan_id, "旧 wan_vlan " .. s[".name"]) end
		local vid = (s.name or s.device or ""):match("^pon%.(%d+)$")
		if vid then ref(vid, s[".type"] .. " " .. s[".name"]) end
	end)
	uci.cursor():foreach("pon", "multicast_vlan", function(s) ref(s.interface_vid, "组播 VLAN " .. (s.vlan_id or "")) end)
	uci.cursor():foreach("xpon", "service", function(s) ref(s.vlan, "旧业务 " .. s[".name"]) end)
	local raw = sh("cat /proc/net/vlan/config 2>/dev/null")
	for name, vid in raw:gmatch("(pon%.(%d+))%s+|%s+%d+%s+|%s+pon") do
		-- Lua 多捕获中第二项就是 VID；name 保留用于兼容不同固件格式。
		vid = name:match("(%d+)$") or vid
		if vid and not by_vid[vid] then
			local r = { name="pon." .. vid, vlan_id=vid, refs=refs[vid] or {}, orphan=(refs[vid] == nil) }
			rows[#rows + 1] = r; by_vid[vid] = r
		end
	end
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return rows
end

function action_service_vlan()
	local vid = tonumber(formvalue("vlan_id") or "")
	if not vid or vid < 1 or vid > 4094 then http.redirect(xpon_url("services", "err=vlan")); return end
	for _, row in ipairs(kernel_vlan_values()) do
		if tonumber(row.vlan_id) == vid then
			if not row.orphan then http.redirect(xpon_url("services", "err=vlan_in_use_" .. vid)); return end
			local rc = sys.call("( timeout 3 vconfig rem pon." .. vid .. " || timeout 3 ip link del pon." .. vid .. " ) >/tmp/xpon-vlan-cleanup.log 2>&1")
			http.redirect(xpon_url("services", rc == 0 and ("vlan_cleaned=" .. vid) or ("err=vlan_cleanup_" .. rc))); return
		end
	end
	http.redirect(xpon_url("services", "err=vlan_not_found"))
end

local function multicast_values()
	local rows, by_vid, registered, bindings = {}, {}, {}, {}
	local raw = sh("/usr/bin/pon-multicast status")
	local snooping, proxy = raw:match("control=([01]),([01])")
	local runtime_snooping, runtime_proxy = raw:match("runtime_control=([01]),([01])")
	local proxy_port = raw:match("proxy_port=([1-4])") or "1"
	local runtime_proxy_port, runtime_proxy_func = raw:match("runtime_proxy_port=([1-4]),([012])")
	local merr = formvalue("merr")
	local error_text = {
		backend_permission = "后端脚本不可执行（权限错误）",
		backend_missing = "后端脚本不存在",
		proxy_port = "代理绑定端口无效",
	}
	for vid in raw:gmatch("mvlan=(%d+)") do registered[vid] = true end
	for port, vid in raw:gmatch("binding=(%d+),(%d+)") do bindings[vid] = port end
	for vid, ifvid, configured_bound, configured_port in
		raw:gmatch("config=(%d+),(%d+),([01]),(%d+)") do
		if vid:match("^%d+$") and ifvid:match("^%d+$") then
			local bound = bindings[ifvid] ~= nil
			local row = { vlan_id=vid, interface_vid=ifvid, bound=bound,
				port=bindings[ifvid] or configured_port or "1", configured=true,
				configured_bound=(configured_bound == "1"),
				state=registered[vid] and (bound and "bound" or "registered") or "error" }
			rows[#rows + 1] = row
			by_vid[vid] = row
		end
	end
	for vid in pairs(registered) do
		if not by_vid[vid] then rows[#rows + 1] = { vlan_id=vid, interface_vid="", bound=false, port="0", state="registered", configured=false } end
	end
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return {
		rows=rows, result=raw, error=error_text[merr] or merr, ok=formvalue("mok"),
		snooping=snooping or "1", proxy=proxy or "0",
		runtime_snooping=runtime_snooping, runtime_proxy=runtime_proxy,
		proxy_port=proxy_port, runtime_proxy_port=runtime_proxy_port,
		runtime_proxy_func=runtime_proxy_func,
	}
end

local function iptv_business_values()
	local rows, seen = {}, {}
	local port_map = { lan1="1", lan2="2", lan3="3", lan4="4" }
	uci.cursor():foreach("network", "xpon_service", function(s)
		local vid = tonumber(s.vlan_id or "")
		if s.service_type == "iptv" and vid and vid >= 1 and vid <= 4094 and not seen[vid] then
			rows[#rows + 1] = { vlan_id=tostring(vid), name=s.remark or "IPTV", port=port_map[s.lan_port] or "1" }; seen[vid] = true
		end
	end)
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return rows
end

function action_multicast()
	local op = formvalue("op") or ""
	if op == "control" then
		local snooping = formvalue("snooping") == "1" and "1" or "0"
		local proxy = formvalue("proxy") == "1" and "1" or "0"
		local proxy_port = tonumber(formvalue("proxy_port") or "")
		if not proxy_port or proxy_port < 1 or proxy_port > 4 then
			http.redirect(xpon_url("services", "merr=proxy_port"))
			return
		end
		if proxy == "1" then snooping = "1" end
		local rc = sys.call(string.format(
			"/usr/bin/pon-multicast control %s %s %d >/tmp/pon-multicast-action.log 2>&1",
			snooping, proxy, proxy_port))
		local result = rc == 0 and "mok=control" or
			(rc == 126 and "merr=backend_permission" or
			(rc == 127 and "merr=backend_missing" or ("merr=driver_" .. rc)))
		http.redirect(xpon_url("services", result))
		return
	end
	local vid = tonumber(formvalue("vlan_id") or "")
	if not vid or vid < 1 or vid > 4094 then
		http.redirect(xpon_url("services", "merr=vlan")); return
	end
	local cmd
	if op == "add" then
		local ver = tonumber(formvalue("igmp_version") or "2") or 2
		local ifvid = tonumber(formvalue("interface_vid") or "")
		local port
		for _, b in ipairs(iptv_business_values()) do if tonumber(b.vlan_id) == ifvid then port = tonumber(b.port) end end
		if not port or port < 1 or port > 4 or (ver ~= 2 and ver ~= 3) or not ifvid or ifvid < 1 or ifvid > 4094 then
			http.redirect(xpon_url("services", "merr=options")); return
		end
		if sh("ip link show pon." .. ifvid) == "" then
			http.redirect(xpon_url("services", "merr=interface")); return
		end
		cmd = string.format("/usr/bin/pon-multicast add %d %d %d %d", vid, ifvid, port, ver)
	elseif op == "bind" then
		cmd = string.format("/usr/bin/pon-multicast bind %d %s", vid, formvalue("bound") == "1" and "1" or "0")
	elseif op == "delete" then
		cmd = string.format("/usr/bin/pon-multicast delete %d", vid)
	else
		http.redirect(xpon_url("services", "merr=operation")); return
	end
	local rc = sys.call(cmd .. " >/tmp/pon-multicast-action.log 2>&1")
	local result
	if rc == 0 then
		if op == "delete" then
			local nu = uci.cursor()
			nu:foreach("network", "xpon_service", function(s)
				if tonumber(s.mcast_vlan or "") == vid then nu:delete("network", s[".name"], "mcast_vlan") end
			end)
			nu:save("network"); nu:commit("network")
			local xu = uci.cursor()
			xu:foreach("xpon", "service", function(s)
				if tonumber(s.mcast_vlan or "") == vid then xu:delete("xpon", s[".name"], "mcast_vlan") end
			end)
			xu:save("xpon"); xu:commit("xpon")
		end
		result = "mok=1"
	elseif rc == 126 then
		result = "merr=backend_permission"
	elseif rc == 127 then
		result = "merr=backend_missing"
	else
		result = "merr=driver_" .. rc
	end
	http.redirect(xpon_url("services", result))
end

-- 组播 M-VLAN“实际登记”只读快照：读 /tmp/xpon-mvlan-act.txt（由 xpon-mvlan-snap.sh
-- 后台刷新，LuCI 绝不直接调 xponigmpcmd——该 ioctl 可能阻塞，同步调用会挂起页面）。
local function mvlan_snapshot()
	local raw = sh("cat /tmp/xpon-mvlan-act.txt 2>/dev/null")
	local ids = {}
	for v in (raw or ""):gmatch("vlan=(%d+)") do
		local n = tonumber(v)
		if n and n >= 1 and n <= 4094 then ids[#ids + 1] = n end
	end
	table.sort(ids)
	return ids, raw
end

function ponmode_values()
	local boot = onu_boot_values()
	local sys_mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")

	-- 当前生效 hex（cmdline 优先），用于预选与缺省技术推导
	local cur_hex = boot.run_hex
	local cur_bits = tonumber(cur_hex, 16)
	local cur_tech = (cur_bits and pon_tech_by_bits[math.floor(cur_bits / 16)]) or nil
	-- ONU 形态只看 onu_type 最后一位：1=SFU、2=HGU。
	local cur_low = cur_hex:match("([12])$") or "1"

	-- PON 技术以当前 cmdline/env 为准，UCI 仅保存认证参数，不能驱动模式。
	local tech = cur_tech or "XGPON"
	local saved_tech = uget("network", "xpon_auth", "pon_tech") or uget("xpon", "device", "pon_tech") or ""
	local tech_mismatch = (cur_tech ~= nil and pon_tech_bits[saved_tech] ~= nil and saved_tech ~= cur_tech)
	local tech_name = tech
	for _, t in ipairs(pon_techs) do
		if t.id == tech then tech_name = t.name end
	end

	-- 本页只选 SFU/HGU，始终保留 env 中的 PON 技术高半字节。
	local forms = {
		{ low = "2", short = "HGU", name = "HGU（家庭网关）", desc = "国内运营商默认：LAN 桥接 + VEIP + IPTV 组播完整" },
		{ low = "1", short = "SFU", name = "SFU（桥形态）", desc = "纯桥/实验：无 VEIP 与 LAN 侧组播引擎" },
	}
	local opts = {}
	for _, f in ipairs(forms) do
		opts[#opts + 1] = {
			low = f.low, short = f.short, name = f.name, desc = f.desc,
			hex = onu_type_hex(tech, f.low),
		}
	end

	-- sys_xpon_mode 枚举，供“技术详情”展开
	local sys_mode_names = {
		[1] = "GPON", [2] = "EPON", [3] = "10G_1G_EPON", [4] = "10G_10G_EPON",
		[5] = "1G_1G_EPON", [6] = "XGPON", [7] = "XGSPON", [8] = "NGPON2_10G_10G",
		[9] = "NGPON2_10G_2G", [10] = "NGPON2_2G_2G", [11] = "GPON_SYM", [12] = "TURBO_EPON",
	}
	local sys_modes = {}
	for i = 1, 12 do
		sys_modes[#sys_modes + 1] = {
			id = i,
			name = pon_mode_names[i] or ("未知(" .. i .. ")"),
			detail = sys_mode_names[i] or "",
		}
	end

	-- PON VLAN 接口列表（内核 802.1q：pon.<VID>，用于 PPPoE/静态 IP 拨号）
	local vlans = {}
	local function add_vlan(name, vid, pri)
		local n = tonumber(vid)
		if name and n and n >= 1 and n <= 4094 then
			vlans[#vlans + 1] = { name = name, vid = n, pbit = tonumber(pri) or 0 }
		end
	end
	local vc = sh("cat /proc/net/vlan/config 2>/dev/null")
	-- 空列表诊断（帮助区分“真没有接口”还是“读表途径缺失”）
	local vlan_diag = {}
	-- 方式1：/proc/net/vlan/config 逐行解析，兼容三种内核输出：
	--   Name: pon.100  VID: 100  REORDER_HDR: 1 ...（5.x）
	--   Name:"pon.100" VID: 100 PRIORITY: 0 ...（老内核）
	--   pon.100  VID: 100  REORDER_HDR: 1 ...（更老）
	for line in (vc .. "\n"):gmatch("([^\n]+)") do
		local name, vid = line:match('Name:%s*"?(pon%.[0-9]+)"?%s+VID:%s*(%d+)')
		if not name then
			name, vid = line:match("(pon%.[0-9]+)%s+VID:%s*(%d+)")
		end
		if name then add_vlan(name, vid, 0) end
	end
	-- 方式2：紧凑旧格式 pon.100 100 0x0000 ...
	if #vlans == 0 then
		for name, vid, pri in vc:gmatch("(pon%.[0-9]+)%s+([0-9]+)%s+([0-9xXa-fA-F]+)%s") do
			add_vlan(name, vid, pri)
		end
	end
	-- 方式3：/proc/net/vlan/ 目录列举
	if #vlans == 0 then
		local vdir = sh("ls /proc/net/vlan/ 2>/dev/null")
		for name in vdir:gmatch("(pon%.[0-9]+)") do
			add_vlan(name, name:match("(%d+)$"), 0)
		end
		if vdir == "" then
			vlan_diag[#vlan_diag + 1] = "/proc/net/vlan/ 目录不可读"
		end
	end
	-- 方式4：ip -o link show type vlan（iproute2）
	if #vlans == 0 then
		local o2 = sh("ip -o link show type vlan 2>/dev/null")
		for name, vid in o2:gmatch("(pon%.[0-9]+)@[^:%s]+:[^\n]* vlan protocol 802%.1Q id (%d+)") do
			add_vlan(name, vid, 0)
		end
	end
	-- 方式5：ifconfig 兜底
	if #vlans == 0 then
		for name in sh("ifconfig 2>/dev/null"):gmatch("(pon%.[0-9]+)") do
			add_vlan(name, name:match("(%d+)$"), 0)
		end
	end
	-- 方式6：sysfs /sys/class/net（8021q 接口必然注册，最可靠兜底）
	local sf = sh("ls /sys/class/net/ 2>/dev/null")
	if #vlans == 0 then
		for name in sf:gmatch("(pon%.[0-9]+)") do
			add_vlan(name, name:match("(%d+)$"), 0)
		end
	end
	table.sort(vlans, function(a, b) return (a.vid or 0) < (b.vid or 0) end)

	if vc == "" then
		vlan_diag[#vlan_diag + 1] = "/proc/net/vlan/config 不存在或为空"
	elseif #vlans == 0 then
		local head = vc:gsub("%s+", " "):sub(1, 120)
		vlan_diag[#vlan_diag + 1] = "config 未匹配（原文：" .. head .. "）"
	end
	if #vlans == 0 then
		local dhead = sh("ls -1 /proc/net/vlan/ 2>/dev/null | tr '\\n' ' '"):sub(1, 80)
		local ihead = sh("ifconfig 2>/dev/null | grep '^pon' | tr '\\n' ' '"):sub(1, 80)
		local shead = sf:gsub("%s+", " "):sub(1, 120)
		vlan_diag[#vlan_diag + 1] = "proc目录[" .. dhead .. "] ifconfig[" .. ihead .. "] sysfs[" .. shead .. "]"
	end
	-- 8021q 是否可用以 /proc/net/vlan 目录为准（内核模块可能编入内核，lsmod 查不到）；
	-- 且已有 pon.<VID> 接口时绝不误报
	if #vlans == 0 and sh("[ -d /proc/net/vlan ] && echo y") ~= "y" then
		vlan_diag[#vlan_diag + 1] = "8021q 未加载（/proc/net/vlan 不存在）"
	end
	if sh("command -v vconfig 2>/dev/null") == "" then
		vlan_diag[#vlan_diag + 1] = "vconfig 缺失（自动改用 ip link 建口）"
	end
	vlan_diag = table.concat(vlan_diag, "；")

	-- 已持久化的 wan_vlan 段（系统启动时自动创建 pon.<VID>）；
	-- 同时收集段内组播 M-VLAN（mcast_vlan 自定义字段）供当前接口列表回显
	local persisted = {}
	local mvid_by_vid = {}
	pcall(function()
		uci.cursor():foreach("network", "wan_vlan", function(s)
			local pvid = tonumber(s.vlan_id or "")
			if pvid and pvid >= 1 and pvid <= 4094 then
				if s.mcast_vlan and s.mcast_vlan ~= "" then mvid_by_vid[pvid] = s.mcast_vlan end
				local present = false
				for _, vl in ipairs(vlans) do
					if vl.vid == pvid then present = true break end
				end
				persisted[#persisted + 1] = {
					name = s[".name"] or "",
					vid = pvid,
					payload = s.payload or "routed",
					mcast = s.mcast_vlan or "",
					present = present,
				}
			end
		end)
	end)
	table.sort(persisted, function(a, b) return a.vid < b.vid end)
	for _, vl in ipairs(vlans) do
		vl.mcast = mvid_by_vid[vl.vid] or ""
	end

	local mvlan_act, mvlan_cnt_raw = mvlan_snapshot()

	return {
		env           = boot.env,
		env_hex       = boot.env_hex,
		fwenv_hex     = boot.fwenv_hex,
		bootargs_hex  = boot.bootargs_hex,
		cmdline       = boot.cmdline,
		pending       = boot.pending,
		sys_mode      = sys_mode,
		sys_mode_name = pon_mode_names[tonumber(sys_mode)] or "未知",
		pon_tech      = tech,
		pon_tech_name = tech_name,
		pon_tech_short = pon_tech_short_names[tech] or "未知",
		saved_tech_short = pon_tech_short_names[saved_tech] or "未知",
		run_tech_short = pon_tech_short_names[cur_tech] or "未知",
		tech_mismatch = tech_mismatch,
		run_tech      = cur_tech,
		run_hex       = boot.run_hex,
		run_dec       = boot.run_dec,
		env_dec       = boot.env_dec,
		forms         = opts,
		cur_low       = cur_low,
		sys_modes     = sys_modes,
		ko            = sh("lsmod 2>/dev/null | awk '$1 ~ /^xpon/ {print $1}' | tr '\\n' ' '"),
		bbf_gpon      = sh("if [ -e /proc/gpon/bbf247Flag ]; then cat /proc/gpon/bbf247Flag; fi"),
		bbf_xgpon     = sh("if [ -e /proc/xgpon/bbf247Flag ]; then cat /proc/xgpon/bbf247Flag; fi"),
		vlans         = vlans,
		persisted     = persisted,
		vlan_diag     = vlan_diag,
		vlan_cfg_raw  = vc,
		vlan_dir_raw  = sh("ls -1 /proc/net/vlan/ 2>/dev/null"),
		vlan_if_raw   = sh("ifconfig 2>/dev/null | grep -E '^(pon|eth)'"),
		vlan_ip_raw   = sh("ip -o link show type vlan 2>/dev/null"),
		mvlan_act     = mvlan_act,
		mvlan_cnt_raw = mvlan_cnt_raw,
	}
end

-- 模式页 PON VLAN 操作结果提示（?vlan=add|del|bad&rc=&vid=）
local function vlan_msg_for(vlan, rc, vid)
	if vlan == "add" then
		if rc == "ok" then
			return ("已创建 <code>pon.%s</code> 802.1q 接口（已写入 network wan_vlan，重启自动重建；组播 VLAN 已写入配置，登记由后台执行、开机自动重放）。"):format(vid), true
		end
		return ("创建 <code>pon.%s</code> 失败：确认 pon 口存在、8021q 模块已加载（<code>lsmod | grep 8021q</code>）。"):format(vid), false
	elseif vlan == "del" then
		return ("已删除 <code>pon.%s</code> 接口（若勾选持久化，对应 network wan_vlan 段已清除）。"):format(vid), true
	elseif vlan == "bad" then
		return "VLAN ID 不合法（需 1~4094）。", false
	elseif vlan == "err" then
		return "PON VLAN 操作失败（内部错误，详见系统日志）。", false
	end
	return nil, true
end

------------------------------------------------------------------------
-- 保存
------------------------------------------------------------------------

local function validate_vid(s)
	local n = tonumber(s or "")
	return n ~= nil and n >= 1 and n <= 4094
end

-- 组播 M-VLAN 列表：接受单个或逗号分隔 VLAN（含全角逗号），去重保序，仅保留 1~4094
local function parse_mvids(s)
	local seen, out = {}, {}
	for m in (s or ""):gsub("[,，]+", ","):gmatch("(%d+)") do
		local n = tonumber(m)
		if n and n >= 1 and n <= 4094 and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	return out
end

-- 创建 pon.<VID> 802.1q 拨号子接口 + 持久化 wan_vlan 段 + 登记组播 M-VLAN。
-- 设备 VLAN 创建流程：vconfig add pon <VID> → up →
-- set_egress_map / set_ingress_map（Pbit）；组播登记 xpon_ani_pass_mvlan（xpon_igmp_core.c）。
-- 返回 (ok, exists)：exists=接口是否创建成功（决定 rc=ok/fail）。
local function ponvlan_add(vid, pbit, mvids)
	local existing, unmanaged = nil, false
	uci.cursor():foreach("network", "wan_vlan", function(s)
		if s.vlan_id == tostring(vid) then
			if s.xpon_managed == "1" then existing = s[".name"] else unmanaged = true end
		end
	end)
	if unmanaged then return false, false end
	local ok = pcall(function()
		if sh("command -v vconfig 2>/dev/null") ~= "" then
			sys.call("timeout 3 vconfig add pon " .. vid .. " 2>/dev/null")
			if pbit > 0 then
				sys.call("timeout 3 vconfig set_egress_map pon." .. vid .. " 0 " .. pbit .. " 2>/dev/null")
				sys.call("timeout 3 vconfig set_ingress_map pon." .. vid .. " 0 " .. pbit .. " 2>/dev/null")
			end
		else
			sys.call("timeout 3 ip link add link pon name pon." .. vid .. " type vlan id " .. vid .. " 2>/dev/null")
		end
		sys.call("timeout 3 ifconfig pon." .. vid .. " up 2>/dev/null")
		logger("xpon", ("ponvlan_add vid=%s pbit=%s mvids=%s"):format(vid, pbit, table.concat(mvids, ",")))
		-- 持久化（必做）：netifd 的 wan_vlan 段会在启动时创建 pon.<VID>，
		-- 段内 mcast_vlan 为自定义字段（netifd 忽略），由 xpon-mvlan.sh 重启重放登记
		local u = uci.cursor()
		local sec = existing
		if not sec then
			sec = "pon_vlan_" .. vid
			ensure_section(u, "network", sec, "wan_vlan")
			u:set("network", sec, "vlan_id", tostring(vid))
			u:set("network", sec, "payload", "routed")
		end
		u:set("network", sec, "xpon_managed", "1")
		if #mvids > 0 then
			u:set("network", sec, "mcast_vlan", table.concat(mvids, ","))
			-- 组播登记改后台异步：xponigmpcmd 在部分环境会阻塞 ioctl，
			-- 同步执行会让 LuCI 请求挂起（表现为“保存后登出”）。UCI 已持久化，
			-- 即使这里失败，xpon-app 开机 / xpon-mvlan.sh 也会重放登记。
			local bg = {}
			for _, m in ipairs(mvids) do
				bg[#bg + 1] = "/userfs/bin/xponigmpcmd mvlan del " .. m .. " >/dev/null 2>&1"
				bg[#bg + 1] = "/userfs/bin/xponigmpcmd mvlan add " .. m .. " >/dev/null 2>&1"
			end
			bg[#bg + 1] = "/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1"
			sys.call("( " .. table.concat(bg, "; ") .. " ) >/dev/null 2>&1 </dev/null &")
		else
			u:delete("network", sec, "mcast_vlan")
		end
		u:save("network")
		u:commit("network")
	end)
	local exists = sh("timeout 3 ip link show pon." .. vid .. " 2>/dev/null")
	if exists == "" then exists = sh("timeout 3 ifconfig pon." .. vid .. " 2>/dev/null") end
	return ok, exists ~= ""
end

-- 删除 pon.<VID>；del_persist=1 时连带删除 wan_vlan 段并清组播 M-VLAN 登记
local function ponvlan_del(vid, del_persist)
	if del_persist then
		local owned = false
		uci.cursor():foreach("network", "wan_vlan", function(s)
			if s.vlan_id == tostring(vid) and s.xpon_managed == "1" then owned = true end
		end)
		if not owned then return false end
	end
	return pcall(function()
		sys.call("(timeout 3 vconfig rem pon." .. vid .. " 2>/dev/null || timeout 3 ip link del pon." .. vid .. " 2>/dev/null)")
		logger("xpon", "ponvlan_del vid=" .. vid .. " persist=" .. tostring(del_persist))
		if del_persist then
			local u = uci.cursor()
			u:foreach("network", "wan_vlan", function(s)
				if s.vlan_id == tostring(vid) and s.xpon_managed == "1" then
					local bg = {}
					for _, m in ipairs(parse_mvids(s.mcast_vlan)) do
						bg[#bg + 1] = "/userfs/bin/xponigmpcmd mvlan del " .. m .. " >/dev/null 2>&1"
					end
					if #bg > 0 then
						bg[#bg + 1] = "/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1"
						sys.call("( " .. table.concat(bg, "; ") .. " ) >/dev/null 2>&1 </dev/null &")
					end
					u:delete("network", s[".name"])
				end
			end)
			u:save("network")
			u:commit("network")
		end
	end)
end

-- Equipment ID：可选；非空时允许 1~24 个可打印 ASCII 字符。
local function ascii24_optional(s)
	if #s == 0 then return true end
	if #s > 24 then return false end
	for i = 1, #s do
		local b = s:byte(i)
		if not (b >= 32 and b <= 126) then return false end
	end
	return true
end

local function ascii4_optional(s)
	if #s == 0 then return true end
	if #s ~= 4 then return false end
	for i = 1, #s do
		local b = s:byte(i)
		if not (b >= 32 and b <= 126) then return false end
	end
	return true
end

-- OMCI 协议版本 specVer：固件存 uint8（0~255），接受十进制或 0x 十六进制
local function specver_ok(s)
	s = (s or ""):gsub("%s+", "")
	if s == "" then return true end
	local n = tonumber(s)
	if not n and s:match("^0[xX][0-9a-fA-F]+$") then
		n = tonumber(s:sub(3), 16)
	end
	return n ~= nil and n >= 0 and n <= 255
end

-- Lua pattern 不支持正则表达式的 {n,m} 数量语法，长度必须显式判断。
local function hex_len(s, min_len, max_len)
	s = s or ""
	return #s >= min_len and #s <= max_len and s:match("^%x+$") ~= nil
end

local function normalize_omccver(s)
	s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return "" end
	local n
	if s:match("^0[xX]%x+$") then
		n = tonumber(s:sub(3), 16)
	elseif s:match("^%x+$") and s:match("[a-fA-F]") then
		n = tonumber(s, 16)
	elseif s:match("^%d+$") then
		-- 一至两位数字沿用界面的十六进制语义；三位数字按十进制兼容。
		n = (#s <= 2) and tonumber(s, 16) or tonumber(s, 10)
	end
	if not n or n < 0 or n > 255 then return nil end
	return string.format("0x%02X", n)
end

local function ponmac_ok(s)
	return #(s or "") == 17 and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function save_auth(fv)
	if not ensure_xpon_config_file() then
		return nil, "persist_config_xpon"
	end
	-- 认证持久化使用固件自带的原生 uci.so，绕开 luci.model.uci 的 ubus
	-- session 包装层；后者对新增的 xpon package 可能返回成功但没有落盘。
	local u = uci_native.cursor()
	local ptech = fv("pon_tech") or "GPON"
	local valid = {}
	for _, t in ipairs(pon_techs) do valid[t.id] = true end
	if not valid[ptech] then ptech = "GPON" end
	local pmode = pon_engine_for(ptech)
	local auth_type = fv("auth_type_g") or "LOID"
	-- netifd 对 auth_type 的 sn / LOID 值做精确匹配，
	-- 只认 SN* 或 LOID 两种：REG_ID（移动 Password）= SN + regid 密码，落库为 SN + xpon_sn_auth_type=regid
	local snf = (fv("xpon_sn_auth_type") or "ascii"):lower()
	local ui_auth = auth_type:lower()
	local auth_method = ui_auth
	if ui_auth == "regid" then
		auth_type, snf = "sn", "regid"
		auth_method = "password"
	elseif ui_auth == "password" then
		auth_type, snf = "sn", "regid"
		auth_method = "password"
	elseif ui_auth == "loid" then
		auth_type = "LOID"
		auth_method = "loid"
	else
		auth_type = "sn"
		auth_method = "sn"
	end
	local active_prefix = (pmode == "EPON") and "epon" or "gpon"
	local private_saved = (u:get("xpon", "device", "pon_mode") or "") ~= ""
	local function stored_mode_credential(field)
		local s = u:get("xpon", "device", active_prefix .. "_" .. field)
		if field == "loid_password" and s == '""' then return "" end
		if s ~= nil and s ~= "" then return s end
		if private_saved then return "" end
		if field == "sn" then
			if active_prefix == "epon" then return "" end
			s = u:get("xpon", "device", "sn") or u:get("xpon", "device", "def_sn")
				or u:get("network", "xpon_auth", "sn") or u:get("network", "xpon_auth", "def_sn")
		else
			s = u:get("xpon", "device", field) or u:get("network", "xpon_auth", field)
		end
		if field == "loid_password" and s == '""' then s = "" end
		return s or ""
	end
	local loid = fv("loid") or ""
	local submitted_loid_password = fv("loid_password") or ""
	local stored_loid_password = stored_mode_credential("loid_password")
	local loid_password = submitted_loid_password ~= "" and submitted_loid_password
		or (fv("loid_password_clear") == "1" and "" or stored_loid_password)
	if (pmode == "EPON" or auth_type == "LOID") and #loid_password > 12 then
		return nil, "loid_password"
	end
	local function stored_sn_password(fmt)
		local field = fmt == "hex" and "sn_hex_password"
			or fmt == "regid" and "sn_regid_password" or "sn_ascii_password"
		return u:get("xpon", "device", field)
			or u:get("network", "xpon_auth", field) or ""
	end
	local stored_regid_password = stored_sn_password("regid")
	-- EPON/XEPON 用 auth_type_e（TYPE_EPON_AUTH），EPON 只支持 LOID 认证，必须大写
	local auth_type_e = "LOID"
	-- 页面只接收完整 PON SN；GPON Vendor ID 始终由前 4 位派生。
	local sn = (fv("sn") or stored_mode_credential("sn") or ""):gsub("%s+", ""):upper()
	if sn == "NONUMBER" then sn = "" end
	local vendor_id = (#sn == 12) and sn:sub(1, 4) or ""
	-- 空值表示恢复 DSD wan_mac。GPON 仅应用到 pon 业务接口；
	-- EPON 将最终值写入 U-Boot ethaddr。当前 XG2010G U-Boot 使用 FIT DTB
	-- 命令行并清除 legacy bootargs，因此这里不创建或修改 bootargs。
	local epon_pon_mac = (fv("epon_pon_mac") or fv("pon_mac") or ""):gsub("%s+", ""):upper()
	local gpon_pon_mac = (fv("gpon_pon_mac") or fv("pon_mac") or ""):gsub("%s+", ""):upper()
	local active_pon_mac = pmode == "EPON" and epon_pon_mac or gpon_pon_mac
	local effective_pon_mac = active_pon_mac ~= "" and active_pon_mac or dsd_wan_mac()
	-- EPON OUI = 最终 EPON 注册 MAC 前 3 字节，留空使用 DSD 时也保持联动。
	local eoui = (fv("epon_oui") or ""):gsub("%s+", ""):upper()
	if pmode == "EPON" and ponmac_ok(effective_pon_mac) then
		-- EPON localOui is the ONU OUI and must follow the MPCP registration MAC.
		eoui = effective_pon_mac:gsub(":", ""):sub(1, 6):upper()
	end
	local ectc = (fv("epon_ctc_oui") or ""):gsub("%s+", ""):upper()
	if ectc == "" then ectc = "111111" end
	local eonu_vendor = fv("epon_onu_vendor_id") or ""
	local epon_serial = (fv("epon_serial") or ""):gsub("%s+", ""):upper()
	local even = (fv("epon_ven_info") or ""):gsub("%s+", ""):upper()
	-- OMCI 协议版本（spec_version）：固件存 uint8；omcicfgCmd 用 atoi 解析 -> 统一落库为十进制
	local equipment_id = (fv("equipment_id") or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local onu_version = (fv("onu_version") or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local omci_spec_ver = (fv("omci_spec_ver") or ""):gsub("%s+", "")
	local omcc_version = normalize_omccver(fv("omcc_version")) or ""
	if omci_spec_ver ~= "" then
		local svn = tonumber(omci_spec_ver)
		if not svn and omci_spec_ver:match("^0[xX][0-9a-fA-F]+$") then
			svn = tonumber(omci_spec_ver:sub(3), 16)
		end
		if svn and svn >= 0 and svn <= 255 then
			omci_spec_ver = tostring(svn)
		else
			omci_spec_ver = ""
		end
	end

	local network_ok = ensure_section(u, "network", "xpon_auth", "xpon_auth")
	if not network_ok then return nil, "persist_section_network" end
	u:set("network", "xpon_auth", "pon_mode", pmode)
	u:set("network", "xpon_auth", "pon_tech", ptech)
	if pmode == "EPON" then
		u:set("network", "xpon_auth", "auth_type_e", auth_type_e)
		u:delete("network", "xpon_auth", "auth_type_g")
		u:delete("network", "xpon_auth", "auth_method_g")
	else
		u:set("network", "xpon_auth", "auth_type_g", auth_type)
		u:set("network", "xpon_auth", "auth_method_g", auth_method)
		u:delete("network", "xpon_auth", "auth_type_e")
	end
	if pmode == "EPON" or auth_type == "LOID" then
		if loid ~= "" then u:set("network", "xpon_auth", "loid", loid) end
	else
		u:delete("network", "xpon_auth", "loid")
		u:delete("network", "xpon_auth", "loid_password")
	end
	if pmode == "EPON" or auth_type == "LOID" then
		-- 空 LOID 密码必须保留为明确配置；字面 "" 经原厂 netifd/shell
		-- 展开为空参数，避免缺省路径继续注入 Econet。
		u:set("network", "xpon_auth", "loid_password", loid_password ~= "" and loid_password or '""')
	end
	if sn ~= "" then
		u:set("network", "xpon_auth", "def_sn", sn)
		u:set("network", "xpon_auth", "sn", sn)
	elseif pmode == "EPON" then
		u:delete("network", "xpon_auth", "def_sn")
		u:delete("network", "xpon_auth", "sn")
	end
	u:set("network", "xpon_auth", "xpon_sn_auth_type", snf)
	if pmode == "EPON" then
		u:delete("network", "xpon_auth", "equipment_id")
		u:delete("network", "xpon_auth", "onu_version")
		u:delete("network", "xpon_auth", "omcc_version")
		u:delete("network", "xpon_auth", "omci_spec_ver")
		u:set("network", "xpon_auth", "epon_oui", eoui)
		u:set("network", "xpon_auth", "epon_ctc_oui", ectc)
		u:set("network", "xpon_auth", "epon_ven_info", even)
		if eonu_vendor ~= "" then u:set("network", "xpon_auth", "epon_onu_vendor_id", eonu_vendor) else u:delete("network", "xpon_auth", "epon_onu_vendor_id") end
		if epon_serial ~= "" then u:set("network", "xpon_auth", "epon_serial", epon_serial) else u:delete("network", "xpon_auth", "epon_serial") end
		if epon_pon_mac ~= "" then u:set("network", "xpon_auth", "epon_pon_mac", epon_pon_mac) else u:delete("network", "xpon_auth", "epon_pon_mac") end
		u:delete("network", "xpon_auth", "gpon_pon_mac")
	else
		if equipment_id ~= "" then u:set("network", "xpon_auth", "equipment_id", equipment_id) else u:delete("network", "xpon_auth", "equipment_id") end
		if onu_version ~= "" then u:set("network", "xpon_auth", "onu_version", onu_version) else u:delete("network", "xpon_auth", "onu_version") end
		if omcc_version ~= "" then u:set("network", "xpon_auth", "omcc_version", omcc_version) else u:delete("network", "xpon_auth", "omcc_version") end
		if gpon_pon_mac ~= "" then u:set("network", "xpon_auth", "gpon_pon_mac", gpon_pon_mac) else u:delete("network", "xpon_auth", "gpon_pon_mac") end
		u:delete("network", "xpon_auth", "epon_oui")
		u:delete("network", "xpon_auth", "epon_ctc_oui")
		u:delete("network", "xpon_auth", "epon_ven_info")
		u:delete("network", "xpon_auth", "epon_onu_vendor_id")
		u:delete("network", "xpon_auth", "epon_serial")
		u:delete("network", "xpon_auth", "epon_pon_mac")
	end
	-- 移动 Password = 只填 REG_ID（regid ≤36）；留空保持旧值，避免只切换认证类型却丢失密码。
	local submitted_regid = fv("reg_id") or ""
	local snpwd = ""
	if pmode ~= "EPON" then
		snpwd = (ui_auth == "password") and
			(submitted_regid ~= "" and submitted_regid or stored_regid_password) or
			(fv("sn_password") or "")
		if ui_auth == "password" and snpwd == "" then
			return nil, "reg_id"
		elseif snpwd == "" then
			snpwd = stored_sn_password(snf)
		end
	end
	if pmode ~= "EPON" and snpwd ~= "" then
		if snf == "hex" then
			u:set("network", "xpon_auth", "sn_hex_password", snpwd)
			u:delete("network", "xpon_auth", "sn_ascii_password")
			u:delete("network", "xpon_auth", "sn_regid_password")
		elseif snf == "regid" then
			u:set("network", "xpon_auth", "sn_regid_password", snpwd)
			u:delete("network", "xpon_auth", "sn_ascii_password")
			u:delete("network", "xpon_auth", "sn_hex_password")
		else
			u:set("network", "xpon_auth", "sn_ascii_password", snpwd)
			u:delete("network", "xpon_auth", "sn_hex_password")
			u:delete("network", "xpon_auth", "sn_regid_password")
		end
	end
	if pmode == "EPON" then
		u:delete("network", "xpon_auth", "xpon_sn_auth_type")
		u:delete("network", "xpon_auth", "sn_ascii_password")
		u:delete("network", "xpon_auth", "sn_hex_password")
		u:delete("network", "xpon_auth", "sn_regid_password")
	end

	-- 镜像到 /etc/config/xpon（auth 类型段 device）：开机 restore-auth 的持久源，
	-- 抵消 S00xponconfig 每次开机把 network.xpon_auth 打回 sn 的问题
	local device_ok = ensure_section(u, "xpon", "device", "auth")
	if not device_ok then return nil, "persist_section_device" end
	u:set("xpon", "device", "pon_mode", pmode)
	u:set("xpon", "device", "pon_tech", ptech)
	if pmode == "EPON" then
		u:set("xpon", "device", "auth_type_e", auth_type_e)
		-- Keep GPON auth preferences in the persistent source so switching
		-- back from EPON restores the previous LOID/SN/PASSWORD selection.
		u:set("xpon", "device", "auth_type_g", auth_type)
		u:set("xpon", "device", "auth_method_g", auth_method)
	else
		u:set("xpon", "device", "auth_type_g", auth_type)
		u:set("xpon", "device", "auth_method_g", auth_method)
		u:delete("xpon", "device", "auth_type_e")
	end
	if loid ~= "" then
		u:set("xpon", "device", active_prefix .. "_loid", loid)
	end
	u:set("xpon", "device", active_prefix .. "_loid_password", loid_password ~= "" and loid_password or '""')
	if sn ~= "" then
		u:set("xpon", "device", active_prefix .. "_sn", sn)
	elseif active_prefix == "epon" then
		u:delete("xpon", "device", active_prefix .. "_sn")
	end
	for _, shared in ipairs({ "loid", "loid_password", "def_sn", "sn" }) do
		u:delete("xpon", "device", shared)
	end
	u:set("xpon", "device", "xpon_sn_auth_type", snf)
	if snpwd ~= "" then
		if snf == "hex" then
			u:set("xpon", "device", "sn_hex_password", snpwd)
			u:delete("xpon", "device", "sn_ascii_password")
			u:delete("xpon", "device", "sn_regid_password")
		elseif snf == "regid" then
			u:set("xpon", "device", "sn_regid_password", snpwd)
			u:delete("xpon", "device", "sn_ascii_password")
			u:delete("xpon", "device", "sn_hex_password")
		else
			u:set("xpon", "device", "sn_ascii_password", snpwd)
			u:delete("xpon", "device", "sn_hex_password")
			u:delete("xpon", "device", "sn_regid_password")
		end
	end
	if pmode ~= "EPON" and vendor_id ~= "" then u:set("xpon", "device", "vendor_id", vendor_id) end
	if equipment_id ~= "" then u:set("xpon", "device", "equipment_id", equipment_id) else u:delete("xpon", "device", "equipment_id") end
	if onu_version ~= "" then u:set("xpon", "device", "onu_version", onu_version) else u:delete("xpon", "device", "onu_version") end
	if omcc_version ~= "" then u:set("xpon", "device", "omcc_version", omcc_version) end
	if omci_spec_ver ~= "" then u:set("xpon", "device", "omci_spec_ver", omci_spec_ver) end
	if epon_pon_mac ~= "" then
		u:set("xpon", "device", "epon_pon_mac", epon_pon_mac)
	else
		u:delete("xpon", "device", "epon_pon_mac")
	end
	if gpon_pon_mac ~= "" then
		u:set("xpon", "device", "gpon_pon_mac", gpon_pon_mac)
	else
		u:delete("xpon", "device", "gpon_pon_mac")
	end
	u:set("xpon", "device", "epon_oui", eoui)
	u:set("xpon", "device", "epon_ctc_oui", ectc)
	u:set("xpon", "device", "epon_ven_info", even)
	if eonu_vendor ~= "" then
		u:set("xpon", "device", "epon_onu_vendor_id", eonu_vendor)
	else
		u:delete("xpon", "device", "epon_onu_vendor_id")
	end
	if epon_serial ~= "" then
		u:set("xpon", "device", "epon_serial", epon_serial)
	else
		u:delete("xpon", "device", "epon_serial")
	end

	u:save("network")
	local network_commit = u:commit("network")
	if not network_commit then return nil, "persist_commit_network" end
	u:save("xpon")
	local xpon_commit = u:commit("xpon")
	if not xpon_commit then return nil, "persist_commit_xpon" end
	-- 原厂 OMCI 启动脚本从 gpon.ONU.OMCCVersion 读取默认值；同步该配置，
	-- 再由 xpon-replay 在 OMCI 就绪后覆盖运行态，避免启动窗口使用旧版本。
	if omcc_version ~= "" and u:get("gpon", "ONU") then
		local gv = omcc_version:gsub("^0[xX]", ""):upper()
		u:set("gpon", "ONU", "OMCCVersion", gv)
		u:save("gpon")
		local gpon_commit = u:commit("gpon")
		if not gpon_commit then return nil, "persist_commit_gpon" end
	end
	-- UCI Lua API 的写操作可能只返回 nil 而不抛异常；提交后使用新 cursor
	-- 回读关键身份字段，禁止“页面提示成功但持久配置没写进去”。
	local check = uci_native.cursor()
	local equipment = equipment_id
	local function password_value(s)
		return s == '""' and "" or (s or "")
	end
	if pmode ~= "EPON" and check:get("network", "xpon_auth", "auth_method_g") ~= auth_method then
		return nil, "persist_network_auth_method"
	end
	if pmode ~= "EPON" and check:get("xpon", "device", "auth_method_g") ~= auth_method then
		return nil, "persist_device_auth_method"
	end
	if sn ~= "" then
		if check:get("network", "xpon_auth", "sn") ~= sn
			or check:get("network", "xpon_auth", "def_sn") ~= sn then
			return nil, "persist_network_sn"
		end
		if check:get("xpon", "device", active_prefix .. "_sn") ~= sn then
			return nil, "persist_device_" .. active_prefix .. "_sn"
		end
	end
	if loid ~= "" then
		if (pmode == "EPON" or auth_type == "LOID") and check:get("network", "xpon_auth", "loid") ~= loid then
			return nil, "persist_network_loid"
		end
		if check:get("xpon", "device", active_prefix .. "_loid") ~= loid then
			return nil, "persist_device_" .. active_prefix .. "_loid"
		end
	end
	if pmode == "EPON" or auth_type == "LOID" then
		if password_value(check:get("network", "xpon_auth", "loid_password")) ~= loid_password then
			return nil, "persist_network_loid_password"
		end
		if password_value(check:get("xpon", "device", active_prefix .. "_loid_password")) ~= loid_password then
			return nil, "persist_device_" .. active_prefix .. "_loid_password"
		end
	end
	if pmode ~= "EPON" and vendor_id ~= "" and check:get("xpon", "device", "vendor_id") ~= vendor_id then
		return nil, "persist_vendor_id"
	end
	if pmode ~= "EPON" and equipment ~= "" and check:get("network", "xpon_auth", "equipment_id") ~= equipment then
		return nil, "persist_equipment_id"
	end
	if equipment ~= "" and check:get("xpon", "device", "equipment_id") ~= equipment then
		return nil, "persist_device_equipment_id"
	end
	if pmode ~= "EPON" and equipment == "" and (check:get("network", "xpon_auth", "equipment_id") or "") ~= "" then
		return nil, "persist_equipment_id_clear"
	end
	if equipment == "" and (check:get("xpon", "device", "equipment_id") or "") ~= "" then
		return nil, "persist_device_equipment_id_clear"
	end
	if pmode ~= "EPON" and onu_version ~= "" and check:get("network", "xpon_auth", "onu_version") ~= onu_version then
		return nil, "persist_onu_version"
	end
	if onu_version ~= "" and check:get("xpon", "device", "onu_version") ~= onu_version then
		return nil, "persist_device_onu_version"
	end
	if pmode ~= "EPON" and onu_version == "" and (check:get("network", "xpon_auth", "onu_version") or "") ~= "" then
		return nil, "persist_onu_version_clear"
	end
	if onu_version == "" and (check:get("xpon", "device", "onu_version") or "") ~= "" then
		return nil, "persist_device_onu_version_clear"
	end
	if pmode ~= "EPON" and omcc_version ~= "" and check:get("network", "xpon_auth", "omcc_version") ~= omcc_version then
		return nil, "persist_omcc_version"
	end
	if snpwd ~= "" then
		local pw_field = snf == "hex" and "sn_hex_password"
			or snf == "regid" and "sn_regid_password" or "sn_ascii_password"
		if pmode ~= "EPON" and check:get("network", "xpon_auth", pw_field) ~= snpwd then
			return nil, "persist_network_" .. pw_field
		end
		if check:get("xpon", "device", pw_field) ~= snpwd then
			return nil, "persist_device_" .. pw_field
		end
	end
	if epon_pon_mac ~= "" and check:get("xpon", "device", "epon_pon_mac") ~= epon_pon_mac then
		return nil, "persist_epon_pon_mac"
	end
	if epon_pon_mac == "" and (check:get("xpon", "device", "epon_pon_mac") or "") ~= "" then
		return nil, "persist_epon_pon_mac_default"
	end
	if gpon_pon_mac ~= "" and check:get("xpon", "device", "gpon_pon_mac") ~= gpon_pon_mac then
		return nil, "persist_gpon_pon_mac"
	end
	if gpon_pon_mac == "" and (check:get("xpon", "device", "gpon_pon_mac") or "") ~= "" then
		return nil, "persist_gpon_pon_mac_default"
	end
	if pmode == "EPON" then
		if check:get("xpon", "device", "epon_oui") ~= eoui then return nil, "persist_epon_oui" end
		if check:get("xpon", "device", "epon_ctc_oui") ~= ectc then return nil, "persist_epon_ctc_oui" end
		if (check:get("xpon", "device", "epon_onu_vendor_id") or "") ~= eonu_vendor then
			return nil, "persist_epon_onu_vendor_id"
		end
		if (check:get("xpon", "device", "epon_serial") or "") ~= epon_serial then
			return nil, "persist_epon_serial"
		end
	end
	return true
end

local function save_services(fv)
	local rows, count = {}, tonumber(fv("vlan_count") or "0") or 0
	local ports, keys, mvids, key_counts = {}, {}, {}, {}
	local allowed_type = { internet=true, tr069=true, iptv=true, voice=true, other=true }
	local allowed_proto = { pppoe=true, dhcp=true, static=true, none=true }
	local allowed_port = { none=true, lan1=true, lan2=true, lan3=true, lan4=true }
	local function valid_ipv4(v)
		if v == "" then return true end
		local a,b,c,d = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		return a and tonumber(a)<=255 and tonumber(b)<=255 and tonumber(c)<=255 and tonumber(d)<=255
	end
	local valid_masks = { ["0.0.0.0"]=true, ["128.0.0.0"]=true, ["192.0.0.0"]=true, ["224.0.0.0"]=true, ["240.0.0.0"]=true, ["248.0.0.0"]=true, ["252.0.0.0"]=true, ["254.0.0.0"]=true, ["255.0.0.0"]=true }
	for bits=9,32 do
		local n, oct = bits, {}
		for j=1,4 do local b=math.min(n,8); oct[j]=tostring(256-2^(8-b)); n=n-b end
		valid_masks[table.concat(oct, ".")] = true
	end
	for i = 0, count - 1 do
		if fv("vlan_" .. i .. "_deleted") ~= "1" then
			local p = "vlan_" .. i .. "_"
			local row = {
				old_key=fv(p.."key") or "", interface=fv(p.."interface") or "", adopt=fv(p.."adopt") == "1",
				access_mode=fv(p.."access_mode") == "untagged" and "untagged" or "tagged",
				vlan_id=fv(p.."id") or "", priority=fv(p.."priority") or "0",
				remark="", enable=fv(p.."enable") == "1" and "1" or "0",
				service_type=fv(p.."service_type") or "internet", mode=fv(p.."mode") or "routed",
				proto=fv(p.."proto") or "dhcp", mtu=fv(p.."mtu") or "1500",
				username=fv(p.."username") or "", password=fv(p.."password") or "",
				ipaddr=fv(p.."ipaddr") or "", netmask=fv(p.."netmask") or "",
				gateway=fv(p.."gateway") or "", dns1=fv(p.."dns1") or "", dns2=fv(p.."dns2") or "",
				lan_port=fv(p.."lan_port") or "none", mcast_vlan=fv(p.."mcast_vlan") or ""
			}
			local vid = tonumber(row.vlan_id)
			local pri, mtu, mvid = tonumber(row.priority), tonumber(row.mtu), tonumber(row.mcast_vlan)
			if row.old_key ~= "" and (#row.old_key > 32 or not row.old_key:match("^[A-Za-z0-9_]+$")) then row.old_key = "" end
			if row.interface ~= "" and not row.interface:match("^[A-Za-z0-9_]+$") then return nil, "interface_name" end
			if row.access_mode == "tagged" then
				if not vid or vid < 1 or vid > 4094 then return nil, "vlan" end
				row.vlan_id = tostring(vid)
			else
				row.vlan_id = ""
				row.priority = "0"
			end
			local base = service_key_base(row.access_mode, row.vlan_id)
			if not base then return nil, "vlan" end
			key_counts[base] = (key_counts[base] or 0) + 1
			row.key = base .. "_" .. tostring(key_counts[base])
			if keys[row.key] then return nil, "service_key" end
			keys[row.key] = true
			if row.access_mode == "tagged" and (not pri or pri < 0 or pri > 7) then return nil, "vlan" end
			if not allowed_type[row.service_type] or (row.mode ~= "routed" and row.mode ~= "bridged") or not allowed_proto[row.proto] then return nil, "service_mode" end
			if row.mode == "bridged" then row.proto = "none" end
			if row.mode == "routed" and row.proto == "none" then return nil, "service_proto" end
			if not mtu or mtu < 576 or mtu > 2000 then return nil, "mtu" end
			if row.proto == "pppoe" and row.username == "" then return nil, "pppoe_username" end
			if row.proto == "static" and (row.ipaddr == "" or row.netmask == "") then return nil, "static_required" end
			if not valid_ipv4(row.ipaddr) or not valid_ipv4(row.netmask) or not valid_ipv4(row.gateway) or not valid_ipv4(row.dns1) or not valid_ipv4(row.dns2) then return nil, "ipv4" end
			if row.proto == "static" and not valid_masks[row.netmask] then return nil, "netmask" end
			if not allowed_port[row.lan_port] then return nil, "lan_port" end
			if row.lan_port ~= "none" and (row.mode ~= "bridged" or ports[row.lan_port]) then return nil, ports[row.lan_port] and "port_conflict" or "port_mode" end
			if row.lan_port ~= "none" then ports[row.lan_port] = true end
			if row.mcast_vlan ~= "" and (row.access_mode ~= "tagged" or row.service_type ~= "iptv" or not mvid or mvid < 1 or mvid > 4094) then return nil, "mcast_vlan" end
			if mvid and mvids[mvid] then return nil, "mcast_duplicate" end
			if mvid then mvids[mvid] = true end
			rows[#rows + 1] = row
		end
	end
	local u = uci.cursor()
	local iface_ids, next_iface_id = {}, 1
	for _, row in ipairs(rows) do
		if row.adopt then
			row.iface_name = row.interface
		else
			local id = service_iface_seq(row.interface)
			if id and iface_ids[id] then id = nil end
			if id then
				local existing = u:get_all("network", service_iface_name(id))
				if existing and row.interface ~= service_iface_name(id) then id = nil end
			end
			if not id then
				while iface_ids[next_iface_id] or
					(u:get_all("network", service_iface_name(next_iface_id)) and
					 row.interface ~= service_iface_name(next_iface_id)) do
					next_iface_id = next_iface_id + 1
				end
				id = next_iface_id
				next_iface_id = next_iface_id + 1
			end
			iface_ids[id] = true
			row.iface_name = service_iface_name(id)
		end
		row.key = row.iface_name
	end
	local desired_lan_devices = {}
	for _, row in ipairs(rows) do
		if row.enable == "1" and row.mode == "bridged" and row.lan_port ~= "none" then
			desired_lan_devices[lan_port_devices[row.lan_port]] = true
		end
	end

	-- Access 桥接必须在持久配置中消除端口双重归属。只记录并恢复本插件
	-- 实际从 br-lan 摘除过的端口，原本就不属于 br-lan 的 LAN1/WAN 不动。
	local xu = uci.cursor()
	local old_detached = {}
	for _, dev in ipairs(option_list(xu:get("xpon", "lan_binding", "detached_ports"))) do
		if lan_port_devices.lan1 == dev or lan_port_devices.lan2 == dev or
		   lan_port_devices.lan3 == dev or lan_port_devices.lan4 == dev then
			old_detached[#old_detached + 1] = dev
		end
	end
	local br_lan_section
	u:foreach("network", "device", function(s)
		if s.type == "bridge" and s.name == "br-lan" then br_lan_section = s[".name"] end
	end)
	if next(desired_lan_devices) and not br_lan_section then return nil, "br_lan_device" end
	local detached = {}
	if br_lan_section then
		local current, present = option_list(u:get("network", br_lan_section, "ports")), {}
		for _, dev in ipairs(current) do present[dev] = true end
		for _, dev in ipairs(old_detached) do
			if desired_lan_devices[dev] then detached[dev] = true end
		end

		-- 解除绑定时，仅恢复先前由本插件摘除的端口。
		for _, dev in ipairs(old_detached) do
			if not desired_lan_devices[dev] and not present[dev] then
				current[#current + 1] = dev
				present[dev] = true
			end
		end

		local kept = {}
		for _, dev in ipairs(current) do
			if desired_lan_devices[dev] then
				-- 当前确实从 br-lan 摘除，纳入以后解除绑定时的恢复清单。
				detached[dev] = true
			else
				kept[#kept + 1] = dev
			end
		end
		u:set_list("network", br_lan_section, "ports", kept)
	else
		-- br-lan 暂时不存在时无法恢复，保留所有权记录供下次保存重试。
		for _, dev in ipairs(old_detached) do detached[dev] = true end
	end
	local pu, mcast_conflict = uci.cursor(), false
	pu:foreach("pon", "multicast_vlan", function(s)
		if s.xpon_managed ~= "1" and mvids[tonumber(s.vlan_id or "")] then mcast_conflict = true end
	end)
	if mcast_conflict then return nil, "unmanaged_mcast_conflict" end
	-- 同一 tag VLAN / untag 入口允许多业务共用；这里只拒绝会被本页覆盖的同名接口。
	local conflict
	u:foreach("network", nil, function(s)
		if s.xpon_managed ~= "1" then
			for _, row in ipairs(rows) do
				local target_dev = row.access_mode == "untagged" and "pon" or ("pon." .. row.vlan_id)
				local adopt_this = row.adopt and s[".type"] == "interface" and s[".name"] == row.interface and s.device == target_dev
				if not adopt_this and s[".name"] == row.iface_name then conflict = "iface_" .. row.iface_name end
			end
		end
	end)
	if conflict then return nil, "unmanaged_conflict_" .. conflict end
	local old_password, old_password_iface = {}, {}
	u:foreach("network", "interface", function(s)
		if s.password then old_password_iface[s[".name"]] = s.password end
		if s.xpon_managed == "1" and s.xpon_service and s.password then old_password[s.xpon_service] = s.password end
	end)
	-- 接管是唯一允许触碰未受管段的路径，且必须由该行显式勾选。
	for _, row in ipairs(rows) do if row.adopt and row.interface ~= "" then u:delete("network", row.interface) end end
	-- 只删除本插件拥有的段；其他 network 配置保持原样。
	local remove = {}
	u:foreach("network", nil, function(s)
		if s.xpon_managed == "1" and (s[".type"] == "xpon_service" or s.xpon_service) then
			remove[#remove + 1] = s[".name"]
		end
	end)
	for _, s in ipairs(remove) do u:delete("network", s) end
	local wan_ifaces, created_devices = {}, {}
	u:foreach("network", "device", function(s)
		if s.xpon_managed ~= "1" and s.name and s.name:match("^pon%.%d+$") then
			created_devices[s.name] = true
		end
	end)
	local default_wan, previous_default = nil, xu:get("xpon", "ppe", "default_wan_itf")
	for _, row in ipairs(rows) do
		if row.iface_name == previous_default and row.enable == "1" and
		   row.mode == "routed" and row.proto == "pppoe" and
		   row.service_type == "internet" and service_iface_seq(row.iface_name) then
			default_wan = row.iface_name
			break
		end
	end
	for _, row in ipairs(rows) do
		if not default_wan and row.enable == "1" and row.mode == "routed" and row.proto == "pppoe" and
		   row.service_type == "internet" and service_iface_seq(row.iface_name) then
			default_wan = row.iface_name
			break
		end
	end
	if not default_wan then
		for _, row in ipairs(rows) do
			if row.enable == "1" and row.mode == "routed" and row.proto == "pppoe" and service_iface_seq(row.iface_name) then
				default_wan = row.iface_name
				break
			end
		end
	end
	for _, row in ipairs(rows) do
		local iface = row.iface_name
		local ifdev = row.access_mode == "untagged" and "pon" or ("pon." .. row.vlan_id)
		u:section("network", "xpon_service", nil, {
			service_key=row.key, vlan_id=row.vlan_id, access_mode=row.access_mode, priority=row.priority, remark=row.remark,
			enable=row.enable, service_type=row.service_type, mode=row.mode, proto=row.proto,
			mtu=row.mtu, username=row.username, ipaddr=row.ipaddr, netmask=row.netmask,
			gateway=row.gateway, dns1=row.dns1, dns2=row.dns2, lan_port=row.lan_port,
			mcast_vlan=row.mcast_vlan, interface=iface, payload=row.mode,
			xpon_managed="1", xpon_service=row.key
		})
		if row.access_mode == "tagged" and not created_devices[ifdev] then
			u:section("network", "device", nil, { type="8021q", ifname="pon", vid=row.vlan_id, name=ifdev, mtu=row.mtu, xpon_managed="1", xpon_service=row.key })
			created_devices[ifdev] = true
		end
		if row.mode == "bridged" then
			local brname = "br-" .. row.key
			local brsec = u:section("network", "device", nil, { type="bridge", name=brname, xpon_managed="1", xpon_service=row.key })
			local list = { ifdev }
			if row.enable == "1" and row.lan_port ~= "none" then list[#list + 1] = lan_port_devices[row.lan_port] end
			u:set_list("network", brsec, "ports", list); ifdev = brname
		end
		local opts = { device=ifdev, proto=row.proto, auto=row.enable, mtu=row.mtu, xpon_managed="1", xpon_service=row.key }
		if row.mode == "routed" then
			wan_ifaces[#wan_ifaces + 1] = iface
			if row.proto == "pppoe" then wan_ifaces[#wan_ifaces + 1] = iface .. "_6" end
		end
		if row.proto == "pppoe" then
			opts.username=row.username; opts.ipv6="auto"
			opts.pppname=iface
		end
		if row.proto == "static" then opts.ipaddr=row.ipaddr; opts.netmask=row.netmask; opts.gateway=row.gateway end
		u:section("network", "interface", iface, opts)
		local password = row.password ~= "" and row.password or old_password[row.key] or old_password[row.old_key] or old_password_iface[iface] or old_password_iface[row.interface]
		if password then u:set("network", iface, "password", password) end
		local dns = {}; if row.dns1 ~= "" then dns[#dns+1]=row.dns1 end; if row.dns2 ~= "" then dns[#dns+1]=row.dns2 end
		if #dns > 0 then u:set("network", iface, "peerdns", "0"); u:set_list("network", iface, "dns", dns) end
	end
	u:save("network"); u:commit("network")
	ensure_section(xu, "xpon", "lan_binding", "lan_binding")
	local detached_list = {}
	for _, dev in ipairs({ lan_port_devices.lan1, lan_port_devices.lan2,
		lan_port_devices.lan3, lan_port_devices.lan4 }) do
		if detached[dev] then detached_list[#detached_list + 1] = dev end
	end
	if #detached_list > 0 then
		xu:set_list("xpon", "lan_binding", "detached_ports", detached_list)
	else
		xu:delete("xpon", "lan_binding", "detached_ports")
	end
	ensure_section(xu, "xpon", "ppe", "ppe")
	if default_wan then
		xu:set("xpon", "ppe", "default_wan_itf", default_wan)
	else
		xu:delete("xpon", "ppe", "default_wan_itf")
	end
	xu:save("xpon"); xu:commit("xpon")
	-- 将路由业务加入 firewall wan zone。用独立清单记录本插件拥有的列表项，
	-- 更新时只替换这些项，并顺带清除旧版本遗留的 xpon_* / XPON_* 接口名。
	local fu, wan_zone = uci.cursor(), nil
	fu:foreach("firewall", "zone", function(s) if s.name == "wan" then wan_zone = s[".name"] end end)
	if wan_zone then
		local function as_list(v)
			if type(v) == "table" then return v end
			local out = {}; for x in tostring(v or ""):gmatch("%S+") do out[#out + 1] = x end; return out
		end
		local old_managed, drop, merged, have = as_list(xu:get("xpon", "firewall", "wan_networks")), {}, {}, {}
		for _, n in ipairs(old_managed) do drop[n] = true end
		for _, n in ipairs(as_list(fu:get("firewall", wan_zone, "network"))) do
			if not drop[n] and not n:match("^xpon_") and not n:match("^XPON_") and not have[n] then merged[#merged + 1] = n; have[n] = true end
		end
		for _, n in ipairs(wan_ifaces) do if not have[n] then merged[#merged + 1] = n; have[n] = true end end
		fu:set_list("firewall", wan_zone, "network", merged)
		fu:save("firewall"); fu:commit("firewall")
		if not xu:get_all("xpon", "firewall") then xu:section("xpon", "firewall", "firewall", {}) end
		xu:set_list("xpon", "firewall", "wan_networks", wan_ifaces)
		xu:save("xpon"); xu:commit("xpon")
	end
	-- 已提交的业务对象是组播关联真源，由后端统一重建配置，避免 LuCI
	-- 多 cursor/多 config 提交时 network 与 pon 状态不同步。
	if sys.call("/usr/bin/pon-multicast sync-services >/tmp/pon-multicast-sync.log 2>&1") ~= 0 then return nil, "mcast_sync" end
	return true
end

local function save_vlan(fv)
	local u = uci.cursor()
	-- 手动写入表单不携带回退开关字段，避免把已保存的开关/gem_base 重置
	if fv("fallback_enable") == nil and fv("gem_base") == nil then
		return
	end
	ensure_section(u, "xpon", "rules", "fallback")
	u:set("xpon", "rules", "enable", fv("fallback_enable") == "1" and "1" or "0")
	u:set("xpon", "rules", "gem_base", fv("gem_base") or "10")
	u:save("xpon")
	u:commit("xpon")
end

------------------------------------------------------------------------
-- 手工写入 GEM 规则（VLAN 页“手动写入”区块，命令与 TTL 实测一致）
--   addGemPortRule tagCtl 0xb tagFlag 1 userPort 3 vid <vid> dscp 0 pbit <pbit> gemPort <gem>
--   addDownRule    <gem> <ifmask> 0 0 1 1
--   delGemPortRule …（同键）/ delDownRule <gem>
-- 默认“已存在则跳过”：上行表中已有同 VID（或 vid=N/A 通配）规则时跳过，防重复/风暴。
-- 返回 (成功数, 跳过数, 失败数)。
------------------------------------------------------------------------

-- 上行表是否已覆盖本次写入：同 VID、vid=N/A 通配、或同 gemPort 任一命中即视为已存在
-- （OLT 下发的通配规则会把全部业务 VLAN 都覆盖掉——这正是“无需手工加规则”的信号）
local function gem_up_conflict(vid, gem)
	local text = klog_show("/userfs/bin/gponmapcmd showGemPortRule")
	local rows, _ = parse_gem_up(text)
	for _, r in ipairs(rows) do
		if r.vid == vid or r.vid == "N/A" or r.gemPort == gem then
			return true
		end
	end
	return false
end

local function manual_gem(fv)
	local svc = fv("msvc") or ""
	local svc_ok = false
	for _, sd in ipairs(service_defs) do
		if sd.id == svc then svc_ok = true break end
	end
	if not svc_ok then
		return 0, 0, 1
	end
	local vid = fv("mvid") or ""
	local pbit = tonumber(fv("mpbit") or "0")
	local gem = tonumber(fv("mgem") or "")
	local ifmask = fv("mifmask") or "0x0f"
	local mvid = fv("mmvid") or ""
	local op = fv("mgo") or "updown"
	if not validate_vid(vid) then return 0, 0, 1 end
	if op ~= "ponif" and op ~= "mvl" then
		if not gem or gem < 1 or gem > 65534 then return 0, 0, 1 end
		if not pbit or pbit < 0 or pbit > 7 then pbit = 0 end
		if not ifmask:match("^0[xX][0-9a-fA-F]+$") then ifmask = "0x0f" end
	end

	local ok, skip, fail = 0, 0, 0
	-- 参数已全部校验（数字/白名单），可安全拼接
	local function run(...)
		local parts = { ... }
		return sys.call("timeout 3 " .. table.concat(parts, " "))
	end

	if op == "ponif" then
		-- 手动添加 = 建内核 8021q 子接口 pon.<VID>（加/剥标签由内核完成，
		-- 驱动只按上行表把“带 Tag 帧”分类到 GEM 口；OLT 通配已覆盖则无需加 GEM 规则）
		run("vconfig add pon", vid, "2>/dev/null")
		run("ip link add link pon name pon." .. vid .. " type vlan id", vid, "2>/dev/null")
		run("ifconfig pon." .. vid .. " up 2>/dev/null")
		local exists = sh("ip link show pon." .. vid .. " 2>/dev/null")
		if exists ~= "" then
			ok = 1
			local u = uci.cursor()
			ensure_section(u, "xpon", svc, "service")
			u:set("xpon", svc, "vlan", vid)
			u:save("xpon")
			u:commit("xpon")
		else
			fail = 1
		end
	elseif op == "mvl" then
		-- 组播 M-VLAN 登记：xpon_ani_pass_mvlan(vid) 白名单（下行组播帧 VID 必须已登记）
		-- OLT 经 OMCI 下发的不用管；无下发时必须手动登记
		if mvid == "" then mvid = vid end
		if not validate_vid(mvid) then return 0, 0, 1 end
		-- 后台 detach 执行（xponigmpcmd ioctl 可能阻塞，同步会挂起页面）；UCI 先落盘，
		-- 重启由 xpon-app / xpon-mvlan.sh 重放登记
		sys.call("( /userfs/bin/xponigmpcmd mvlan add " .. mvid ..
			" >/dev/null 2>&1; /usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1 ) >/dev/null 2>&1 </dev/null &")
		ok = 1
		local u = uci.cursor()
		ensure_section(u, "xpon", svc, "service")
		u:set("xpon", svc, "mcast_vlan", mvid)
		u:save("xpon")
		u:commit("xpon")
	elseif op == "del" then
		local rc1 = run("/userfs/bin/gponmapcmd delGemPortRule tagCtl 0xb tagFlag 1 userPort 3",
			"vid " .. vid, "dscp 0", "pbit " .. pbit, "gemPort " .. gem)
		local rc2 = run("/userfs/bin/gponmapcmd delDownRule", gem)
		if rc1 == 0 and rc2 == 0 then ok = 1 else fail = 1 end
	elseif (fv("mskip") ~= "1") or not gem_up_conflict(vid, tostring(gem)) then
		local rc1 = run("/userfs/bin/gponmapcmd addGemPortRule tagCtl 0xb tagFlag 1 userPort 3",
			"vid " .. vid, "dscp 0", "pbit " .. pbit, "gemPort " .. gem)
		local rc2 = 0
		if op == "updown" then
			rc2 = run("/userfs/bin/gponmapcmd addDownRule", gem, ifmask, "0 0 1 1")
		end
		if rc1 == 0 and rc2 == 0 then
			ok = 1
			-- 回写配置，便于页面临场预填/守护脚本参考
			local u = uci.cursor()
			ensure_section(u, "xpon", svc, "service")
			u:set("xpon", svc, "vlan", vid)
			u:set("xpon", svc, "pbit", tostring(pbit))
			u:set("xpon", svc, "gem", tostring(gem))
			u:set("xpon", svc, "ifmask", ifmask)
			u:save("xpon")
			u:commit("xpon")
		else
			fail = 1
		end
	else
		skip = 1
	end
	return ok, skip, fail
end

function action_save()
	local page = formvalue("page") or "auth"
	local err = nil

	if page == "auth" then
		local loid = formvalue("loid") or ""
		local loid_password = formvalue("loid_password") or ""
		local sn = (formvalue("sn") or ""):gsub("%s+", "")
		local atg = (formvalue("auth_type_g") or ""):lower()
		local ptech = formvalue("pon_tech") or "GPON"
		local pmode = pon_engine_for(ptech)
		local epon_pon_mac = (formvalue("epon_pon_mac") or formvalue("pon_mac") or ""):gsub("%s+", ""):upper()
		local gpon_pon_mac = (formvalue("gpon_pon_mac") or formvalue("pon_mac") or ""):gsub("%s+", ""):upper()
		local active_pon_mac = pmode == "EPON" and epon_pon_mac or gpon_pon_mac
		local dsd_mac = dsd_wan_mac()
		local effective_pon_mac = active_pon_mac ~= "" and active_pon_mac or dsd_mac
		local onu_low = formvalue("onu_low") or ""
		-- EPON OAM 身份：localOui/ctcOui 为 3 字节 hex，localVenInfo 为
		-- 4 字节 hex，onuVenID 为 4 字节可打印 ASCII。
		local eoui = formvalue("epon_oui") or ""
		local ectc = formvalue("epon_ctc_oui") or ""
		local even = formvalue("epon_ven_info") or ""
		local eonu_vendor = formvalue("epon_onu_vendor_id") or ""
		local epon_serial = (formvalue("epon_serial") or ""):gsub("%s+", ""):upper()
		if onu_low ~= "1" and onu_low ~= "2" then
			err = "onu_low"
		elseif pmode ~= "EPON" and (#sn ~= 12 or not sn:sub(1, 4):match("^[A-Za-z0-9]+$") or not sn:sub(5, 12):match("^[0-9a-fA-F]+$")) then
			err = "sn"
		elseif not ascii24_optional(formvalue("equipment_id") or "") then
			err = "equipment_id"
		elseif not specver_ok(formvalue("omci_spec_ver")) then
			err = "omci_spec_ver"
		elseif #eoui > 0 and not hex_len(eoui, 6, 6) then
			err = "epon_oui"
		elseif #ectc > 0 and not hex_len(ectc, 6, 6) then
			err = "epon_ctc_oui"
		elseif #even > 0 and not hex_len(even, 8, 8) then
			err = "epon_ven_info"
		elseif not ascii4_optional(eonu_vendor) then
			err = "epon_onu_vendor_id"
		elseif #epon_serial > 0 and not ponmac_ok(epon_serial) then
			err = "epon_serial"
		elseif #epon_pon_mac > 0 and not ponmac_ok(epon_pon_mac) then
			err = "epon_pon_mac"
		elseif #gpon_pon_mac > 0 and not ponmac_ok(gpon_pon_mac) then
			err = "gpon_pon_mac"
		elseif #loid > 24 then
			err = "loid"
		elseif #loid_password > 12 then
			err = "loid_password"
		elseif pmode == "EPON" and #loid == 0 then
			err = "loid"
		elseif pmode == "EPON" and not ponmac_ok(effective_pon_mac) then
			err = "epon_pon_mac"
		elseif pmode == "EPON" and dsd_mac ~= "" and effective_pon_mac ~= dsd_mac
			and formvalue("dsd_wan_mac_sync") ~= "1" then
			-- U-Boot gives a valid DSD wan_mac priority over env ethaddr.
			-- Do not report success for a value that will be overwritten on reboot.
			err = "dsd_wan_mac_sync_required"
		elseif pmode ~= "EPON" and atg == "loid" and #loid == 0 then
			err = "loid"
		elseif pmode ~= "EPON" and (atg == "sn" or atg == "regid") then
			-- PON SN 已在通用校验中按完整格式验证；这里只校验可选密码。
			-- SN 密码（可选）：ascii ≤10 / hex ≤20 位且只能 0-9a-f。
			if not err then
				local snf = (formvalue("xpon_sn_auth_type") or "ascii"):lower()
				local sp = formvalue("sn_password") or ""
				if #sp > 0 then
					if snf == "hex" then
						if #sp > 20 or not sp:match("^[0-9a-fA-F]*$") then err = "sn_password" end
					elseif snf == "regid" then
						if #sp > 36 then err = "sn_password" end
					elseif #sp > 10 then
						err = "sn_password"
					end
				end
			end
		elseif pmode ~= "EPON" and atg == "password" then
			-- 移动 Password：PON SN + REG_ID。
			local rp = formvalue("reg_id") or ""
			local u = uci.cursor()
			local stored_rp = u:get("xpon", "device", "sn_regid_password")
				or u:get("network", "xpon_auth", "sn_regid_password") or ""
			if #rp == 0 and stored_rp == "" then
				err = "reg_id"
			elseif #rp > 36 then
				err = "reg_id"
			end
		end
		if not err then
			-- 必须在写入下次启动模式之前记录当前引擎。跨 GPON/EPON 切换时，
			-- 当前进程仍是旧引擎，不能把新配置下发给它；开机恢复会按新模式下发。
			local pmv = ponmode_values()
			local run_tech = pmv.run_tech
			local same_engine = pon_tech_bits[run_tech] ~= nil and
				pon_engine_for(run_tech) == pmode
			local saved_ok, save_err = save_auth(formvalue)
			if not saved_ok then
				err = save_err or "persist_auth"
			else
				if pmode ~= "EPON" and formvalue("dsd_fsan_sync") == "1" then
					local dsd_rc = apply_dsd_value("fsan", sn)
					if dsd_rc ~= 0 then err = "dsd_fsan_write_" .. tostring(dsd_rc) end
				end
				if not err and formvalue("dsd_wan_mac_sync") == "1" then
					local dsd_rc = apply_dsd_value("wan_mac", effective_pon_mac)
					if dsd_rc ~= 0 then err = "dsd_wan_mac_write_" .. tostring(dsd_rc) end
				end
				if not err and pmode ~= "EPON" and formvalue("dsd_clei_code_sync") == "1" then
					local dsd_rc = apply_dsd_value("clei_code", formvalue("equipment_id") or "")
					if dsd_rc ~= 0 then err = "dsd_clei_code_write_" .. tostring(dsd_rc) end
				end
			end
			if not err then
				local onu_val = onu_type_hex(ptech, onu_low)
				local next_onu = tostring(pmv.env_hex or ""):lower()
				local mode_rc = 0
				-- ONU 形态/PON 技术最终由 U-Boot 启动参数决定。只有目标值
				-- 与当前“下次启动”值不一致时才写 env/bootargs，避免单纯
				-- 保存认证字段被无关的 U-Boot env 写入错误阻断。
				if next_onu ~= onu_val:lower() then
					mode_rc = sys.call("/usr/bin/xpon-apply.sh ponmode " .. onu_val)
				end
				if mode_rc ~= 0 then
					err = "ponmode_write_" .. tostring(mode_rc)
				else
					-- GPON 只同步 pon 业务接口地址；EPON 只写入 ethaddr，
					-- 供驱动下次启动时设置 MPCP ONU MAC。
					local mac_rc = sys.call("/usr/bin/xpon-apply.sh mac >/tmp/xpon-ponmac-apply.log 2>&1")
					if mac_rc ~= 0 then
						err = "ponmac_write_" .. tostring(mac_rc)
					else
						local rc = same_engine and sys.call("/usr/bin/xpon-auth-native.sh") or 0
						if rc ~= 0 then
							err = "native_write_" .. tostring(rc)
						else
							http.prepare_content("text/html; charset=utf-8")
							if schedule_reboot(8) then
								local result = same_engine and "认证参数及 PON MAC 已应用"
									or "认证参数及 PON MAC 已保存，将在新 PON 模式启动时生效"
								write_reboot_page(result)
								return
							end
							err = "reboot_schedule"
						end
					end
				end
			end
		end
	elseif page == "voice" then
		local ok, why = save_voice(formvalue)
		if not ok then
			http.redirect(xpon_url("voice", "err=" .. tostring(why)))
			return
		end
	elseif page == "services" then
		local ok, why = save_services(formvalue)
		if not ok then
			http.redirect(xpon_url("services", "err=" .. tostring(why))); return
		end
	elseif page == "provision" or page == "moci" then
		local act = formvalue("action") or "save"
		if act == "manual" then
			local mok, mskip, mfail = manual_gem(formvalue)
			http.redirect(xpon_url("moci", "act=manual&mok=" .. mok ..
				"&mskip=" .. mskip .. "&mfail=" .. mfail))
			return
		end
		save_vlan(formvalue)
		if act == "fallback" then
			sys.call("/usr/bin/xpon-fallback.sh once >/dev/null 2>&1")
			http.redirect(xpon_url("moci", "act=fallback"))
		elseif act == "refresh" then
			http.redirect(xpon_url("moci", "act=refresh"))
		else
			sys.call("/usr/bin/xpon-apply.sh network >/dev/null 2>&1")
			http.redirect(xpon_url("moci", "act=save"))
		end
		return
	end

	if err then
		http.redirect(xpon_url(page, "err=" .. err))
		return
	end

	-- 应用：认证参数必须脱离 LuCI 请求后台下发。apply_auth 会重启 OMCI/PON
	-- 进程，若同步执行会在 HTTP 响应前断开网络，表现为“保存后被登出”。
	if page == "auth" then
		sys.call("( /usr/bin/xpon-apply.sh auth; /usr/bin/xpon-apply.sh mac ) >/tmp/xpon-auth-apply.log 2>&1 </dev/null &")
	elseif page == "voice" then
		-- sipclient 的配置接口由 SDK 私有实现；保存 UCI 后只重载 voice WAN，
		-- 并按 SDK 监控程序的约定重启 sipclient（不存在时静默跳过）。
		local voice_enabled = formvalue("line1_enable") == "1" or formvalue("line2_enable") == "1"
		local sip_action = voice_enabled
			and "killall -HUP sipclient >/dev/null 2>&1 || true; if [ -x /userfs/bin/sipclient ]; then /userfs/bin/sipclient >/dev/null 2>&1 & fi"
			or "killall -9 sipclient >/dev/null 2>&1 || true"
		sys.call("( ifdown voice >/dev/null 2>&1; ifup voice >/dev/null 2>&1; " ..
			voice_tcapi_apply_cmd() .. "; " ..
			sip_action .. " ) " ..
			">/tmp/xpon-voice-apply.log 2>&1 </dev/null &")
	elseif page == "services" then
		-- xpon-bind-lan.sh 先提交桥接/路由归属，再统一触发 netifd reload；
		-- 避免先 reload 读取旧配置而与脚本 add/remove 形成竞态。
		sys.call("( /usr/bin/xpon-bind-lan.sh all; /etc/init.d/firewall reload; /usr/bin/pon-multicast apply-all; /usr/bin/xg2010g-tlsfix.sh apply ) >/tmp/pon-services.log 2>&1 </dev/null &")
	end

	http.redirect(xpon_url(page, "saved=1"))
end

------------------------------------------------------------------------
-- 页面
------------------------------------------------------------------------

function action_auth()
	local page_err = formvalue("err")
	-- r5 已将 OMCC 设为非阻断可选项；忽略旧页面 URL 遗留的废弃错误码。
	if page_err == "omcc_version" then page_err = nil end
	local ponmac_log = ""
	if page_err and page_err:match("^ponmac_write_") then
		ponmac_log = sh("tail -20 /tmp/xpon-ponmac-apply.log 2>/dev/null")
	end
	local dsd_fsan_log = ""
	if page_err and page_err:match("^dsd_.*_write_") then
		dsd_fsan_log = sh("tail -20 /tmp/xpon-dsd-apply.log 2>/dev/null")
	end
	ltemplate.render("xpon/auth", {
		v = auth_values(),
		saved = (formvalue("saved") == "1"),
		err = page_err,
		ponmac_log = ponmac_log,
		dsd_fsan_log = dsd_fsan_log,
	})
end

function action_voice()
	ltemplate.render("xpon/voice", {
		v = voice_values(),
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
	})
end

function action_services()
	local err = formvalue("err")
	local err_text = {
		vlan = "tag 业务的 VLAN ID 或优先级不合法",
		mcast_vlan = "组播 VLAN 只能关联 tag IPTV 业务",
		service_key = "业务内部序号冲突",
		service_proto = "路由业务必须选择 DHCP、PPPoE 或静态 IPv4",
		port_conflict = "LAN/STB 端口已被其它业务绑定",
		port_mode = "LAN/STB 端口只能绑定到桥接业务",
	}
	if err and err:match("^unmanaged_conflict_") then
		err = "未受管接口名冲突：" .. (err:match("^unmanaged_conflict_iface_(.+)$") or "未知")
	else
		err = err_text[err] or err
	end
	ltemplate.render("xpon/services", {
		services = service_values(), kernel_vlans = kernel_vlan_values(), multicast = multicast_values(),
		iptv_businesses = iptv_business_values(),
		saved = (formvalue("saved") == "1"),
		err = err,
		vlan_cleaned = formvalue("vlan_cleaned"),
	})
end

function action_service_action()
	local key = formvalue("service") or ""
	local op = formvalue("op") or ""
	if not key:match("^[A-Za-z0-9_]+$") or (op ~= "up" and op ~= "down") then
		http.redirect(xpon_url("services", "err=service_action")); return
	end
	local uc, iface = uci.cursor(), nil
	uc:foreach("network", "xpon_service", function(v)
		if v.xpon_managed == "1" and v.service_key == key then iface = v.interface end
	end)
	iface = iface or (service_iface_seq(key) and key)
	if not iface then
		http.redirect(xpon_url("services", "err=service_owner")); return
	end
	local s = uc:get_all("network", iface)
	if not s or s[".type"] ~= "interface" or s.xpon_managed ~= "1" or s.xpon_service ~= key then
		http.redirect(xpon_url("services", "err=service_owner")); return
	end
	local rc = sys.call((op == "up" and "ifup " or "ifdown ") .. iface .. " >/tmp/xpon-service-action.log 2>&1")
	http.redirect(xpon_url("services", rc == 0 and ("service_op=" .. op) or ("err=service_runtime_" .. rc)))
end

------------------------------------------------------------------------
-- GEM ↔ VLAN ↔ 业务 联动分析（vlan 页 / status 页共用）
-- 数据源：上行映射表（vid 列 × gemPort）、下行映射表（If Mask）、队列表（tcont）、
-- ME84（vid → gem 显式打标）、ponmgr GEM 硬表、本机业务配置（xpon.<svc>.vlan）
------------------------------------------------------------------------
local function build_gem_vlan_analysis(opt)
	opt = opt or {}
	local up_text    = opt.up_text    or klog_show("/userfs/bin/gponmapcmd showGemPortRule")
	local down_text  = opt.down_text  or klog_show("/userfs/bin/gponmapcmd showDownRule")
	local queue_text = opt.queue_text or klog_show("/userfs/bin/gponmapcmd showQueueRule")
	local gp_out     = opt.gp_out     or ponmgr_cache("gpon_gemport")
	local me84_out   = opt.me84_out   or sh("cat /tmp/ponstatus/me84_tag_info 2>/dev/null")
	local me171_out  = opt.me171_out  or sh("cat /tmp/ponstatus/me171_tag_info 2>/dev/null")
	local up_rows, _ = parse_gem_up(up_text)
	local down_total, down_rows, _ = parse_gem_down(down_text)
	local queue_rows, _ = parse_gem_queue(queue_text)

	-- 本机业务 VID → 名称（/etc/config/pon 的 service 列表）
	local svc_by_vid = {}
	for _, v in ipairs(service_values()) do
		if v.vlan_id ~= "" then svc_by_vid[v.vlan_id] = v.name end
	end

	-- ME84：下行显式打标（vid → gem）
	local me84_map = {}
	for l in (me84_out .. "\n"):gmatch("([^\n]+)") do
		local vid, gp = l:match("vid=(%d+).-gemPort=(%d+)")
		if vid then
			me84_map[gp] = me84_map[gp] or {}
			me84_map[gp][#me84_map[gp] + 1] = vid
		end
	end
	-- 上行表：显式 VID / 通配（vid=N/A）/ pbit
	local up_explicit, up_wild, up_pbit = {}, {}, {}
	for _, r in ipairs(up_rows) do
		local g = r.gemPort
		if r.vid ~= "N/A" and r.vid ~= "" then
			up_explicit[g] = up_explicit[g] or {}
			up_explicit[g][#up_explicit[g] + 1] = r.vid
		elseif r.vid == "N/A" then
			up_wild[g] = true
		end
		if r.pbit ~= "N/A" and r.pbit ~= "" then
			up_pbit[g] = up_pbit[g] or {}
			up_pbit[g][r.pbit] = true
		end
	end
	local down_map, queue_map = {}, {}
	for _, r in ipairs(down_rows) do down_map[r.gemPort] = r.ifMask end
	for _, r in ipairs(queue_rows) do
		queue_map[r.gemPort] = { tcont = r.tcont, queue = r.queue, pq = r.pqMode }
	end
	local omcc_text = opt.omcc_out or ponmgr_cache("gpon_omcc")
	local omcc_gem = omcc_text:match("gemport%s+ID%s*:%s*(%d+)") or "57"

	-- GEM 全集：上行表 ∪ 下行表 ∪ ME84 ∪ ponmgr 硬表
	local gem_set, gem_meta = {}, {}
	for _, r in ipairs(up_rows) do gem_set[r.gemPort] = true end
	for _, r in ipairs(down_rows) do gem_set[r.gemPort] = true end
	for gp in pairs(me84_map) do gem_set[gp] = true end
	for l in (gp_out .. "\n"):gmatch("([^\n]+)") do
		local kind, gp, tcont, macif =
			l:match("(%a+) GEM Port:%s*(%d+), TCONT:%s*(%d+), MAC If:(%S+),")
			or l:match("GEM Port:%s*(%d+), TCONT:%s*(%d+), MAC If:(%S+),")
		if gp then
			gem_set[gp] = true
			gem_meta[gp] = { tcont = tcont, macif = macif, kind = kind or "" }
		end
	end

	local rows, wild_gems, gem_count = {}, 0, 0
	for g in pairs(gem_set) do
		local vids, vids_plain, seen = {}, {}, {}
		for _, v in ipairs(me84_map[g] or {}) do
			vids[#vids + 1] = v .. "（ME84 显式打标）"
			vids_plain[#vids_plain + 1] = v
		end
		for _, v in ipairs(up_explicit[g] or {}) do
			vids[#vids + 1] = v .. "（上行表）"
			vids_plain[#vids_plain + 1] = v
		end
		local plain = {}
		for _, v in ipairs(vids_plain) do
			if not seen[v] then seen[v] = true plain[#plain + 1] = v end
		end
		-- 业务推测：优先用实际 VID 匹配本机业务配置，不硬编码
		local biz_parts = {}
		for _, v in ipairs(plain) do
			if svc_by_vid[v] then
				biz_parts[#biz_parts + 1] = svc_by_vid[v] .. "（VID " .. v .. "）"
			else
				biz_parts[#biz_parts + 1] = "VID " .. v .. "（OLT 下发，未匹配本机业务配置）"
			end
		end
		local pbits = {}
		for p in pairs(up_pbit[g] or {}) do pbits[#pbits + 1] = p end
		table.sort(pbits)
		local meta = gem_meta[g] or {}
		local q = queue_map[g]
		local wild = up_wild[g]
		if wild then wild_gems = wild_gems + 1 end
		local role = (g == omcc_gem) and "OMCC 管理"
			or (g == "65534") and "组播"
			or (meta.kind == "Multicast") and "组播"
			or "业务"
		local biz = table.concat(biz_parts, "、")
		if biz == "" then
			if role == "组播" then
				biz = "组播/广播通道（下行专用，组播 VLAN 白名单）"
			elseif role == "OMCC 管理" then
				biz = "OMCI 管理通道"
			elseif wild then
				biz = "通配承载任意 VLAN（OLT 未标注业务，需 OLT 侧工单/抓包确认）"
			else
				biz = "（OLT 未标注，无显式 VID）"
			end
		elseif wild then
			biz = biz .. "（另含通配）"
		end
		gem_count = gem_count + 1
		rows[#rows + 1] = {
			gem = g, tcont = (q and q.tcont) or meta.tcont or "—",
			queue = (q and q.queue) or "—", pq = (q and q.pq) or "—",
			ifmask = down_map[g] or "", kind = meta.kind or "",
			macif = meta.macif or "", role = role,
			vids = table.concat(vids, "、"), wild = wild and "是（任意 VLAN）" or "否",
			wild_bool = wild, pbits = table.concat(pbits, ","), biz = biz,
			omcc = (g == omcc_gem),
		}
	end
	table.sort(rows, function(a, b) return tonumber(a.gem) < tonumber(b.gem) end)

	local has_up = #up_rows > 0
	local conclusion
	if has_up and wild_gems > 0 then
		conclusion = {
			level = "ok",
			title = "OLT 已下发通配规则（vid=N/A）",
			text = "上行表存在 " .. wild_gems .. " 个通配 GEM（任意 VLAN），所有带 Tag 的业务 VLAN 会自动匹配到对应 GEM。",
		}
	elseif has_up then
		conclusion = {
			level = "warn",
			title = "OLT 按 VID 显式下发（无通配）",
			text = "上行表只有显式 VID 规则。页面已将其与本机 Services 自动匹配；未匹配项表示 OLT 工单与本机配置可能不一致，请核对业务配置。",
		}
	else
		conclusion = {
			level = "manual",
			title = "尚未读取到 OMCI 业务规则",
			text = "GEM 上行表、ME84 和 ME171 当前为空。可能是 ONU 尚未进入 O5、OLT 尚未下发，或 OMCI 守护未就绪。",
		}
	end
	local svc_parts = {}
	for _, v in ipairs(service_values()) do
		if v.vlan_id ~= "" then svc_parts[#svc_parts + 1] = v.name .. "=" .. v.vlan_id end
	end
	local me84_txt = (me84_out ~= "") and me84_out:gsub("\n", "；") or "无"
	local note = "上行表 vid=N/A = 该 GEM 通配承载任意 VLAN——OLT 未按 VID 显式下发，本机业务 VID（"
		.. (table.concat(svc_parts, "、") ~= "" and table.concat(svc_parts, "、") or "未配置")
		.. "）由通配 GEM 承载；ME84 显式打标：" .. me84_txt .. "。"

	return {
		rows = rows, note = note, conclusion = conclusion,
		gem_count = gem_count, wild_gems = wild_gems,
		has_up = has_up, has_omci = (#rows > 0 or me84_out ~= "" or me171_out ~= ""),
		down_total = down_total, omcc_gem = omcc_gem,
	}
end

function action_moci()
	local gem_up_text = klog_show("/userfs/bin/gponmapcmd showGemPortRule")
	local me84 = sh("cat /tmp/ponstatus/me84_tag_info 2>/dev/null")
	local me171 = sh("cat /tmp/ponstatus/me171_tag_info 2>/dev/null")
	local pon_info_text = ponmgr_cache("gpon_info")
	local omcc_text = ponmgr_cache("gpon_omcc")
	local auth_stat_text = sh("/userfs/bin/omcicfgCmd get authStat 2>&1")
	local omci_sn_text = sh("/userfs/bin/omcicfgCmd get sn 2>&1")
	local omci_vendor_text = sh("/userfs/bin/omcicfgCmd get vendorId 2>&1")
	local omci_loid_text = sh("/userfs/bin/omcicfgCmd get loid 2>&1")
	local omci_loidpw_text = sh("/userfs/bin/omcicfgCmd get loidPasswd 2>&1")
	local omci_equipment_text = sh("/userfs/bin/omcicfgCmd get equipmentId 2>&1")
	local omci_onuver_text = sh("/userfs/bin/omcicfgCmd get onuVersion 2>&1")
	local omci_omcc_ver_text = sh("/userfs/bin/omcicfgCmd get omccVersion 2>&1")
	local omci_spec_text = sh("/userfs/bin/omcicfgCmd get specVer 2>&1")
	local gpon_passwd_set_log = sh([[ (grep -h "ponmgr gpon set passwd" /tmp/xpon-auth-native.log 2>/dev/null; logread 2>/dev/null | grep "ponmgr.*gpon set passwd") | tail -1 ]])
	local pon_mac_text = sh("cat /sys/class/net/pon/address 2>/dev/null")
	local olt_info_text = sh("cat /tmp/ponstatus/olt_info 2>/dev/null")
	local me2_text = sh("timeout 3 /usr/sbin/gmtk_omci_dbg me 2 2>&1")
	local me11_text = sh("timeout 3 /usr/sbin/gmtk_omci_dbg me 11 2>&1")
	local me131_text = sh("timeout 3 /usr/sbin/gmtk_omci_dbg me 131 2>&1")
	local me256_text = sh("timeout 3 /usr/sbin/gmtk_omci_dbg me 256 2>&1")
	local me329_text = sh("timeout 3 /usr/sbin/gmtk_omci_dbg me 329 2>&1")
	local gem_up_rows = parse_gem_up(gem_up_text)
	-- G.988 结构化：ME84 下行打标 / ME171 打标操作 / ME268 GEM 口（OLT 下发视图）
	local me84_rows = {}
	for line in (me84 .. "\n"):gmatch("([^\n]+)") do
		local vid, gp, tp, tf =
			line:match("vid=(%d+)"), line:match("gemPort=(%d+)"),
			line:match("tpType=(%d+)"), line:match("tagFlag=(%d+)")
		if vid then me84_rows[#me84_rows + 1] = { vid = vid, gem = gp or "?", tp = tp or "?", tf = tf or "?" } end
	end
	local tm_names = {
		["0"] = "透传（不改标签）", ["1"] = "丢弃", ["21"] = "加 1 层标签",
		["22"] = "加 2 层标签", ["23"] = "加标签并改外层", ["31"] = "剥 1 层标签",
		["32"] = "剥 2 层标签", ["33"] = "剥标签并改内层", ["40"] = "改内层标签",
		["41"] = "改外层标签", ["42"] = "内外层都改",
	}
	local me171_rows = {}
	for line in (me171 .. "\n"):gmatch("([^\n]+)") do
		local tm = line:match("treatment_method=(%d+)")
		local fv = line:match("filter_inner_vid=(%d+)")
		if tm or fv then
			me171_rows[#me171_rows + 1] = {
				tm = tm or "?", tm_name = tm_names[tm] or "（设备未定义）",
				fv = fv or "?", fv_txt = (fv == "4096") and "不过滤内层 VID" or ("内层 VID " .. fv),
			}
		end
	end
	local tcont_text = ponmgr_cache("gpon_tcont")
	local tcont_entries = parse_ponmgr_tcont(tcont_text)
	local gemport_text = ponmgr_cache("gpon_gemport")
	local gem_entries = parse_ponmgr_gem(gemport_text)
	local state_id = pon_info_text:match("ONU State:%s*O(%d+)") or pon_info_text:match("ONU%s+State%s*[:=]%s*(%d+)")
	local auth_raw = auth_stat_text:match("authStat%s*=%s*(%d+)") or auth_stat_text:match("(%d+)")
	local alloc_id = omcc_text:match("alloc%s+ID%s*:%s*(%d+)") or omcc_text:match("Alloc%-?ID%s*[:=]%s*(%d+)")
	local omcc_gem = omcc_text:match("gemport%s+ID%s*:%s*(%d+)") or omcc_text:match("GEM%s+Port%s*ID%s*[:=]%s*(%d+)")
	local olt_vendor = olt_info_text:match("oltVendorId%s*=%s*([%w]+)")
		or me131_text:match("oltVendorId%s*=%s*([%w]+)") or me131_text:match("Vendor%s*ID%s*[:=]%s*([%w]+)")
	local olt_equipment = olt_info_text:match("equipmentId[ \t]*=[ \t]*([^\r\n]*)")
		or me131_text:match("equipmentId[ \t]*=[ \t]*([^\r\n]*)") or ""
	olt_equipment = util.trim(olt_equipment or "")
	local onu_equipment = me256_text:match("equipmentId[ \t]*=[ \t]*([^\r\n]*)")
		or me256_text:match("Equipment%s*ID%s*[:=]%s*([^\r\n]*)") or ""
	onu_equipment = util.trim(onu_equipment or "")
	local mib_sync = me2_text:match("[Mm][Ii][Bb][%w_ ]-[Ss]ync%s*[:=]%s*(%d+)")
		or me2_text:match("[Mm][Ii][Bb][%w_ ]*[Ss]ync%s*[:=]%s*(%d+)")
		or me2_text:match("[Mm]ibDataSync%s*[:=]%s*(%d+)")
	local function me_count(text)
		local n = tonumber(text:match("Entries%s*:%s*(%d+)") or text:match("entry%s*num%s*[:=]%s*(%d+)"))
		if n then return n end
		local c = 0
		for _ in (text .. "\n"):gmatch("[Ee]ntity%s*[Ii][Dd]") do c = c + 1 end
		for _ in (text .. "\n"):gmatch("instance%s*[Ii][Dd]") do c = c + 1 end
		return c
	end
	local pptp_count = me_count(me11_text)
	local veip_count = me_count(me329_text)
	local model_label = (veip_count > 0 and "HGU/VEIP") or (pptp_count > 0 and "SFU/PPTP") or "未识别"
	local function cmd_value(text)
		text = util.trim(tostring(text or ""))
		return text:match("^[^=:]*[=:]%s*(.-)%s*$") or text
	end
	local function runtime_mac(s)
		local m = (s or ""):match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
		return m and m:upper() or ""
	end
	local function show(v, empty)
		return (v and v ~= "") and v or (empty or "（空/未读取）")
	end
	local function saved_any(...)
		for i = 1, select("#", ...) do
			local key = select(i, ...)
			local v = key and (uget("xpon", "device", key) or uget("network", "xpon_auth", key))
			if v and v ~= "" then return v end
		end
		return ""
	end
	local function saved_exact(config, section, option)
		return uget(config, section, option) or ""
	end
	local function append_omci_field(rows, label, source, value, note)
		rows[#rows + 1] = { label = label, source = source, value = value, note = note }
	end
	local run_sn = cmd_value(omci_sn_text)
	local run_vendor = cmd_value(omci_vendor_text)
	local run_loid = cmd_value(omci_loid_text)
	local run_loidpw = cmd_value(omci_loidpw_text)
	local run_equipment = cmd_value(omci_equipment_text)
	local run_onuver = cmd_value(omci_onuver_text)
	local run_omcc_ver = cmd_value(omci_omcc_ver_text)
	local run_spec = cmd_value(omci_spec_text)
	local run_pon_mac = runtime_mac(pon_mac_text)
	local saved_gpon_sn = saved_any("gpon_sn", "sn", "def_sn")
	local saved_vendor = saved_any("vendor_id")
	if saved_vendor == "" and #saved_gpon_sn >= 4 then saved_vendor = saved_gpon_sn:sub(1, 4):upper() end
	local saved_loid = saved_any("gpon_loid", "loid")
	local saved_loidpw = saved_any("gpon_loid_password", "loid_password")
	local saved_equipment = saved_any("equipment_id")
	local saved_onuver = saved_any("onu_version")
	local saved_omcc_ver = saved_any("omcc_version")
	local saved_spec = saved_any("omci_spec_ver")
	local saved_gpon_mac = runtime_mac(saved_any("gpon_pon_mac", "pon_mac"))
	local saved_auth_method = saved_exact("network", "xpon_auth", "auth_method_g")
	if saved_auth_method == "" then saved_auth_method = saved_exact("xpon", "device", "auth_method_g") end
	local saved_auth_type = saved_exact("network", "xpon_auth", "auth_type_g")
	if saved_auth_type == "" then saved_auth_type = saved_exact("xpon", "device", "auth_type_g") end
	local saved_sn_pw_type = saved_exact("network", "xpon_auth", "xpon_sn_auth_type")
	if saved_sn_pw_type == "" then saved_sn_pw_type = saved_exact("xpon", "device", "xpon_sn_auth_type") end
	local sn_ascii_pw = saved_any("sn_ascii_password")
	local sn_hex_pw = saved_any("sn_hex_password")
	local sn_regid_pw = saved_any("sn_regid_password")
	local omci_fields = {}
	append_omci_field(omci_fields, "当前 PON 状态", "xpon-app 缓存：ponmgr gpon get info", state_id and ("O" .. state_id) or "未读取", "O5 表示 GPON/XGPON/XGSPON 已进入运行态")
	append_omci_field(omci_fields, "OMCI 认证状态", "omcicfgCmd get authStat", show(auth_raw), auth_raw == "1" and "已认证" or "未认证/未读取")
	append_omci_field(omci_fields, "OMCC alloc / GEM", "xpon-app 缓存：ponmgr gpon get omcc", show((alloc_id or "?") .. " / " .. (omcc_gem or "?")), "OMCI 管理通道，后续 ME 交互走这个 GEM")
	append_omci_field(omci_fields, "OMCC Version（当前）", "omcicfgCmd get omccVersion", show(run_omcc_ver), "OMCI/OMCC 能力版本")
	append_omci_field(omci_fields, "OMCC Version（配置）", "xpon.device.omcc_version", show(saved_omcc_ver), "认证页保存的期望值")
	append_omci_field(omci_fields, "OMCI Spec Version（当前）", "omcicfgCmd get specVer", show(run_spec), "G.988/spec version 运行值")
	append_omci_field(omci_fields, "OMCI Spec Version（配置）", "xpon.device.omci_spec_ver", show(saved_spec), "空值表示不覆盖固件默认")
	append_omci_field(omci_fields, "PON SN（当前）", "omcicfgCmd get sn", show(run_sn), "GPON/XGPON/XGSPON PLOAM/OMCI 身份 SN")
	append_omci_field(omci_fields, "PON SN（配置）", "xpon.device.gpon_sn / network.xpon_auth.gpon_sn", show(saved_gpon_sn), "完整 SN 通常为 4 字节 Vendor ID + 8 位序列")
	append_omci_field(omci_fields, "Vendor ID（当前）", "omcicfgCmd get vendorId", show(run_vendor), "PON Vendor ID，通常等于 SN 前 4 位")
	append_omci_field(omci_fields, "Vendor ID（配置）", "xpon.device.vendor_id / SN 前 4 位", show(saved_vendor), "认证页保存的期望 Vendor")
	append_omci_field(omci_fields, "认证方式（配置）", "network.xpon_auth auth_method_g/auth_type_g", show(saved_auth_method ~= "" and saved_auth_method or saved_auth_type), "LOID / SN / Password 等认证分支")
	append_omci_field(omci_fields, "LOID（当前）", "omcicfgCmd get loid", show(run_loid), "LOID 认证时使用")
	append_omci_field(omci_fields, "LOID（配置）", "xpon.device.gpon_loid", show(saved_loid), "GPON 专属持久 LOID")
	append_omci_field(omci_fields, "LOID 密码（当前）", "omcicfgCmd get loidPasswd", show(run_loidpw), "OMCI 当前运行值")
	append_omci_field(omci_fields, "LOID 密码（配置）", "xpon.device.gpon_loid_password", show(saved_loidpw), "认证页保存的期望值")
	append_omci_field(omci_fields, "SN Password 类型（配置）", "xpon_sn_auth_type", show(saved_sn_pw_type), "ascii / hex / regid")
	append_omci_field(omci_fields, "SN Password ASCII（配置）", "sn_ascii_password", show(sn_ascii_pw), "认证页保存值")
	append_omci_field(omci_fields, "SN Password HEX（配置）", "sn_hex_password", show(sn_hex_pw), "认证页保存值")
	append_omci_field(omci_fields, "REG_ID / Password（配置）", "sn_regid_password", show(sn_regid_pw), "移动 Password 认证常用")
	append_omci_field(omci_fields, "SN Password（最近下发）", "ponmgr gpon set passwd（固件无 get passwd）", show(gpon_passwd_set_log, "未读取到最近下发日志"), "当前固件 help 未列 get passwd；运行态不支持回读")
	append_omci_field(omci_fields, "Equipment ID（当前）", "omcicfgCmd get equipmentId / ME256", show(run_equipment ~= "" and run_equipment or onu_equipment), "ONU2-G 设备型号/标识")
	append_omci_field(omci_fields, "Equipment ID（配置）", "xpon.device.equipment_id", show(saved_equipment), "空值表示不覆盖固件默认")
	append_omci_field(omci_fields, "ONU Version（当前）", "omcicfgCmd get onuVersion", show(run_onuver), "ONU 软件/硬件版本模拟值")
	append_omci_field(omci_fields, "ONU Version（配置）", "xpon.device.onu_version", show(saved_onuver), "空值表示不覆盖固件默认")
	append_omci_field(omci_fields, "PON 业务 MAC（当前）", "/sys/class/net/pon/address", show(run_pon_mac), "GPON 系列业务侧 pon netdev MAC，不参与 PLOAM SN 注册")
	append_omci_field(omci_fields, "PON 业务 MAC（配置）", "xpon.device.gpon_pon_mac / pon_mac", show(saved_gpon_mac), "空值通常使用 DSD 默认 MAC")
	append_omci_field(omci_fields, "OLT-G Vendor / Equipment", "ME131 / /tmp/ponstatus/olt_info", show((olt_vendor or "") .. (olt_equipment ~= "" and (" / " .. olt_equipment) or "")), "OLT 标识，仅用于诊断")
	append_omci_field(omci_fields, "ONU 模型", "ME11 / ME329", model_label .. "（PPTP=" .. pptp_count .. "，VEIP=" .. veip_count .. "）", "决定 OLT 下发 bridge/VEIP 业务模型")
	append_omci_field(omci_fields, "MIB Data Sync", "ME2 ONU Data", show(mib_sync), "OLT MIB Upload/MIB Reset 的同步计数")

	local me_groups = {
		{ title = "身份与 MIB 同步（ME2 / ME131 / ME256）", mes = {
			{ 2, "ONU Data / MIB Data Sync" }, { 131, "OLT-G" }, { 256, "ONU2-G" },
		} },
		{ title = "TCONT、GEM 与 QoS（ME262 / ME268 / ME130 / ME277）", mes = {
			{ 262, "T-CONT" }, { 268, "GEM Port Network CTP" },
			{ 130, "802.1p Mapper Service Profile" }, { 277, "Priority Queue" },
		} },
		{ title = "桥接、UNI 与 VLAN（ME11 / ME45 / ME47 / ME84 / ME171 / ME329）", mes = {
			{ 11, "PPTP Ethernet UNI" }, { 45, "MAC Bridge Service Profile" },
			{ 47, "MAC Bridge Port Configuration Data" }, { 84, "VLAN Tagging Filter Data" },
			{ 171, "Extended VLAN Tagging Operation Configuration Data" },
			{ 329, "Virtual Ethernet Interface Point" },
		} },
		{ title = "组播（ME281 / ME309 / ME310 / ME311）", mes = {
			{ 281, "Multicast GEM Interworking TP" }, { 309, "Multicast Operations Profile" },
			{ 310, "Multicast Subscriber Config Info" }, { 311, "Multicast Subscriber Monitor" },
		} },
	}
	local omci_me_groups = {}
	for _, group in ipairs(me_groups) do
		local defs = {}
		for _, me in ipairs(group.mes) do
			defs[#defs + 1] = {
				"ME" .. me[1] .. " " .. me[2],
				"/usr/sbin/gmtk_omci_dbg me " .. me[1],
			}
		end
		omci_me_groups[#omci_me_groups + 1] = { title = group.title, dump = command_dump(defs) }
	end

	local ponmgr_groups = {
		{ title = "注册、OMCC 与密钥", dump = ponmgr_cache_dump({
			{ "ponmgr gpon get info", "gpon_info" },
			{ "ponmgr gpon get omcc", "gpon_omcc" },
			{ "ponmgr gpon get sys_link_cfg", "gpon_sys_link_cfg" },
			{ "ponmgr gpon get onlineDuration", "gpon_onlineDuration" },
			{ "ponmgr gpon get PloamGtcInfo", "gpon_PloamGtcInfo" },
			{ "ponmgr gpon get key_info", "gpon_key_info" },
		}) },
		{ title = "TCONT、GEM 与 WAN 计数", dump = ponmgr_cache_dump({
			{ "ponmgr gpon get tcont", "gpon_tcont" },
			{ "ponmgr gpon get gemport", "gpon_gemport" },
			{ "ponmgr gpon get AllTcontTxCnt", "gpon_AllTcontTxCnt" },
			{ "ponmgr gpon get WanCnt", "gpon_WanCnt" },
		}) },
		{ title = "FEC、光模块与时序", dump = ponmgr_cache_dump({
			{ "ponmgr gpon get fec_status", "gpon_fec_status" },
			{ "ponmgr gpon get fecCnt", "gpon_fecCnt" },
			{ "ponmgr gpon get rx_fec_cfg", "gpon_rx_fec_cfg" },
			{ "ponmgr gpon get phyTransParams", "gpon_phyTransParams" },
			{ "ponmgr gpon get DrvPowerLevel", "gpon_DrvPowerLevel" },
			{ "ponmgr gpon get rsp_time", "gpon_rsp_time" },
			{ "ponmgr gpon get eqd_off", "gpon_eqd_off" },
			{ "ponmgr gpon get spf", "gpon_spf" },
			{ "ponmgr gpon get tod_info", "gpon_tod_info" },
		}) },
	}

	local channel_counters = "为避免页面按实例并发直调 ponmgr，已停止逐 TCONT/GEM 即时查询；汇总计数见上方 xpon-app 单写者缓存。"
	local gem_down_text = klog_show("/userfs/bin/gponmapcmd showDownRule")
	local down_total, gem_down_rows = parse_gem_down(gem_down_text)
	local gem_queue_text = klog_show("/userfs/bin/gponmapcmd showQueueRule")
	local gem_queue_rows = parse_gem_queue(gem_queue_text)
	local analysis = build_gem_vlan_analysis({
		up_text = gem_up_text, down_text = gem_down_text, queue_text = gem_queue_text,
		gp_out = gemport_text, omcc_out = omcc_text,
		me84_out = me84, me171_out = me171,
	})
	local interaction_rows = {
		{
			stage = "1",
			direction = "OLT → ONU",
			message = "PLOAM 激活 + OMCC 创建",
			purpose = "ONU 进入 O5 后建立 OMCI 管理控制通道；OMCC alloc-id 通常来自 ONU-ID，OMCI GEM 承载后续 OMCI 消息。",
			values = "ONU State=" .. (state_id and ("O" .. state_id) or "未读取")
				.. "；OMCC alloc=" .. (alloc_id or "?") .. "；OMCI GEM=" .. (omcc_gem or "?"),
			evidence = "xpon-app ponmgr 快照：info / omcc",
			level = (state_id == "5" or (alloc_id and omcc_gem)) and "ok" or "warn",
		},
		{
			stage = "2",
			direction = "OLT ↔ ONU",
			message = "OMCI 基础报文头",
			purpose = "OMCI 在 GEM Port 上以主从方式交互；请求/响应通过 Transaction Correlation Identifier 对应，Message Type 表示 Create/Delete/Set/Get/MIB upload 等操作。",
			values = "当前可见 OMCI GEM=" .. (omcc_gem or "?") .. "；DeviceID=0x0A（Baseline）/0x0B（Extended，抓包可见）",
			evidence = "OMCC GEM / OMCI 协议头",
			level = omcc_gem and "ok" or "info",
		},
		{
			stage = "3",
			direction = "OLT → ONU",
			message = "Get/Set 身份与能力 ME",
			purpose = "OLT 读取/设置 ONU-G、ONU2-G、OLT-G 等管理实体，确认厂商、型号、版本和认证状态。",
			values = "authStat=" .. (auth_raw or "未读取") .. "；OLT=" .. ((olt_vendor or "N/A") .. (olt_equipment ~= "" and ("/" .. olt_equipment) or ""))
				.. "；ONU2-G Equipment=" .. (onu_equipment ~= "" and onu_equipment or "未读取"),
			evidence = "omcicfgCmd authStat / ME131 / ME256",
			level = auth_raw == "1" and "ok" or "warn",
		},
		{
			stage = "4",
			direction = "OLT ↔ ONU",
			message = "MIB Reset / MIB Upload / MIB Upload Next",
			purpose = "OLT 触发 MIB 同步并读取 ONU 支持的 ME 实例；后续下发会依赖这张能力表。",
			values = "ME2 MIB Data Sync=" .. (mib_sync or "未读取")
				.. "；PPTP(ME11)=" .. pptp_count .. "；VEIP(ME329)=" .. veip_count .. "；模型=" .. model_label,
			evidence = "ME2 / ME11 / ME329",
			level = (mib_sync or pptp_count > 0 or veip_count > 0) and "ok" or "info",
		},
		{
			stage = "5",
			direction = "OLT → ONU",
			message = "Create/Set TCONT 与 GEM Port",
			purpose = "OLT 建立上行业务承载：TCONT 对应 alloc-id，GEM Port 对应业务/组播/OMCC 通道。",
			values = "TCONT=" .. tostring(#tcont_entries) .. " 个；GEM=" .. tostring(#gem_entries)
				.. " 个；OMCC GEM=" .. (omcc_gem or "?"),
			evidence = "xpon-app ponmgr 快照：tcont / gemport",
			level = (#tcont_entries > 0 or #gem_entries > 0) and "ok" or "warn",
		},
		{
			stage = "6",
			direction = "OLT → ONU",
			message = "Set VLAN / Bridge / Mapper",
			purpose = "OLT 下发业务 VLAN、桥接端口、802.1p 映射和扩展 VLAN 处理；这一步决定 TR069/Internet/IPTV/Voice 如何落到本机业务。",
			values = "GEM↔VLAN 行=" .. tostring(#(analysis.rows or {}))
				.. "；ME84 显式 VLAN=" .. tostring(#me84_rows)
				.. "；ME171 处理规则=" .. tostring(#me171_rows)
				.. "；通配 GEM=" .. tostring(analysis.wild_gems or 0),
			evidence = "ME84 / ME171 / gponmapcmd",
			level = #(analysis.rows or {}) > 0 and "ok" or "warn",
		},
		{
			stage = "7",
			direction = "ONU → OLT",
			message = "Alarm / AVC / Test Result",
			purpose = "ONU 运行后主要由 OLT 主动控制；ONU 仅在告警、属性变化或测试结果时主动上报。",
			values = "事件快照见原始诊断中的 /tmp/ponstatus/omci_trap_event；业务承载以当前 GEM/VLAN 表为准。",
			evidence = "/tmp/ponstatus/omci_trap_event",
			level = "info",
		},
	}
	ltemplate.render("xpon/moci", {
		ctl_ver = "2",
		interaction_rows = interaction_rows,
		omci_fields = omci_fields,
		gem_up_rows = gem_up_rows,
		gem_down_rows = gem_down_rows,
		gem_down_total = down_total,
		gem_queue_rows = gem_queue_rows,
		me84_rows = me84_rows,
		me171_rows = me171_rows,
		tcont_entries = tcont_entries,
		gem_entries = gem_entries,
		omci_me_groups = omci_me_groups,
		ponmgr_groups = ponmgr_groups,
		channel_counters = channel_counters,
		analysis = analysis,
		services = service_values(),
		gem_up_raw = gem_up_text,
		gem_down_raw = gem_down_text,
		gem_queue_raw = gem_queue_text,
	})
end

local function onu_state_name(state_id)
	local names = {
		["O1"] = "O1 初始 Initial",
		["O2"] = "O2 待命 Standby",
		["O3"] = "O3 序列号 Serial-Number",
		["O4"] = "O4 测距 Ranging",
		["O5"] = "O5 运行 Operation（已注册）",
		["O6"] = "O6 中断 Interruption",
		["O7"] = "O7 去激活 Deactivated",
		["O9"] = "O9 紧急停止 Emergency-Stop（NGPON2）",
	}
	return names[state_id] or (state_id and ("O" .. state_id)) or ""
end

------------------------------------------------------------------------
-- 光模块 DDM / 温度：
--   en7572.ko（BOB 驱动）→ /proc/lddla/debug 写 bob_info/bosa_info，
--     printk 打到 dmesg（private/lddla/en7572_cmd.c）：
--     bob_info  → LOS/Temp/VccT/Ibias/Imod/TxPwr(dBm)/RxPwr(dBm)
--     bosa_info → BOSA Temp / 校准（TxPwr_cal/RxPwr1~3_cal）
--   phy_10g.ko → /proc/pon_phy/temperature（hex，0x2c=44°C，可负=补码）
--   libblapi 用户态 → /userfs/bin/xponblapicmd get transTemp（%.1lf C）
--   CPU 温度 → /userfs/bin/cputemp_cmd（temp=[%d]）
------------------------------------------------------------------------

-- 千分位格式化
local function fmt_num(n)
	local s = tostring(n or 0)
	local out = {}
	local c = 0
	for i = #s, 1, -1 do
		c = c + 1
		out[#out + 1] = s:sub(i, i)
		if c % 3 == 0 and i > 1 then out[#out + 1] = "," end
	end
	return table.concat(out):reverse()
end

-- 执行写 proc 命令并取 dmesg 增量（与 klog_show 同法）
local function ktail(cmd)
	local before = tonumber(sh("dmesg 2>/dev/null | wc -l")) or 0
	sh(cmd)
	return sh("dmesg 2>/dev/null | tail -n +" .. (before + 1) ..
		" | sed 's/^\\[ *[0-9][0-9]*\\.[0-9][0-9]*\\] //'")
end

local function hexword(s)
	local h = s and s:match("0[xX]([0-9a-fA-F]+)") or nil
	if not h then h = s and s:match("^%s*([0-9a-fA-F]+)%s*$") end
	return h and tonumber(h, 16) or nil
end

local function epon_olt_mac()
	local function read_reg(addr)
		return sh("for b in /usr/sbin/devmem /sbin/devmem /usr/bin/devmem /bin/devmem /userfs/bin/devmem; do [ -x $b ] && exec $b " .. addr .. " 32; done")
	end
	local hi = hexword(read_reg("0x1FB66390"))
	local lo = hexword(read_reg("0x1FB66394"))
	if hi and lo and (hi ~= 0 or lo ~= 0) and hi <= 0xffff then
		return string.format("%02X:%02X:%02X:%02X:%02X:%02X",
			math.floor(hi / 0x100) % 0x100, hi % 0x100,
			math.floor(lo / 0x1000000) % 0x100, math.floor(lo / 0x10000) % 0x100,
			math.floor(lo / 0x100) % 0x100, lo % 0x100)
	end
	return nil
end

-- 汇总光模块 DDM 原始输出（无 /proc/lddla/debug 时返回空）
local function optical_diag()
	local notes = {}
	local out = {}
	local lddla_ok = (sh("test -e /proc/lddla/debug && echo yes") == "yes")
	local ko = sh("lsmod 2>/dev/null | awk '$1 ~ /^(en7572|phy_10g)/ {print $1}' | tr '\\n' ' '")
	if lddla_ok then
		local b = ktail("printf 'bob_info' > /proc/lddla/debug 2>/dev/null")
		if not (b:match("TxPwr") or b:match("RxPwr") or b:match("VccT")) then
			-- dmesg 增量可能被 OMCI 日志淹没/错过：回退全量最近一次 DDM 输出
			b = sh("dmesg 2>/dev/null | grep -E 'VccT|Ibias|Imod|TxPwr|RxPwr|bob_info' | tail -25")
		end
		if b:match("TxPwr") or b:match("RxPwr") then
			out[#out + 1] = "==== /proc/lddla/debug: bob_info（实时 DDM） ====\n" .. b
		else
			notes[#notes + 1] = "（诊断：bob_info 无 TxPwr/RxPwr 输出——DDM I2C 读取可能未就绪或光模块无响应）"
		end
		local s = ktail("printf 'bosa_info' > /proc/lddla/debug 2>/dev/null")
		if s == "" or s:match("^%s*$") then
			s = sh("dmesg 2>/dev/null | grep -E 'BOSA|bosa_info' | tail -15")
		end
		if s ~= "" and not s:match("^%s*$") then
			out[#out + 1] = "==== /proc/lddla/debug: bosa_info（BOSA 温度/校准） ====\n" .. s
		end
	else
		notes[#notes + 1] = "（诊断：/proc/lddla/debug 不存在，BOB 驱动未加载；当前相关模块：" ..
			(ko ~= "" and ko or "无 en7572/phy_10g") .. "）"
	end
	local tt = sh("/userfs/bin/xponblapicmd get transTemp 2>&1")
	if tt ~= "" then out[#out + 1] = "==== xponblapicmd get transTemp ====\n" .. tt end
	local pt = sh("cat /proc/pon_phy/temperature 2>/dev/null")
	if pt ~= "" then out[#out + 1] = "==== /proc/pon_phy/temperature ====\n" .. pt end
	local body = table.concat(out, "\n\n")
	if #notes > 0 then
		body = (body ~= "" and (body .. "\n\n") or "") .. table.concat(notes, "\n")
	end
	return body ~= "" and body or "（无任何输出：/proc/lddla/debug 不存在且备用命令均无输出）"
end

function action_oam()
	local sys_mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")
	local sys_mode_num = tonumber(sys_mode)
	local is_epon = sys_mode_num == 2 or sys_mode_num == 3 or sys_mode_num == 4
		or sys_mode_num == 5 or sys_mode_num == 12
	local oam_ready = sh("pidof epon_oam >/dev/null 2>&1 && echo yes || echo no") == "yes"
	local status_file = sh("cat /tmp/epon_reg_auth_status 2>/dev/null")
	local oam_log = sh("tail -160 /tmp/oam_debug 2>/dev/null")
	local llid_proc = sh("cat /proc/epon/debug 2>/dev/null")
	local klog = sh("dmesg 2>/dev/null | grep -Ei 'epon|mpcp|oam|register|llid|auth' | tail -160")
	if klog == "" then klog = sh("logread 2>/dev/null | grep -Ei 'epon|mpcp|oam|register|llid|auth' | tail -160") end
	local olt_mac = epon_olt_mac()
	local auth_out = sh("/userfs/bin/oamcfgCmd get authStatus 2>&1")
	local auth_status = tonumber(auth_out:match("[Aa]uth[Ss]tatus%s*=%s*(%d+)"))
	local function runtime_mac(s)
		local m = (s or ""):match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
		return m and m:upper() or ""
	end
	local function first_nonempty(...)
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if v and v ~= "" then return v end
		end
		return ""
	end
	local onu_mac = first_nonempty(
		runtime_mac(ponmgr_cache("epon_devMac")),
		runtime_mac(sh("cat /sys/class/net/oam/address 2>/dev/null")),
		runtime_mac(sh("awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ethaddr=/) { print substr($i, 9); exit } }' /proc/cmdline 2>/dev/null")),
		runtime_mac(sh("fw_printenv -n ethaddr 2>/dev/null")),
		runtime_mac(uget("xpon", "device", "epon_pon_mac") or ""))
	local llid_text = table.concat({ status_file, llid_proc, klog, oam_log }, "\n")
	local llid_value = parse_epon_llid(llid_text)
	local llid_label = llid_value and ("LLID=" .. llid_value) or "未读取到明确 LLID"

	local fields = {
		{ label = "LOID", cmd = "loid0", secret = false },
		{ label = "LOID 密码", cmd = "loidPasswd0", secret = false },
		{ label = "ONU 本地 OUI", cmd = "localOui", secret = false },
		{ label = "CTC OUI", cmd = "ctcOui", secret = false },
		{ label = "Vendor 信息", cmd = "localVenInfo", secret = false },
		{ label = "ONU Vendor ID", cmd = "onuVenID", secret = false },
	}
	local oam_fields = {}
	local oam_values = {}
	for _, f in ipairs(fields) do
		local raw = sh("/userfs/bin/oamcfgCmd get " .. f.cmd .. " 2>&1")
		local value = raw:match("^[^=:]*[=:]%s*(.-)%s*$") or raw
		oam_values[f.cmd] = value
		if f.secret then value = value ~= "" and value or "（空）" end
		oam_fields[#oam_fields + 1] = {
			label = f.label,
			cmd = f.cmd,
			value = value ~= "" and value or "（空/未读取）",
			raw = raw,
		}
	end
	local onusn = sh("/usr/bin/xpon-epon-sn.sh get 2>&1")
	oam_fields[#oam_fields + 1] = {
		label = "CTC ONUSN",
		cmd = "xpon-epon-sn.sh get",
		value = onusn,
	}

	local evidence = (status_file .. "\n" .. oam_log):upper()
	local registered = llid_value ~= nil
		or evidence:match("REG_AND_AUTH") ~= nil
		or evidence:match("REG_BUT_NOT_AUTH") ~= nil
		or llid_text:upper():match("REGISTER%s*%+%s*GATE") ~= nil
		or llid_text:upper():match("REGISTER%s+GATE") ~= nil
		or llid_text:upper():match("REGISTER[_%s]+ACK") ~= nil
	local auth_label, auth_level
	if auth_status == 1 then
		auth_label = "已认证（authStatus=1）"
		auth_level = "ok"
	elseif auth_status == 0 then
		auth_label = "未确认认证（authStatus=0）"
		auth_level = registered and "warn" or "info"
	elseif evidence:match("REG_AND_AUTH") or evidence:match("AUTH SUCCESS") then
		auth_label = "已认证（日志确认）"
		auth_level = "ok"
	elseif evidence:match("REG_BUT_NOT_AUTH") or evidence:match("AUTH FAILURE") then
		auth_label = "认证失败或未通过"
		auth_level = "err"
	else
		auth_label = "状态未知"
		auth_level = "info"
	end

	local summary = {
		{ label = "当前 PON 模式", value = (sys_mode ~= "" and (sys_mode .. " → " .. (pon_mode_names[sys_mode_num] or "未知"))) or "N/A",
		  level = is_epon and "ok" or "warn" },
		{ label = "epon_oam 进程", value = oam_ready and "运行中" or "未运行", level = oam_ready and "ok" or "err" },
		{ label = "MPCP 注册", value = registered and "已检测到 LLID/注册证据" or "未检测到有效 LLID", level = registered and "ok" or "warn" },
		{ label = "OAM 认证", value = auth_label, level = auth_level },
		{ label = "OLT MAC", value = olt_mac and olt_mac or "未读取到", level = olt_mac and "ok" or "info" },
	}

	local function field_value(name)
		local v = oam_values[name] or ""
		return v ~= "" and v or "未读取到"
	end
	local saved_epon_mac = runtime_mac(uget("xpon", "device", "epon_pon_mac") or "")
	local saved_legacy_mac = runtime_mac(uget("xpon", "device", "pon_mac") or "")
	local saved_epon_oui = (uget("xpon", "device", "epon_oui") or ""):gsub("^0[xX]", ""):upper()
	local saved_ctc_oui = (uget("xpon", "device", "epon_ctc_oui") or ""):gsub("^0[xX]", ""):upper()
	local saved_ven_info = (uget("xpon", "device", "epon_ven_info") or ""):gsub("^0[xX]", ""):upper()
	local saved_onu_vendor = uget("xpon", "device", "epon_onu_vendor_id") or ""
	local saved_onusn = runtime_mac(uget("xpon", "device", "epon_serial") or "")
	local saved_loid = uget("xpon", "device", "epon_loid") or uget("network", "xpon_auth", "epon_loid") or ""
	local saved_loidpw = uget("xpon", "device", "epon_loid_password") or uget("network", "xpon_auth", "epon_loid_password") or ""
	local dsd_mac = dsd_wan_mac()
	local oam_if_mac = runtime_mac(sh("cat /sys/class/net/oam/address 2>/dev/null"))
	local pon_if_mac = runtime_mac(sh("cat /sys/class/net/pon/address 2>/dev/null"))
	local boot_ethaddr = runtime_mac(sh("awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ethaddr=/) { print substr($i, 9); exit } }' /proc/cmdline 2>/dev/null"))
	local fw_ethaddr = runtime_mac(sh("fw_printenv -n ethaddr 2>/dev/null"))
	local desired_mac = first_nonempty(saved_epon_mac, saved_legacy_mac, dsd_mac)
	local current_oui_from_mac = onu_mac ~= "" and onu_mac:gsub(":", ""):sub(1, 6):upper() or ""
	local function show(v, empty)
		return (v and v ~= "") and v or (empty or "（空/未读取）")
	end
	local function append_field(label, source, value, note)
		oam_fields[#oam_fields + 1] = {
			label = label,
			cmd = source,
			value = value,
			note = note,
		}
	end
	local existing_oam_fields = oam_fields
	oam_fields = {}
	append_field("当前 PON 技术模式", "/proc/tc3162/sys_xpon_mode", show(sys_mode) .. " → " .. (pon_mode_names[sys_mode_num] or "未知"), "2/3/4/5/12 为 EPON/OAM 家族")
	append_field("epon_oam 进程", "pidof epon_oam", oam_ready and "运行中" or "未运行", "OAM 身份字段只有进程起来后才可靠")
	append_field("OAM 认证状态", "oamcfgCmd get authStatus", auth_status ~= nil and tostring(auth_status) or show(auth_out), auth_label)
	append_field("MPCP 注册状态", "xpon-app LLID 缓存 / 内核日志", registered and "已检测到 LLID/注册证据" or "未检测到有效 LLID", llid_label)
	append_field("OLT MAC", "devmem 0x1FB66390/0x1FB66394", show(olt_mac), "来自 EPON MAC 寄存器，只读")
	append_field("EPON 注册 MAC（当前）", "xpon-app devMac 缓存 / oam / ethaddr", show(onu_mac), "REGISTER_REQ 使用的 ONU/MPCP MAC")
	append_field("EPON 注册 MAC（配置）", "xpon.device.epon_pon_mac / pon_mac / DSD wan_mac", show(desired_mac), "留空时通常回退 DSD wan_mac")
	append_field("oam 接口 MAC", "/sys/class/net/oam/address", show(oam_if_mac), "OAM netdev 地址，可能跟注册基准 MAC 联动")
	append_field("pon 接口 MAC", "/sys/class/net/pon/address", show(pon_if_mac), "业务侧 pon netdev 地址")
	append_field("U-Boot ethaddr（本次启动）", "/proc/cmdline ethaddr / fw_printenv", show(first_nonempty(boot_ethaddr, fw_ethaddr)), "EPON 驱动常用的启动基准 MAC")
	append_field("DSD 默认 wan_mac", "dsd wan_mac", show(dsd_mac), "未显式配置 EPON MAC 时的默认来源")
	append_field("ONU 本地 OUI（当前）", "oamcfgCmd get localOui", field_value("localOui"), "通常应等于 EPON 注册 MAC 前 3 字节：" .. show(current_oui_from_mac))
	append_field("ONU 本地 OUI（配置）", "xpon.device.epon_oui", show(saved_epon_oui), "保存认证页后写入 localOui")
	append_field("CTC OUI（当前）", "oamcfgCmd get ctcOui", field_value("ctcOui"), "CTC 扩展组织标识，不等同于 ONU 本地 OUI")
	append_field("CTC OUI（配置）", "xpon.device.epon_ctc_oui", show(saved_ctc_oui ~= "" and saved_ctc_oui or "111111"), "空值按 111111 下发")
	append_field("Vendor 信息（当前）", "oamcfgCmd get localVenInfo", field_value("localVenInfo"), "CTC OAM 厂商扩展字段")
	append_field("Vendor 信息（配置）", "xpon.device.epon_ven_info", show(saved_ven_info), "可选，克隆旧猫时填写")
	append_field("ONU Vendor ID（当前）", "oamcfgCmd get onuVenID", field_value("onuVenID"), "4 字节可打印 ASCII")
	append_field("ONU Vendor ID（配置）", "xpon.device.epon_onu_vendor_id", show(saved_onu_vendor), "可选，空值不下发")
	append_field("LOID（当前）", "oamcfgCmd get loid0", field_value("loid0"), "扩展 OAM/运营商认证字段")
	append_field("LOID（配置）", "xpon.device.epon_loid", show(saved_loid), "EPON 专属持久 LOID")
	append_field("LOID 密码（当前）", "oamcfgCmd get loidPasswd0", show(oam_values.loidPasswd0), "OAM 当前运行值")
	append_field("LOID 密码（配置）", "xpon.device.epon_loid_password", show(saved_loidpw), "认证页保存的期望值")
	append_field("CTC ONUSN（当前）", "xpon-epon-sn.sh get", show(onusn), "CTC ONUSN 的 6 字节 ONU ID")
	append_field("CTC ONUSN（配置）", "xpon.device.epon_serial", show(saved_onusn), "与 MPCP 注册 MAC 是两个字段")
	local ext_version = first_nonempty(
		(oam_log:match("[Ee]xt[^\n]*[Vv]er[^0-9A-Fa-f]*(0x%x+)") or ""),
		(oam_log:match("[Vv]ersion[^0-9A-Fa-f]*(0x%x+)") or ""),
		(oam_log:match("[Ee]xt[^\n]*[Vv]er[^0-9]*(%d+)") or ""))
	local interaction_rows = {
		{
			stage = "1",
			direction = "OLT → ONU",
			packet = "MPCP Discovery GATE",
			purpose = "打开发现窗口，让 ONU 发起注册。",
			values = "OLT MAC：" .. (olt_mac or "未读取到") .. "；发现证据：" .. ((klog:lower():match("discover") or klog:lower():match("gate")) and "日志出现 discovery/gate" or "SDK 未直接暴露帧字段"),
			evidence = "devmem / dmesg",
			level = olt_mac and "ok" or "info",
		},
		{
			stage = "2",
			direction = "ONU → OLT",
			packet = "REGISTER_REQ",
			purpose = "ONU 上报 MPCP 注册 MAC，OLT 用它识别 ONU 并测距。",
			values = "ONU/MPCP MAC：" .. (onu_mac ~= "" and onu_mac or "未读取到"),
			evidence = "xpon-app devMac 缓存 / oam netdev / ethaddr",
			level = onu_mac ~= "" and "ok" or "warn",
		},
		{
			stage = "3",
			direction = "OLT → ONU",
			packet = "REGISTER + GATE",
			purpose = "OLT 分配 LLID，并开始给该 LLID 授权上行时隙。",
			values = llid_label,
			evidence = "xpon-app LLID 缓存 / /proc/epon/debug",
			level = registered and "ok" or "warn",
		},
		{
			stage = "4",
			direction = "ONU → OLT",
			packet = "REGISTER_ACK",
			purpose = "ONU 确认 LLID，MPCP 注册阶段完成。",
			values = registered and "已检测到 LLID/注册证据" or "未检测到有效 LLID",
			evidence = "/tmp/epon_reg_auth_status / 内核日志",
			level = registered and "ok" or "warn",
		},
		{
			stage = "5",
			direction = "ONU ↔ OLT",
			packet = "标准 OAM Information/Keepalive",
			purpose = "建立 OAM 管理通道，后续扩展 OAM 在该通道上协商。",
			values = "epon_oam：" .. (oam_ready and "运行中" or "未运行") .. "；authStatus：" .. (auth_status ~= nil and tostring(auth_status) or "未读取到"),
			evidence = "pidof epon_oam / oamcfgCmd get authStatus",
			level = oam_ready and "ok" or "err",
		},
		{
			stage = "6",
			direction = "ONU → OLT",
			packet = "扩展 OAM Organization Specific TLV",
			purpose = "ONU 宣告扩展 OAM 能力和厂商身份，运营商认证通常看这里。",
			values = "InfoType=0xFE；CTC OUI=" .. field_value("ctcOui") .. "；扩展版本=" .. (ext_version ~= "" and ext_version or "SDK 未暴露") .. "；localOui=" .. field_value("localOui") .. "；Vendor=" .. field_value("localVenInfo") .. "；ONU Vendor ID=" .. field_value("onuVenID") .. "；LOID=" .. field_value("loid0") .. "；ONUSN=" .. (onusn ~= "" and onusn or "未读取到"),
			evidence = "oamcfgCmd / xpon-epon-sn.sh / OAM 日志",
			level = (field_value("ctcOui") ~= "未读取到" and field_value("localOui") ~= "未读取到") and "ok" or "warn",
		},
		{
			stage = "7",
			direction = "OLT → ONU",
			packet = "扩展 OAM 响应 / 认证结果",
			purpose = "OLT 确认扩展能力和身份是否匹配，随后才会放行业务。",
			values = auth_label,
			evidence = "authStatus / 状态文件 / OAM 日志",
			level = auth_level,
		},
	}

	local raw_groups = {
		{ title = "MPCP / LLID", body = command_dump({
			{ "/proc/epon/debug", "cat /proc/epon/debug 2>/dev/null" },
			{ "/tmp/epon_reg_auth_status", "cat /tmp/epon_reg_auth_status 2>/dev/null" },
		}) },
		{ title = "OAM 认证与身份", body = command_dump({
			{ "oamcfgCmd get authStatus", "/userfs/bin/oamcfgCmd get authStatus" },
			{ "oamcfgCmd get loid0", "/userfs/bin/oamcfgCmd get loid0" },
			{ "oamcfgCmd get localOui", "/userfs/bin/oamcfgCmd get localOui" },
			{ "oamcfgCmd get ctcOui", "/userfs/bin/oamcfgCmd get ctcOui" },
			{ "oamcfgCmd get localVenInfo", "/userfs/bin/oamcfgCmd get localVenInfo" },
			{ "oamcfgCmd get onuVenID", "/userfs/bin/oamcfgCmd get onuVenID" },
			{ "xpon-epon-sn.sh get", "/usr/bin/xpon-epon-sn.sh get" },
		}) },
		{ title = "OAM 最近日志", body = oam_log ~= "" and oam_log or "（无输出）" },
		{ title = "内核 EPON/OAM 线索", body = klog ~= "" and klog or "（无输出）" },
	}

	ltemplate.render("xpon/oam", {
		is_epon = is_epon,
		summary = summary,
		interaction_rows = interaction_rows,
		oam_fields = oam_fields,
		raw_groups = raw_groups,
		llid_live = status_file,
		llid_proc = llid_proc,
		status_file = status_file,
		auth_out = auth_out,
	})
end

-- 收集一次状态（服务端渲染 + JSON 轮询共用同一份数据）
local function collect_status(include_details)
	include_details = include_details == true
	local function sec(title, cmd)
		return { title = title, body = sh(cmd) }
	end
	local function ksec(title, cmd)
		return { title = title, body = klog_show(cmd) }
	end

	-- 驱动模式比 UCI 更接近当前实际运行状态。EPON 家族包括
	-- 1G/10G/Turbo EPON；其余模式均使用 GPON/OMCI 查询接口。
	local sys_mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")
	local sys_mode_num = tonumber(sys_mode)
	local is_epon = sys_mode_num == 2 or sys_mode_num == 3 or sys_mode_num == 4
		or sys_mode_num == 5 or sys_mode_num == 12
	local pon_family = is_epon and "epon" or "gpon"
	local epon_llid_out, epon_auth_out, epon_status_file, epon_oam_log = "", "", "", ""
	local epon_proc, epon_klog = "", ""
	local pon_info
	if is_epon then
		epon_auth_out = sh("/userfs/bin/oamcfgCmd get authStatus 2>&1")
		epon_status_file = sh("cat /tmp/epon_reg_auth_status 2>/dev/null")
		epon_oam_log = sh("tail -120 /tmp/oam_debug 2>/dev/null")
		-- The poll never invokes ponmgr. It consumes the xpon-app snapshot and
		-- read-only proc/kernel evidence, so a valid LLID is not hidden merely
		-- because the snapshot is stale or the ioctl is unavailable.
		epon_proc = sh("cat /proc/epon/debug 2>/dev/null")
		epon_klog = sh("dmesg 2>/dev/null | grep -Ei 'epon|mpcp|register|llid' | tail -120")
		if epon_klog == "" then epon_klog = sh("logread 2>/dev/null | grep -Ei 'epon|mpcp|register|llid' | tail -120") end
		epon_llid_out = epon_status_file
		if epon_proc ~= "" then
			epon_llid_out = (epon_llid_out ~= "" and (epon_llid_out .. "\n\n") or "")
			epon_llid_out = epon_llid_out .. "---- /proc/epon/debug ----\n" .. epon_proc
		end
		if epon_klog ~= "" then
			epon_llid_out = (epon_llid_out ~= "" and (epon_llid_out .. "\n\n") or "")
			epon_llid_out = epon_llid_out .. "---- kernel log ----\n" .. epon_klog
		end
		pon_info = epon_llid_out
	else
		pon_info = ponmgr_cache("gpon_info")
	end
	local fec_out
	local mac_cnt
	if is_epon then
		fec_out = "（10 秒轮询不调用 ponmgr；由 xpon-app 单写者刷新器统一读取）"
		mac_cnt = "（EPON 使用 pon 接口计数与只读内核证据）"
	else
		fec_out = ponmgr_cache("gpon_fec_status")
		mac_cnt = ponmgr_cache("gpon_WanCnt")
	end

	-- 光模块 DDM：收发光 dBm / BOSA 温度 / CPU 温度
	local diag = optical_diag()
	local tx_pwr = diag:match("TxPwr%s*=%s*([%-]?%d+%.%d+)%s*dBm")
	local rx_pwr = diag:match("RxPwr%s*=%s*([%-]?%d+%.%d+)%s*dBm")
	local vcc    = diag:match("VccT%s*=%s*([%-]?%d+%.?%d*)%s*V?")
	local ibias  = diag:match("Ibias%s*=%s*([%-]?%d+%.%d+)%s*mA")
	local imod   = diag:match("Imod%s*=%s*([%-]?%d+%.%d+)%s*mA")
	local los    = diag:match("LOS%s*=%s*(%d+)")
	local bosa_t = diag:match("BOSA%s+Temp%s*=%s*([%-]?%d+)'C")
	local xp_t   = sh("/userfs/bin/xponblapicmd get transTemp 2>&1"):match("temperature%s+is%s+([%-]?%d+%.?%d*)")
	-- /proc/pon_phy/temperature 的 hex（0x2c=44，>127 为负数补码）
	local pp_t
	local pp_hex = sh("cat /proc/pon_phy/temperature 2>/dev/null"):match("0x(%x+)")
	if pp_hex then
		pp_t = tonumber(pp_hex, 16)
		if pp_t and pp_t > 127 then pp_t = pp_t - 256 end
	end
	local xp_t_c = tonumber(xp_t)
	local bosa_t_c = tonumber(bosa_t)
	local temp_level = (xp_t_c and xp_t_c >= 75) and "warn" or "ok"
	local bosa_level = (bosa_t_c and bosa_t_c >= 75) and "warn" or "ok"
	-- OLT 下发的光功率门限（olt_info，单位 0.001 dBm）：收光低于低门限即告警
	local olt = sh("cat /tmp/ponstatus/olt_info 2>/dev/null")
	local rx_low = olt:match("lowOptThreshold=([%-]?%d+)")
	local rx_low_db = rx_low and (tonumber(rx_low) / 1000) or nil
	local rx_level = (los == "1") and "err"
		or (rx_pwr and rx_low_db and tonumber(rx_pwr) < rx_low_db and "warn")
		or (rx_pwr and "ok") or "info"
	local rx_note = (los == "1") and "（LOS 无光）"
		or (rx_pwr and rx_low_db and tonumber(rx_pwr) < rx_low_db and
			("（低于 OLT 低门限 " .. rx_low_db .. " dBm）")) or ""

	-- PON 接口收发（ifconfig pon 计数），可视化用 bars
	local ifc = sh("ifconfig pon 2>/dev/null | grep -E 'RX packets|TX packets'")
	local pon_rx  = tonumber(ifc:match("RX packets:(%d+)")) or 0
	local pon_tx  = tonumber(ifc:match("TX packets:(%d+)")) or 0
	local rx_err  = tonumber(ifc:match("RX packets:%d+ errors:(%d+)")) or 0
	local rx_drop = tonumber(ifc:match("RX packets:%d+ errors:%d+ dropped:(%d+)")) or 0
	local tx_err  = tonumber(ifc:match("TX packets:%d+ errors:(%d+)")) or 0
	local tx_drop = tonumber(ifc:match("TX packets:%d+ errors:%d+ dropped:(%d+)")) or 0
	local pmax = math.max(pon_rx, pon_tx, 1)
	local pon_bars = {
		{ name = "RX 收", val = fmt_num(pon_rx) .. "（err " .. rx_err .. " / drop " .. rx_drop .. "）",
		  pct = math.floor(pon_rx / pmax * 100), cls = "xpon-fill-rx" },
		{ name = "TX 发", val = fmt_num(pon_tx) .. "（err " .. tx_err .. " / drop " .. tx_drop .. "）",
		  pct = math.floor(pon_tx / pmax * 100), cls = "xpon-fill-tx" },
	}

	-- PON MAC 层计数不同于 ifconfig 的业务接口计数，可直接反映 FEC、
	-- CRC/BIP 和驱动丢包。字段格式已在 XGPON 真机及 AN7583 固件核对。
	local mac_rx = tonumber(mac_cnt:match("rxFrameCnt%s+(%d+)") or mac_cnt:match("rx packets:%s*(%d+)"))
	local mac_tx = tonumber(mac_cnt:match("txFrameCnt:%s*(%d+)") or mac_cnt:match("tx packets:%s*(%d+)"))
	local mac_rx_drop = tonumber(mac_cnt:match("rxDropCnt:%s*(%d+)")) or 0
	local mac_tx_drop = tonumber(mac_cnt:match("txDropCnt:%s*(%d+)")) or 0
	local fec_uncorrectable = tonumber(mac_cnt:match("rxFecErrorCnt:%s*(%d+)")
		or mac_cnt:match("rx FEC error cnt:%s*(%d+)")) or 0
	local fec_corrected = tonumber(mac_cnt:match("rxFecCerrorCnt:%s*(%d+)"))
	local crc_errors = tonumber(mac_cnt:match("rxCrcCnt:%s*(%d+)"))
	local bip_errors = tonumber(mac_cnt:match("BipError:%s*(%d+)"))
	local fec_rx = fec_out:match("fec_rx_status%s+is%s+(%w+)")
		or fec_out:match("fec_rx%s*=%s*(%d+)")
	local fec_tx = fec_out:match("fec_tx_status%s+is%s+(%w+)")
		or fec_out:match("FEC state%s*=%s*(%d+)")
	local fec_label = "RX " .. (fec_rx or "?") .. " / TX " .. (fec_tx or "?")
	local mac_label = (mac_rx and mac_tx) and
		("RX " .. fmt_num(mac_rx) .. " / TX " .. fmt_num(mac_tx)
		 .. "（drop " .. mac_rx_drop .. "/" .. mac_tx_drop .. "）") or "N/A"
	local err_parts = { "不可纠正 FEC " .. fec_uncorrectable }
	if fec_corrected then err_parts[#err_parts + 1] = "已纠正 FEC " .. fmt_num(fec_corrected) end
	if crc_errors then err_parts[#err_parts + 1] = "CRC " .. crc_errors end
	if bip_errors then err_parts[#err_parts + 1] = "BIP " .. bip_errors end
	local pon_error_label = table.concat(err_parts, " / ")
	local pon_error_level = (fec_uncorrectable > 0 or (crc_errors or 0) > 0 or (bip_errors or 0) > 0)
		and "warn" or "ok"

	-- 摘要：ONU State / 认证 / OMCC / 模式 / OLT 下发（尽量取 OMCI 可查状态）
	local omcc_out  = is_epon and "" or ponmgr_cache("gpon_omcc")
	local alloc_id  = omcc_out:match("alloc%s+ID%s*:%s*(%d+)")
	local gem_id    = omcc_out:match("gemport%s+ID%s*:%s*(%d+)")
	local gemport_out = is_epon and "" or ponmgr_cache("gpon_gemport")
	local tcont_out = is_epon and "" or ponmgr_cache("gpon_tcont")
	local gem_entries = gemport_out:match("Entries%s*:%s*(%d+)")
	local tcont_entries = is_epon and "?" or tostring(select(2, tcont_out:gsub("ALLOC ID:", "")))
	-- GEM ↔ VLAN 关联：ponmgr GEM 表 × 上行映射（vid 列）× ME84 显式打标
	local map_up, map_down, map_queue = "", "", ""
	if include_details and not is_epon then
		map_up = klog_show("/userfs/bin/gponmapcmd showGemPortRule")
		map_down = klog_show("/userfs/bin/gponmapcmd showDownRule")
		map_queue = klog_show("/userfs/bin/gponmapcmd showQueueRule")
	end
	local analysis = is_epon and { rows = {}, note = "EPON/OAM 模式不使用 GPON GEM/TCONT 映射。" }
		or include_details and build_gem_vlan_analysis({
			up_text = map_up, down_text = map_down, queue_text = map_queue,
			gp_out = gemport_out,
		}) or { rows = {}, note = "" }
	local gem_vlan = { rows = analysis.rows, note = analysis.note }

	-- EPON 的 MPCP 注册和 OAM 认证是两个独立状态。llid_info 只证明
	-- 驱动已有有效 LLID；authStatus 才是 OAM 认证结果，不能互相推断。
	local epon_llid_lower = epon_llid_out:lower()
	local epon_entry_num = tonumber(epon_llid_lower:match("entry%s*num%s*[:=]%s*(%d+)")
		or epon_llid_lower:match("entries%s*[:=]%s*(%d+)")
		or epon_llid_lower:match("number%s*[:=]%s*(%d+)"))
	-- llidIdx is an internal/control index on some kernels and may stay at zero
	-- even when the registered data LLID is non-zero. Only parse an explicit LLID.
	local epon_mpcp_text = epon_llid_out .. "\n" .. epon_oam_log
	local epon_llid = parse_epon_llid(epon_mpcp_text)
	local epon_auth_status = tonumber(epon_auth_out:match("[Aa]uth[Ss]tatus%s*=%s*(%d+)"))
	local epon_auth_evidence = (epon_status_file .. "\n" .. epon_oam_log):upper()
	local epon_mpcp_evidence = epon_mpcp_text:upper()
	local epon_registered = is_epon and ((epon_entry_num and epon_entry_num > 0)
		or (epon_llid ~= nil and epon_llid > 0 and epon_llid < 65535)
		or epon_auth_evidence:match("REG_AND_AUTH") ~= nil
		or epon_auth_evidence:match("REG_BUT_NOT_AUTH") ~= nil
		or epon_mpcp_evidence:match("REGISTER%s*%+%s*GATE") ~= nil
		or epon_mpcp_evidence:match("REGISTER%s+GATE") ~= nil
		or epon_mpcp_evidence:match("REGISTER[_%s]+ACK") ~= nil) or false
	-- 当前共享内存 authStatus 优先；只有命令不可读时，才回退文件/日志，
	-- 避免旧日志中的成功或失败记录覆盖当前状态。
	local epon_oam_authenticated = epon_auth_status == 1
		or (epon_auth_status == nil and (epon_auth_evidence:match("REG_AND_AUTH") ~= nil
			or epon_auth_evidence:match("AUTH SUCCESS") ~= nil))
	local epon_oam_rejected = epon_auth_status == nil
		and (epon_auth_evidence:match("REG_BUT_NOT_AUTH") ~= nil
			or epon_auth_evidence:match("AUTH FAILURE") ~= nil)

	-- GPON ONU State：优先使用 ponmgr，再回退内核日志；全部不可读时
	-- 才根据 OMCC alloc 推断。EPON 不套用 GPON 的 O1-O7 状态机。
	local state_id
	if not is_epon then
		state_id = pon_info:match("ONU State:%s*O(%d+)")
	end
	local last_pt = ""
	local pt_src = "ponmgr"
	if not is_epon and not state_id then
		last_pt = sh("dmesg 2>/dev/null | grep -o 'ponTime:O[0-9]*' | tail -1")
		pt_src = "dmesg"
	end
	if not is_epon and not state_id and last_pt == "" then
		last_pt = sh("logread 2>/dev/null | grep -o 'ponTime:O[0-9]*' | tail -1")
		pt_src  = "logread"
	end
	if not is_epon and not state_id then state_id = last_pt:match("O(%d+)$") end
	local state_inf  = false
	if not is_epon and not state_id and alloc_id and alloc_id ~= "1023" then
		state_id = "5"
		state_inf = true
	end
	local pt_tail = sh("dmesg 2>/dev/null | grep ponTime | tail -8")
	if pt_tail == "" then pt_tail = sh("logread 2>/dev/null | grep ponTime | tail -8") end

	-- authStat is both the firmware's output label and CLI subcommand on this SDK.
	local auth_out = is_epon and epon_auth_out or sh("/userfs/bin/omcicfgCmd get authStat 2>&1")
	local auth_raw = is_epon and (epon_auth_status ~= nil and tostring(epon_auth_status) or "")
		or (auth_out:match("authStat%s*=%s*(%d+)") or "")
	-- OLT 标识：/tmp/ponstatus/olt_info（OMCI ME131 OLT-G 运行信息）
	local olt_out    = sh("cat /tmp/ponstatus/olt_info 2>/dev/null")
	local olt_vendor = olt_out:match("oltVendorId%s*=%s*([%w]+)") or ""
	-- %s 会跨越换行；equipmentId 为空时不能误把下一行的键名当设备型号。
	local olt_equip  = olt_out:match("equipmentId[ \t]*=[ \t]*([^\r\n]*)") or ""
	olt_equip = util.trim(olt_equip)
	local olt_names  = {
		HWTC = "华为 Huawei", ZTEG = "中兴 ZTE", FHTT = "烽火 FiberHome",
		FHTS = "烽火 FiberHome", ALCL = "诺基亚 Nokia(原阿尔卡特)", UTST = "UT 斯达康",
	}
	local olt_label = olt_vendor
	if olt_names[olt_vendor] then olt_label = olt_names[olt_vendor] end
	if olt_equip ~= "" and olt_equip ~= "0" then olt_label = olt_label .. " / " .. olt_equip end
	local olt_mac = is_epon and epon_olt_mac() or nil
	local olt_device_label = is_epon and (olt_mac and ("OLT MAC " .. olt_mac) or "OLT MAC 未读取到")
		or ((olt_label ~= "" and olt_label) or "N/A（未收到 ME131 OLT-G）")

	local onu_boot = onu_boot_values()
	local function onu_form_label(dec)
		return (dec and dec.form and dec.form ~= "") and dec.form or "未知"
	end
	local onu_env_label = onu_form_label(onu_boot.env_dec)
	local onu_run_label = onu_form_label(onu_boot.run_dec)

	local state_label
	if is_epon then
		if epon_registered then
			state_label = "已注册（MPCP" .. (epon_llid ~= nil and ("，LLID=" .. epon_llid) or "") .. "）"
		else
			state_label = "未检测到有效 LLID（MPCP 发现/注册中）"
		end
	else
		state_label = onu_state_name(state_id)
	end
	if not is_epon and state_inf then
		state_label = "O5 运行（推断：OMCC alloc=" .. alloc_id .. " 已分配，dmesg 不可读）"
	end
	local level = is_epon and (epon_registered and "ok" or "err") or "info"
	if not is_epon and state_id == "5" then
		level = (alloc_id and alloc_id ~= "1023") and "ok" or "warn"
	elseif not is_epon and state_id then
		level = "err"
	end
	local auth_label, auth_level
	if is_epon and epon_oam_authenticated then
		auth_label = "已认证" .. (epon_auth_status ~= nil and ("（authStatus=" .. epon_auth_status .. "）") or "（OAM 日志确认）")
		auth_level = "ok"
	elseif is_epon and not epon_registered then
		auth_label = "尚未开始（需先完成 MPCP 注册）"
		auth_level = "info"
	elseif is_epon and epon_oam_rejected then
		auth_label = "认证失败或未通过（OAM 明确返回失败）"
		auth_level = "err"
	elseif is_epon and epon_auth_status == 0 then
		auth_label = "未确认认证（authStatus=0；部分 OLT 仅要求 MPCP 注册）"
		auth_level = "warn"
	elseif is_epon then
		auth_label = "状态未知（设备未返回可识别的 OAM 认证值）"
		auth_level = "info"
	elseif auth_raw == "1" then
		auth_label = "已认证（authStat=1）"
		auth_level = "ok"
	elseif auth_raw == "0" then
		auth_label = "未认证（authStat=0）"
		auth_level = "warn"
	else
		auth_label = (auth_raw ~= "" and ("authStat=" .. auth_raw)) or "获取失败"
		auth_level = "info"
	end

	local summary = {
		{ label = is_epon and "MPCP 注册" or "ONU 状态", value = state_label, level = level, group = "reg", wide = true },
		{ label = is_epon and "OAM 认证" or "OMCI 认证", value = auth_label, level = auth_level, group = "reg" },
		{ label = "OLT 设备", value = olt_device_label,
		  level = (is_epon and olt_mac or olt_vendor ~= "") and "ok" or "info", group = "reg" },
		{ label = "PON 模式（驱动 sys_xpon_mode）", value = (sys_mode ~= "" and (sys_mode .. " → " .. (pon_mode_names[tonumber(sys_mode)] or "未知"))) or "N/A", group = "reg" },
		{ label = "ONU 形态（系统变量/本次启动）", value = (onu_env_label .. " / " .. onu_run_label), group = "reg" },
		{ label = "OMCC 分配（alloc / gemport）", value = ((alloc_id or "?") .. " / " .. (gem_id or "?")), group = "reg" },
		{ label = "OLT 下发（GEM / TCONT）", value = ((gem_entries or "?") .. " 条 / " .. tcont_entries .. " 条"
			.. (#gem_vlan.rows > 0 and "（关联见下）" or "")), group = "reg" },
		{ label = "PON 接口流量", value = "RX " .. fmt_num(pon_rx) .. " | TX " .. fmt_num(pon_tx), bars = pon_bars, group = "traffic", wide = true },
		{ label = "PON MAC 计数（" .. string.upper(pon_family) .. "）", value = mac_label,
		  level = (mac_rx and mac_tx) and "ok" or "info", group = "traffic", wide = true },
		{ label = "FEC 状态", value = fec_label, level = (fec_rx or fec_tx) and "ok" or "info", group = "traffic" },
		{ label = "PON 错误计数", value = pon_error_label, level = pon_error_level, group = "traffic" },
		{ label = "收光（OLT→ONU 下行）", value = (rx_pwr and (rx_pwr .. " dBm" .. rx_note) or "N/A"), level = rx_level, group = "optical" },
		{ label = "发光（ONU→OLT 上行）", value = (tx_pwr and (tx_pwr .. " dBm") or "N/A"), level = tx_pwr and "ok" or "info", group = "optical" },
		{ label = "供电电压（Vcc）", value = (vcc and (vcc .. " V") or "N/A"), level = vcc and "ok" or "info", group = "optical" },
		{ label = "偏置电流（Ibias）", value = (ibias and (ibias .. " mA") or "N/A"), level = ibias and "ok" or "info", group = "optical" },
		{ label = "调制电流（Imod）", value = (imod and (imod .. " mA") or "N/A"), level = imod and "ok" or "info", group = "optical" },
		{ label = "光模块温度（Transceiver）", value = (xp_t and (xp_t .. " °C") or "N/A"), level = (xp_t and temp_level or "info"), group = "optical" },
		{ label = "BOSA 温度", value = (bosa_t and (bosa_t .. " °C") or "N/A"), level = (bosa_t and bosa_level or "info"), group = "optical" },
	}
	if is_epon then
		local filtered = {}
		for _, item in ipairs(summary) do
			if not item.label:match("^OMCC 分配") and not item.label:match("^OLT 下发") then
				filtered[#filtered + 1] = item
			end
		end
		summary = filtered
	end
	local sections = include_details and {
		is_epon and { title = "EPON MPCP 注册（只读驱动/内核证据）",
			body = epon_llid_out ~= "" and epon_llid_out
				or "（ponmgr、状态文件、/proc 与内核日志均无有效 LLID 输出）" }
			or sec("认证参数 (omcicfgCmd)",
				"/userfs/bin/omcicfgCmd get loid; /userfs/bin/omcicfgCmd get loidPasswd; /userfs/bin/omcicfgCmd get sn; /userfs/bin/omcicfgCmd get vendorId; /userfs/bin/omcicfgCmd get equipmentId; /userfs/bin/omcicfgCmd get onuVersion; /userfs/bin/omcicfgCmd get omccVersion; /userfs/bin/omcicfgCmd get specVer; /userfs/bin/omcicfgCmd get authStat; " ..
				"echo '---- PASSWORD/REG_ID 保存状态（明文） ----'; " ..
				"am=$(uci -q get network.xpon_auth.auth_method_g); [ -n \"$am\" ] || am=$(uci -q get xpon.device.auth_method_g); echo \"auth_method_g=${am:-未知}\"; " ..
				"st=$(uci -q get network.xpon_auth.xpon_sn_auth_type); [ -n \"$st\" ] || st=$(uci -q get xpon.device.xpon_sn_auth_type); echo \"xpon_sn_auth_type=${st:-未知}\"; " ..
				"rp=$(uci -q get network.xpon_auth.sn_regid_password); [ -n \"$rp\" ] || rp=$(uci -q get xpon.device.sn_regid_password); [ -n \"$rp\" ] && echo \"sn_regid_password=$rp\" || echo 'sn_regid_password=（空）'; " ..
				"echo '---- 最近严格下发日志（若使用应用按钮） ----'; sed -n '/ponmgr gpon set passwd/,$p' /tmp/xpon-auth-native.log 2>/dev/null | tail -20"),
		is_epon and { title = "OLT MAC（EPON/MPCP）",
			body = olt_mac and ("OLT MAC " .. olt_mac)
				or "OLT MAC 未读取到（需设备提供 devmem；寄存器 0x1FB66390/0x1FB66394）。" }
			or sec("OLT-G (ME 131, OLT 标识/型号)",
				"timeout 3 /usr/sbin/gmtk_omci_dbg me 131 2>&1"),
		sec("PON 接口",
			"ifconfig pon 2>/dev/null | head -6; ip link show pon 2>/dev/null | head -3"),
		{ title = "PON MAC / FEC 原生计数（" .. string.upper(pon_family) .. "）",
		  body = "---- FEC ----\n" .. fec_out .. "\n\n---- counters ----\n" .. mac_cnt },
		{ title = "光模块 DDM（en7572.ko /proc/lddla/debug + phy_10g.ko /proc/pon_phy）",
		  body = (diag ~= "" and diag) or "（空：/proc/lddla/debug 不存在，BOB 驱动未加载）" },
		is_epon and { title = "EPON OAM 认证（只读）",
			body = "---- oamcfgCmd get authStatus ----\n" .. (epon_auth_out ~= "" and epon_auth_out or "（无输出）")
				.. "\n\n---- 原厂状态文件（若存在） ----\n" .. (epon_status_file ~= "" and epon_status_file or "（不存在）")
				.. "\n\n---- OAM 最近日志 ----\n" .. (epon_oam_log ~= "" and epon_oam_log or "（无输出）") }
			or { title = "OMCC / GEM / TCONT",
				body = omcc_out .. "\n" .. gemport_out .. "\n" .. tcont_out },
		is_epon and { title = "GEM 映射", body = "EPON/OAM 模式不使用 GPON GEM 映射。" }
			or { title = "GEM 上行映射", body = map_up },
		is_epon and { title = "GEM 下行映射", body = "EPON/OAM 模式不使用 GPON GEM 映射。" }
			or { title = "GEM 下行映射", body = map_down },
		is_epon and { title = "GEM 队列映射", body = "EPON/OAM 模式不使用 GPON GEM 映射。" }
			or { title = "GEM 队列映射", body = map_queue },
		ksec("PON VLAN 规则",
			"/userfs/bin/ponvlancmd showrule 1; /userfs/bin/ponvlancmd showrule 2; /userfs/bin/ponvlancmd showrule 3; /userfs/bin/ponvlancmd showrule 4"),
		sec("LED 状态",
			"for d in /sys/class/leds/*/brightness; do echo $d=$(cat $d 2>/dev/null); done"),
		sec("接口状态",
			"ifstatus wan 2>/dev/null | head -c 600; echo; ip addr show 2>/dev/null | grep -E '^[0-9]+:|inet ' | head -40"),
		{ title = "最近 PON 状态变化 (ponTime)",
		  body = pt_tail },
		sec("BBF247 标志",
			"for f in /proc/xgpon/bbf247Flag /proc/gpon/bbf247Flag; do [ -e $f ] && echo $f=$(cat $f 2>/dev/null); done"),
		sec("PON 模式 (onu_type)",
			"echo -n 'env: '; fw_printenv onu_type 2>/dev/null || echo N/A; echo -n 'cmdline: '; grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1; echo -n 'sys_xpon_mode: '; cat /proc/tc3162/sys_xpon_mode 2>/dev/null || echo N/A; lsmod 2>/dev/null | awk '$1 ~ /^xpon/ {print $1}' | tr '\\n' ' '"),
		sec("组播登记快照 (xpon-mvlan-snap.sh)",
			"cat /tmp/xpon-mvlan-act.txt 2>/dev/null || echo '未生成：开机/添加组播后由后台刷新'"),
		sec("OMCI 运行文件 (/tmp/ponstatus)",
			"for f in olt_info me84_tag_info me171_tag_info omci_trap_event error_cnts xpon_mode; do if [ -e /tmp/ponstatus/$f ]; then echo '--- ' $f; cat /tmp/ponstatus/$f 2>/dev/null; fi; done"),
	} or {}

	return {
		summary = summary,
		summary_groups = {
			{ id = "reg", name = "注册与链路（ONU 状态 / 认证 / OLT / 模式）" },
			{ id = "optical", name = "光模块 DDM（收光 / 发光 / 供电 / 温度）" },
			{ id = "traffic", name = "接口流量（PON 收发）" },
		},
		sections = sections,
		gem_vlan = gem_vlan,
	}
end

function action_status()
	-- 首屏只渲染骨架，设备状态由浏览器异步加载。
	ltemplate.render("xpon/status", { status = {
		summary = { { label = "PON 状态", value = "正在读取...", level = "info", wide = true } },
		sections = {}, gem_vlan = { rows = {}, note = "" },
	} })
end

function action_status_data()
	local ok, st = pcall(collect_status, false)
	if not ok then
		st = {
			summary = { { label = "ONU State", value = "读取失败：" .. tostring(st), level = "err" } },
			sections = {},
		}
	end
	http.prepare_content("application/json")
	http.write(encode_json(st))
end

function action_status_details()
	local ok, st = pcall(collect_status, true)
	if not ok then
		st = { sections = {}, gem_vlan = { rows = {}, note = "" }, error = tostring(st) }
	end
	http.prepare_content("application/json")
	http.write(encode_json({ sections = st.sections or {}, gem_vlan = st.gem_vlan or {}, error = st.error }))
end
