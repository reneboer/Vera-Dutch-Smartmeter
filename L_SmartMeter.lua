--[==[
	Module L_SmartMeter.lua
	Written by R.Boer. 
	V1.15 15 October 2019

 	V1.15 Changes:
		Fix for UI7 check
 	V1.14 Changes:
		Changes for icon handling for UI 7.30.
 	V1.12 Changes:
		Updated for my now standard Var, Log and Utils API's.
	V1.11 Changes:
		Can reduce number of updates to reduce CPU load on Vera.
		Nicer looking on ALTUI
	V1.10 Changes:
		Added support for Gas meter being on OBIS channel number 1-4.
	V1.9 Changes:
		Fix on LogGet function.
		Removed some obsolete generic functions.
		Can use local loop IP address on openLuup.
	V1.8 Changes:
		Fix for gas reading of DSMR 2.2 and 3.0 meters.
		Fix for converting meter number with hex values.
		Child devices wil not show the delete button.
	V1.7 Changes:
		More options to enable/disable to reduce CPU load on Vera when options are not in use.
		Possible fix for unrealisting GasMeter flow calculations using the meter timestamp.
		Support for disable attribute so you can disable the plugin without deinstallation. 
	V1.6 Changes: 
		Support for serial2IP connection. Thanks to nlrb. 
	V1.5 Changes: 
		Minor fixes. Added devices to show line power readings. Changed some settings to dropdowns.
		Added a large number of notifications.
	V1.4 Changes: 
		ALTUI support. Added pulling Meter Numbers.
	V1.3 Changes: 
		DSMR V5.0 support for each phase volts, amps and power reading.
	V1.2 Changes: 
		Fix for ISK5 meter Gas reading, monitor plug in memory usage.
	V1.1 Changes: 
		Spelling and a fix on app market.

Read from Smart Meters via P1 port according to Dutch DRSM standard
See forum topic 		: http://forum.micasaverde.com/index.php/topic,10736.0.html
and for this plug in : http://forum.micasaverde.com/index.php/topic,32081.0.html
--]==]

local socketLib = require("socket")  -- Required for logAPI module.

local PlugIn = {
	Version = "1.15",
	DESCRIPTION = "Smart Meter", 
	SM_SID = "urn:rboer-com:serviceId:SmartMeter1", 
	EM_SID = "urn:micasaverde-com:serviceId:EnergyMetering1", 
	GE_SID = "urn:rboer-com:serviceId:SmartMeterGAS1", 
	PM_XML = "D_PowerMeter1.xml", 
	GE_XML = "D_SmartMeterGAS.xml",
	THIS_DEVICE = 0,
	Disabled = false,
	ShowMultiTariff = 0,
	ShowExport = 0,
	ShowGas = 0,
	UseGeneratedPower = 0,
	GeneratedPowerSource = '',
	GeneratorInterval = 0,
	GeneratorIsIdle = true,
	GeneratorInd = 0,
	GeneratorPrevLen = 0,
	UpdateFrequency = 0,
	MessageFrequency = 10,  -- One message per 10 seconds for DSMR V4 and below, each second for V5. Will be set based on version info from meter.
	MessageNum = 1,
	InMessage = false,
	StartingUp = true,
	indGasComming = false -- Some meter types split Gas reading over two lines
}
local GeneratorPrev = {}
local mapperData = {}  

-- Keys for Smart Meter values
local mapKeys = {
	DSMRver  = "1-3:0.2.8",
	Ta       = "0-0:96.14.0", 
	EqID     = "0-0:96.1.1",
	ImpT1    = "1-0:1.8.1", 
	ImpT2    = "1-0:1.8.2",
	ExpT1    = "1-0:2.8.1", 
	ExpT2    = "1-0:2.8.2",
	ImpWatts = "1-0:1.7.0",
	ExpWatts = "1-0:2.7.0",
	L1Volt   = "1-0:32.7.0",
	L2Volt   = "1-0:52.7.0", 
	L3Volt   = "1-0:72.7.0",
	L1Amp    = "1-0:31.7.0",
	L2Amp    = "1-0:51.7.0",
	L3Amp    = "1-0:71.7.0",
	L1ImpWatts = "1-0:21.7.0",
	L2ImpWatts = "1-0:41.7.0",
	L3ImpWatts = "1-0:61.7.0",
	L1ExpWatts = "1-0:22.7.0",
	L2ExpWatts = "1-0:42.7.0",
	L1ExpWatts = "1-0:22.7.0",
	L2ExpWatts = "1-0:42.7.0",
	L3ExpWatts = "1-0:62.7.0",
	Gas_1    = "0-1:24.2.1",
	Gas_2    = "0-2:24.2.1",
	Gas_3    = "0-3:24.2.1",
	Gas_4    = "0-4:24.2.1",
	Gas2     = "0-1:24.3.0",
	GEqID_1  = "0-1:96.1.0",
	GEqID_2  = "0-2:96.1.0",
	GEqID_3  = "0-3:96.1.0",
	GEqID_4  = "0-4:96.1.0",
	WholeHouse = "9-9:9.9.9" -- Dummy Meter reading type for WholeHouse device
}
local FRC_PFX = "_frac" -- post fix for fractional values. We display meter readings without fractions on the UI.
local SM_LOG = "SMLog" -- Log values needed for Whole House with Power Generator calculations and Gas Meter.
local PluginImages = { 'SmartMeter' }

---------------------------------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------------------------------
local log
local var
local utils


-- API getting and setting variables and attributes from Vera more efficient.
local function varAPI()
	local def_sid, def_dev = '', 0
	
	local function _init(sid,dev)
		def_sid = sid
		def_dev = dev
	end
	
	-- Get variable value
	local function _get(name, sid, device)
		local value = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		return (value or '')
	end

	-- Get variable value as number type
	local function _getnum(name, sid, device)
		local value = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		local num = tonumber(value,10)
		return (num or 0)
	end
	
	-- Set variable value
	local function _set(name, value, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local old = luup.variable_get(sid, name, device)
		if (tostring(value) ~= tostring(old or '')) then 
			luup.variable_set(sid, name, value, device)
		end
	end

	-- create missing variable with default value or return existing
	local function _default(name, default, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local value = luup.variable_get(sid, name, device) 
		if (not value) then
			value = default	or ''
			luup.variable_set(sid, name, value, device)	
		end
		return value
	end
	
	-- Get an attribute value, try to return as number value if applicable
	local function _getattr(name, device)
		local value = luup.attr_get(name, tonumber(device or def_dev))
		local nv = tonumber(value,10)
		return (nv or value)
	end

	-- Set an attribute
	local function _setattr(name, value, device)
		luup.attr_set(name, value, tonumber(device or def_dev))
	end
	
	return {
		Get = _get,
		Set = _set,
		GetNumber = _getnum,
		Default = _default,
		GetAttribute = _getattr,
		SetAttribute = _setattr,
		Initialize = _init
	}
end

-- API to handle basic logging and debug messaging. V2.0, requires socketlib
local function logAPI()
local _LLError = 1
local _LLWarning = 2
local _LLInfo = 8
local _LLDebug = 11
local def_level = _LLError
local def_prefix = ''
local def_debug = false
local syslog


	-- Syslog server support. From Netatmo plugin by akbooer
	local function _init_syslog_server(ip_and_port, tag, hostname)
		local sock = socketLib.udp()
		local facility = 1    -- 'user'
--		local emergency, alert, critical, error, warning, notice, info, debug = 0,1,2,3,4,5,6,7
		local ip, port = ip_and_port:match "^(%d+%.%d+%.%d+%.%d+):(%d+)$"
		if not ip or not port then return nil, "invalid IP or PORT" end
		local serialNo = luup.pk_accesspoint
		hostname = ("Vera-"..serialNo) or "Vera"
		if not tag or tag == '' then tag = def_prefix end
		tag = tag:gsub("[^%w]","") or "No TAG"  -- only alphanumeric, no spaces or other
		local function send (self, content, severity)
			content  = tostring (content)
			severity = tonumber (severity) or 6
			local priority = facility*8 + (severity%8)
			local msg = ("<%d>%s %s %s: %s\n"):format (priority, os.date "%b %d %H:%M:%S", hostname, tag, content)
			sock:send(msg) 
		end
		local ok, err = sock:setpeername(ip, port)
		if ok then ok = {send = send} end
		return ok, err
	end

	local function _update(level)
		if level > 10 then
			def_debug = true
			def_level = 10
		else
			def_debug = false
			def_level = level
		end
	end	

	local function _init(prefix, level)
		_update(level)
		def_prefix = prefix
	end	

	local function _set_syslog(sever)
		if (sever ~= '') then
			_log('Starting UDP syslog service...',7) 
			local err
			syslog, err = _init_syslog_server(server, def_prefix)
			if (not syslog) then _log('UDP syslog service error: '..err,2) end
		else
			syslog = nil
		end	
	end

	local function _log(text, level) 
		local level = (level or 10)
		local msg = (text or "no text")
		if (def_level >= level) then
			if (syslog) then
				local slvl
				if (level == 1) then slvl = 2 
				elseif (level == 2) then slvl = 4 
				elseif (level == 3) then slvl = 5 
				elseif (level == 4) then slvl = 5 
				elseif (level == 7) then slvl = 6 
				elseif (level == 8) then slvl = 6 
				else slvl = 7
				end
				syslog:send(msg,slvl) 
			else
				if (level == 10) then level = 50 end
				luup.log(def_prefix .. ": " .. msg:sub(1,80), (level or 50)) 
			end	
		end	
	end	
	
	local function _debug(text)
		if def_debug then
			luup.log(def_prefix .. "_debug: " .. (text or "no text"), 50) 
		end	
	end
	
	return {
		Initialize = _init,
		LLError = _LLError,
		LLWarning = _LLWarning,
		LLInfo = _LLInfo,
		LLDebug = _LLDebug,
		Update = _update,
		SetSyslog = _set_syslog,
		Log = _log,
		Debug = _debug
	}
end 

-- API to handle some Util functions
local function utilsAPI()
local _UI5 = 5
local _UI6 = 6
local _UI7 = 7
local _UI8 = 8
local _OpenLuup = 99

	local function _init()
	end	

	-- See what system we are running on, some Vera or OpenLuup
	local function _getui()
		if (luup.attr_get("openLuup",0) ~= nil) then
			return _OpenLuup
		else
			return luup.version_major
		end
		return _UI7
	end
	
	local function _getmemoryused()
		return math.floor(collectgarbage "count")         -- app's own memory usage in kB
	end
	
	local function _setluupfailure(status,devID)
		if (luup.version_major < 7) then status = status ~= 0 end        -- fix UI5 status type
		luup.set_failure(status,devID)
	end

	-- Luup Reload function for UI5,6 and 7
	local function _luup_reload()
		if (luup.version_major < 6) then 
			luup.call_action("urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {}, 0)
		else
			luup.reload()
		end
	end
	
	return {
		Initialize = _init,
		ReloadLuup = _luup_reload,
		GetMemoryUsed = _getmemoryused,
		SetLuupFailure = _setluupfailure,
		GetUI = _getui,
		IsUI5 = _UI5,
		IsUI6 = _UI6,
		IsUI7 = _UI7,
		IsUI8 = _UI8,
		IsOpenLuup = _OpenLuup
	}
end 


-- Fill mapperData table with an extra entry
local function mapperRow(k,v,s,f,di)
	mapperData[k] = {key = k, var = v, sid = s, dev = nil, val = 0, func = f, dir = (di or 1), desc = "", lab = "", xml = nil}
end	
local function mapperRowChild(k,v,s,vl,f,di,de,l,x)
	mapperData[k] = {key = k, var = v, sid = s, dev = nil, val = vl, func = f, dir = di, desc = de, lab = l, xml = x}
end	

-- Functions to handle Log values. They are all five numbers, number four is time stamp number
local function LogGet(meter)
	local lgstr = var.Get(SM_LOG, meter.sid, meter.dev)
	local a,b,c,d,e = -1,0,0,0,0
	if lgstr ~= "" then
		a,b,c,d,e = lgstr:match("(%d+),(%d+),(%d+),(%d+),(%d+)")
		if (lgstr:sub(1,1) == "-") then a = a * -1 end
	end
	return {v1=tonumber(a), v2=tonumber(b),v3=tonumber(c),ts=tonumber(d),v5=tonumber(e)}
end
local function LogSet(meter,val1,val2,val3,timest,val5)
	local lt = meter.rtlog
	lt.v1 = val1 or -1
	lt.v2 = val2 or 0
	lt.v3 = val3 or 0
	lt.ts = timest or 0
	lt.v5 = val5 or 0
	var.Set(SM_LOG, lt.v1..","..lt.v2..","..lt.v3..","..lt.ts..","..lt.v5, meter.sid, meter.dev)
end
function SmartMeter_registerWithAltUI()
	-- Register with ALTUI once it is ready
	local ALTUI_SID = "urn:upnp-org:serviceId:altui1"
	for k, v in pairs(luup.devices) do
		if (v.device_type == "urn:schemas-upnp-org:device:altui:1") then
			if luup.is_ready(k) then
				log.Debug("Found ALTUI device "..k.." registering devices.")
				local arguments = {}
				arguments["newDeviceType"] = "urn:schemas-rboer-com:device:SmartMeter:1"
				arguments["newScriptFile"] = "J_ALTUI_SmartMeter.js"	
				arguments["newDeviceDrawFunc"] = "ALTUI_SmartMeterDisplays.drawSmartMeter"	
				arguments["newStyleFunc"] = ""	
				arguments["newDeviceIconFunc"] = ""	
				arguments["newControlPanelFunc"] = ""	
				-- Main device
				luup.call_action(ALTUI_SID, "RegisterPlugin", arguments, k)
				-- Child devices
				arguments["newDeviceType"] = "urn:schemas-rboer-com:device:SmartMeterGAS:1"	
				arguments["newScriptFile"] = "J_ALTUI_SmartMeter.js"	
				arguments["newDeviceDrawFunc"] = "ALTUI_SmartMeterDisplays.drawSmartMeterGas"	
				luup.call_action(ALTUI_SID, "RegisterPlugin", arguments, k)
			else
				log.Debug("ALTUI plugin is not yet ready, retry in a bit..")
				luup.call_delay("SmartMeter_registerWithAltUI", 10, "", false)
			end
			break
		end
	end
end

---------------------------------------------------------------------------
-- Functions to parse meter values from strings, must be before mapperData
local function SetKWHDetails(meter, newVal)
	local elem = meter
	var.Set(elem.var, math.floor(newVal), elem.sid, elem.dev)
	var.Set(elem.var .. FRC_PFX, newVal, elem.sid, elem.dev)
end
-- Set KWH values
local function SetKWH(meter, dataStr)
	local elem = meter
	local newVal = tonumber(dataStr:match("%d+.%d+")) 
	if (newVal ~= elem.val) then
		elem.val = newVal
		local impVal = 0
		local expVal = 0
		local impT1Elem = mapperData[mapKeys.ImpT1]
		local impT2Elem = mapperData[mapKeys.ImpT2]
		local whElem = mapperData[mapKeys.WholeHouse]
		-- Sum import meters
		if (impT1Elem.val ~= -1 and impT2Elem.val ~= -1) then impVal = impT1Elem.val + impT2Elem.val end
		-- Are we processing an Import value?
		if (elem.dir == 1) then
			if (PlugIn.ShowMultiTariff == 0) then
				-- If we do not have multi tariff, then show import total on ImpT1 as well
				SetKWHDetails(impT1Elem, impVal)
			else
				-- Update individual meter
				if (elem.dev ~= nil) then SetKWHDetails(elem, newVal) end
			end
		end	
		-- If applicable sum export meters
		if (PlugIn.ShowExport == 1) then
			local expT1Elem = mapperData[mapKeys.ExpT1]
			local expT2Elem = mapperData[mapKeys.ExpT2]
			if (expT1Elem.val ~= -1 and expT2Elem.val ~= -1) then expVal = expT1Elem.val + expT2Elem.val end
			-- Are we processing an Export value?
			if (elem.dir == -1) then
				-- If we do not have multi tariff, then show export total on ExpT1 as well
				if (PlugIn.ShowMultiTariff == 0) then
					SetKWHDetails(expT1Elem, expVal)
				else
					-- Update individual meter
					if (elem.dev ~= nil) then SetKWHDetails(elem, newVal) end
				end
			end	
		end	
		-- If Show sum on Whole House 
		SetKWHDetails(whElem, impVal - expVal)
		-- Set new matching KWH value on main plugin
		var.Set(elem.lab, math.floor(newVal))
		var.Set(whElem.lab, math.floor(impVal - expVal))
	end
	return newVal
end
local function BufferValue(newval)
	if (PlugIn.GeneratorPrevLen == 0) then return newval end
	local curval = (GeneratorPrev[PlugIn.GeneratorInd] or newval)
	GeneratorPrev[PlugIn.GeneratorInd] = newval
	PlugIn.GeneratorInd = (PlugIn.GeneratorInd % PlugIn.GeneratorPrevLen) + 1
	return curval
end

-- Set the Watts value for the correct meter
local function SetWatts(meter, dataStr) 
	local elem = meter
	local newVal = math.floor(tonumber(dataStr:match("%d+.%d+")) * 1000)
	-- See if we have the import or export devices show as well
	if (elem.dev ~= nil) then 
		if (newVal ~= elem.val) then
			var.Set(elem.var, newVal, elem.sid, elem.dev)
			elem.val = newVal
		end
	end
	-- We only calculate the below when the reading is not zero and start up has completed. No need to do it twice for Import and Export in one round. 
	if (newVal == 0) then return 0 end
	local whElem = mapperData[mapKeys.WholeHouse]
	-- Just set WholeHouse value to follow meter value
	local dirVal = newVal * elem.dir
	if (newVal ~= 0) and (dirVal ~= whElem.val) then
		whElem.val = dirVal
		var.Set(elem.var, dirVal, whElem.sid, whElem.dev)
	end
	return newVal
end
-- Set the Watts value for the correct meter accouning for generator
local function SetWattsGen(meter, dataStr) 
	local elem = meter
	local newVal = math.floor(tonumber(dataStr:match("%d+.%d+")) * 1000)
	-- See if we have the import or export devices show as well
	if (elem.dev ~= nil) then 
		if (newVal ~= elem.val) then
			var.Set(elem.var, newVal, elem.sid, elem.dev)
			elem.val = newVal
		end
	end
	-- We only calculate the below when the reading is not zero and start up has completed. No need to do it twice for Import and Export in one round. 
	if (newVal == 0) then return 0 end
	local whElem = mapperData[mapKeys.WholeHouse]
	-- See if we have an active power generator to include, then we are not updating the Whole House reading here unless it is real time
	if (PlugIn.GeneratorInterval == 0) then
		-- Just set WholeHouse value to follow meter value
		local dirVal = newVal * elem.dir
		-- If we have a real time power reader, add its wattage to the Whole House value
		if (PlugIn.GeneratedPowerSource ~= "") then
			local genWatts = var.GetNumber("Watts", PlugIn.EM_SID, PlugIn.GeneratedPowerSource)
			dirVal = dirVal + genWatts
		end
		if (newVal ~= 0) and (dirVal ~= whElem.val) then
			whElem.val = dirVal
			var.Set(elem.var, dirVal, whElem.sid, whElem.dev)
		end
	else	
		-- We use the value of some samples back to compensate for polling delay in solar
		local whWH = BufferValue(math.floor(var.GetNumber("KWH" .. FRC_PFX, whElem.sid, whElem.dev) * 1000))
		-- See if value from Generator has changed
		local now = os.time()
		local genWH = math.floor(var.GetNumber("KWH", PlugIn.EM_SID, PlugIn.GeneratedPowerSource) * 1000)
		local int = math.abs(os.difftime(now, whElem.rtlog.ts))
		if (whElem.rtlog.v1 == -1) then
			-- Is the first update after install
			var.Set("Watts", 0, whElem.sid, whElem.dev)
			LogSet(whElem, genWH, genWH, whWH, now, PlugIn.GeneratorInterval)
			log.Log("SetWatts Generator Initialize.",7)
		else
			if (genWH > whElem.rtlog.v1) then
				local whWatts = math.floor(((genWH - whElem.rtlog.v1) + (whWH - whElem.rtlog.v3)) * 3600 / int)
				if (type(whWatts) == "number") and (whWatts >= 0) and (whWatts < 50000) then 
					log.Log("SetWatts Generator Active: set House Watts to " .. whWatts.." over "..int.." seconds.",7)
					var.Set("Watts", whWatts, whElem.sid, whElem.dev)
					LogSet(whElem, genWH, whElem.rtlog.v1, whWH, now, int)
				else	
					log.Log("SetWatts Generator Active: Value for Watts out of range "..(whWatts or "nil").." over "..int.." seconds.",7)
					LogSet(whElem, genWH, whElem.rtlog.v1, whElem.rtlog.v3, whElem.rtlog.ts, whElem.rtlog.v5)
				end	
				PlugIn.GeneratorIsIdle = false
			else
				-- No updated KWH from Generator, see if we need to assume it is now not producing any power.
				local timedOut = false
				if (PlugIn.GeneratorIsIdle) then
					if (int >= PlugIn.GeneratorInterval) then timedOut = not PlugIn.StartingUp end
				else
					if (int > (PlugIn.GeneratorInterval * 1.5)) then timedOut = not PlugIn.StartingUp end
				end	
				-- See if we timed out or are initializing
				if (timedOut) then				
					local whWH = math.floor(var.GetNumber("KWH" .. FRC_PFX, whElem.sid, whElem.dev) * 1000)
					local whWatts = math.floor((whWH - whElem.rtlog.v3) * 3600 / int)
					if (type(whWatts) == "number" and whWatts >= 0 and whWatts < 50000) then 
						log.Log("SetWatts Generator Idle: set House Watts to " .. whWatts.." over "..int.." seconds.",7)
						var.Set("Watts", whWatts, whElem.sid, whElem.dev)
					else	
						log.Log("SetWatts Generator Idle: Value for Watts out of range " .. (whWatts or "nil").." over "..int.." seconds.",7)
						var.Set("Watts", newVal, whElem.sid, whElem.dev)
					end	
					LogSet(whElem, genWH, genWH, whWH, now, int)
					PlugIn.GeneratorIsIdle = true
				end
			end
		end
	end
	return newVal
end

-- Update the GasMeter reading for single line reading.
local function SetGas(meter, dataStr) 
--	local elem = meter
	-- All map to meter 1 to handle meter numbers 1-4
	local elem = mapperData[mapKeys.Gas_1]
	if (elem.dev == nil) then return "" end
	-- See if we have a new reading value by looking at the timestamp from the meter.
	local dateTime, DLS = dataStr:match("(%d+)(.)")
	local yr, mnth, dy, hh, mm , ss = dateTime:match("(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
	local convertedTimestamp = os.time({year = '20'..yr, month = mnth, day = dy, hour = hh, min = mm, sec = ss, isdst = (DLS == 'S')})
	local int = math.abs(os.difftime(convertedTimestamp, elem.rtlog.ts))
	-- Get last gas reading and the time stamp
	local newVal = tonumber(string.match(dataStr:match("(%d+.%d+*m3)"), "%d+.%d+"))
	if (int ~= 0) then
		if (newVal ~= elem.val) then
			var.Set(elem.var, math.floor(newVal), elem.sid, elem.dev)
			var.Set(elem.var .. FRC_PFX, newVal, elem.sid, elem.dev)
			elem.val = newVal
		end	
		-- Calculate flow value
		local newLiters = math.floor(newVal * 1000)
		if (elem.rtlog.v1 == -1) then
			-- Is the first update after install
			var.Set("Flow", 0, elem.sid, elem.dev)
			LogSet(elem, newLiters, newLiters, 0, convertedTimestamp, 0)
		else
			-- Calculate flow per hour value if it has changed.
			if (newLiters ~= elem.rtlog.v1) then
				local usage = math.floor((newLiters - elem.rtlog.v1) * 3600 / int)
				if (type(usage) ~= "number") or (usage < 0) or (usage > 50000) then 
					log.Log("SetGas Flowing: untrusted number for flow " .. usage.." over "..int.." seconds. Setting to zero.",7)
					usage = 0
				else
					log.Log("SetGas Flowing: set l/h to " .. usage.." over "..int.." seconds.",7)
				end	
				var.Set("Flow", usage, elem.sid, elem.dev)
				LogSet(elem, newLiters, elem.rtlog.v1, usage, convertedTimestamp, int)
			else
				-- No change, so no flow
				var.Set("Flow", 0, elem.sid, elem.dev)
				LogSet(elem, elem.rtlog.v1, elem.rtlog.v1, 0, convertedTimestamp, int)
			end
			-- Set new Gas value on main plugin
			var.Set(elem.lab, math.floor(newVal))
		end
	end
	return newVal
end
-- Handle GAS for meters that have it on a separate line for DSMR 2.2 and 3.0 standard.
local function SetGas2(meter, dataStr) 
--	local elem = meter
	local elem = mapperData[mapKeys.Gas_1]
	if (elem.dev == nil) then return "" end
	local dateTime = dataStr:match("(%d+)")
	local yr, mnth, dy, hh, mm , ss = dateTime:match("(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
	local convertedTimestamp = os.time({year = '20'..yr, month = mnth, day = dy, hour = hh, min = mm, sec = ss})
	local int = math.abs(os.difftime(convertedTimestamp, elem.rtlog.ts))
	if (int ~= 0) then
		PlugIn.indGasComming = true 
		elem.tst = convertedTimestamp
	end
	return 0
end
local function SetGas3(meter, dataStr) 
--	local elem = meter
	local elem = mapperData[mapKeys.Gas_1]
	if (elem.dev == nil) then return "" end
	local newVal = tonumber(dataStr:match("%d+.%d+"))
	local int = math.abs(os.difftime(elem.tst, elem.rtlog.ts))
	if (newVal ~= elem.val) then
		var.Set(elem.var, math.floor(newVal), elem.sid, elem.dev)
		var.Set(elem.var .. FRC_PFX, newVal, elem.sid, elem.dev)
		elem.val = newVal
	end	
	-- Calculate flow value
	local newLiters = math.floor(newVal * 1000)
	if (elem.rtlog.v1 == -1) then
		-- Is the first update after install
		var.Set("Flow", 0, elem.sid, elem.dev)
		LogSet(elem, newLiters, newLiters, 0, elem.tst, 0)
	else
		-- Calculate flow per hour value if it has changed.
		if (newLiters > elem.rtlog.v1) then
			local usage = math.floor((newLiters - elem.rtlog.v1) * 3600 / int)
			if (type(usage) ~= "number") or (usage < 0) or (usage > 50000) then 
				log.Log("SetGas Flowing: untrusted number for flow " .. usage.." over "..int.." seconds. Setting to zero.",7)
				usage = 0
			else
				log.Log("SetGas Flowing: set l/h to " .. usage.." over "..int.." seconds.",7)
			end	
			var.Set("Flow", usage, elem.sid, elem.dev)
			LogSet(elem, newLiters, elem.rtlog.v1, usage, elem.tst, int)
		else	
			var.Set("Flow", 0, elem.sid, elem.dev)
			LogSet(elem, elem.rtlog.v1, elem.rtlog.v1, 0, elem.tst, int)
		end
		-- Set new Gas value on main plugin
		var.Set(elem.lab, math.floor(newVal))
	end
	return newVal
end
-- Set the correct tariff, and switch meters when showing multiple tariffs
local function SetTariff(meter, dataStr) 
	local elem = meter
	local newVal = tonumber(dataStr:match("%d+")) 
	if (newVal ~=  elem.val) then
		-- Toggle watts to other device, set current to zero as it won't update after switch
		elem.val = newVal
		var.Set(elem.var, newVal, elem.sid, elem.dev)
		if (PlugIn.ShowMultiTariff == 1) then 
			local impElem = mapperData[mapKeys.ImpWatts]
			var.Set(impElem.var, 0, impElem.sid, impElem.dev)
			if (newVal == 1) then 
				impElem.dev = mapperData[mapKeys.ImpT1].dev
			elseif (newVal == 2) then 
				impElem.dev = mapperData[mapKeys.ImpT2].dev
			end
			if (PlugIn.ShowExport == 1) then 
				local expElem = mapperData[mapKeys.ExpWatts]
				var.Set(expElem.var, 0, expElem.sid, expElem.dev)
				if (newVal == 1) then 
					expElem.dev = mapperData[mapKeys.ExpT1].dev
				elseif (newVal == 2) then 
					expElem.dev = mapperData[mapKeys.ExpT2].dev
				end
			end
		end
	end
	return newVal
end
-- Set meter P1 output version 
local function SetVersion(meter, dataStr) 
	local elem = meter
	local newVal = dataStr:match("%d+")
	if (newVal ~= elem.val) then
		var.Set(elem.var, newVal)
		elem.val = newVal
		if (tonumber(newVal) >= 50) then -- I think version 5 and up show as 50. Need user to test.
			PlugIn.MessageFrequency = 1 
		else
			PlugIn.MessageFrequency = 10
		end
	end
	-- We only need to set this value once as it never changes after startup. So clear definition till next time.
	mapperData[elem.key] = nil
	return newVal
end
-- Line voltage reading (V5.0 and up)
local function SetLineVolt(meter, dataStr) 
	local elem = meter
	local newVal = tonumber(dataStr:match("%d+.%d+"))
	if (newVal ~= elem.val) then
		var.Set(elem.var, newVal)
		elem.val = newVal
	end
	return newVal
end
-- Line Amps (V4.04 and up)
local function SetLineAmp(meter, dataStr) 
	local elem = meter
	local newVal = tonumber(dataStr:match("%d+"))
	if (newVal ~= elem.val) then
		var.Set(elem.var, newVal)
		elem.val = newVal
	end
	return newVal
end
-- Line Watts (V4.04 and up)
local function SetLineWatts(meter, dataStr) 
	local elem = meter
	local newVal = math.floor(tonumber(dataStr:match("%d+.%d+")) * 1000)
	if (newVal ~= elem.val) then
		if (elem.dev ~= nil and newVal ~= 0) then 
			var.Set(elem.var, newVal * elem.dir, elem.sid, elem.dev) 
		end
		elem.val = newVal
		-- Set new matching Watts value on main plugin
		var.Set(elem.lab, newVal)
	end
	return newVal
end
-- Meter Numbers 
local function SetMeterNum(meter, dataStr) 
	local elem = meter
	local newVal = dataStr:sub(2,-2)
	if (newVal ~= elem.val) then
		local resstr = ""
		for i = 1, newVal:len(),2 do
			resstr = resstr .. string.char(tonumber(newVal:sub(i,i+1),16))
		end
		var.Set(elem.var, resstr)
		elem.val = newVal
	end
	-- We only need to set this value once as it never changes after startup. So clear definition till next time.
	mapperData[elem.key] = nil
	return newVal
end
-- Meter Numbers 
local function SetGasMeterNum(meter, dataStr) 
	local elem = mapperData[mapKeys.GEqID_1]
	local newVal = dataStr:sub(2,-2)
	if (newVal ~= elem.val) then
		local resstr = ""
		for i = 1, newVal:len(),2 do
			resstr = resstr .. string.char(tonumber(newVal:sub(i,i+1),16))
		end
		var.Set(elem.var, resstr)
		elem.val = newVal
	end
	-- We only need to set this value once as it never changes after startup. So clear definition till next time.
	mapperData[elem.key] = nil
	elem = mapperData[mapKeys.GEqID_2]
	mapperData[elem.key] = nil
	elem = mapperData[mapKeys.GEqID_3]
	mapperData[elem.key] = nil
	elem = mapperData[mapKeys.GEqID_4]
	mapperData[elem.key] = nil
	return newVal
end

-- Find the device ID of the type and set the in memory value to the current.
local function findChild(meterID)
	local elem = mapperData[meterID]
	for k, v in pairs(luup.devices) do
		if (v.device_num_parent == PlugIn.THIS_DEVICE and v.id == "SM_"..(elem.desc or "notvalid")) then
			elem.dev = k
			elem.val = var.Default(elem.var, 0, elem.sid, elem.dev)
			-- Disable delete button
			var.Default("HideDeleteButton", 1, "urn:micasaverde-com:serviceId:HaDevice1", elem.dev)
			return true
		end
	end

	-- Dump a copy of the Global Module list for debugging purposes.
	for k, v in pairs(luup.devices) do
		log.Debug("Device Number: " .. k ..
			" v.device_type: " .. tostring(v.device_type) ..
			" v.device_num_parent: " .. tostring(v.device_num_parent) ..
			" v.id: " .. tostring(v.id))
	end 
	return false
end

-- Find child based on having THIS_DEVICE as parent and the expected altID
local function addMeterDevice(childDevices, meterID)
	local elem = mapperData[meterID]
	local meterName = "SM_"..elem.desc
	local childName = "SmartMeter "..elem.desc
	local init = ""

	-- For Power meters, set initial values
	if (elem.xml == PlugIn.PM_XML) then
		init=elem.sid .. ",ActualUsage=1\n" .. 
			 elem.sid .. ",Watts=0\n" .. 
			 elem.sid .. ",KWH=0\n" ..
			 elem.sid .. ",KWH" .. FRC_PFX .. "=0"
		-- For whole house set WholeHouse flag
		if (meterID == WholeHouse) then
			init=init .. "\n" .. elem.sid..",WholeHouse=1\n" .. elem.sid .. "," .. SM_LOG .. "=-1,0,0,0,0"
		end	
	elseif (elem.xml == PlugIn.GE_XML) then
		init=elem.sid .. ",ActualUsage=1\n" .. 
			 elem.sid .. ",WholeHouse=1\n" .. 
			 elem.sid .. ",Flow=0\n" .. 
			 elem.sid .. "," .. elem.var .. "=0\n" ..
			 elem.sid .. "," .. elem.var .. FRC_PFX .. "=0\n" ..
			 elem.sid .. "," .. SM_LOG .. "=-1,0,0,0,0"
	end	

	-- Now add the new device to the tree
	log.Log("Creating child device id " .. meterName .. " (" .. childName .. ")")
	luup.chdev.append(
		    	PlugIn.THIS_DEVICE, -- parent (this device)
		    	childDevices, 		-- pointer from above "start" call
		    	meterName,			-- child Alt ID
		    	childName,			-- child device description 
		    	"", 				-- serviceId (keep blank for UI7 restart avoidance)
		    	elem.xml,			-- device file for given device
		    	"",					-- Implementation file
		    	init,				-- parameters to set 
		    	true)				-- not embedded child devices can go in any room
end

-- V1.2 Check how much memory the plug in uses
function checkMemory()
	local AppMemoryUsed =  math.floor(collectgarbage "count")         -- app's own memory usage in kB
	var.Set("AppMemoryUsed", AppMemoryUsed) 
	luup.call_delay("checkMemory", 600)
end

-- After a minute set flag so we are sure all dependent plug ins are stable.
function finishSetup()
	log.Debug("finishSetup")
	PlugIn.StartingUp = false
	if (PlugIn.GeneratedPowerSource ~= "") then
		local genWatts = var.GetNumber("Watts", PlugIn.EM_SID, PlugIn.GeneratedPowerSource)
		PlugIn.GeneratorIsIdle = (genWatts == 0)
	end	
	checkMemory()
end

-- Start up plug in
function SmartMeter_Init(lul_device)
	PlugIn.THIS_DEVICE = lul_device
	-- start Utility API's
	log = logAPI()
	var = varAPI()
	utils = utilsAPI()
	var.Initialize(PlugIn.SM_SID, PlugIn.THIS_DEVICE)
	
	var.Default("LogLevel", log.LLError)
	log.Initialize(PlugIn.DESCRIPTION, var.GetNumber("LogLevel"))
	utils.Initialize()
	
	log.Log("Starting version "..PlugIn.Version.." device: " .. tostring(PlugIn.THIS_DEVICE),3)
	var.Set("Version", PlugIn.Version)
	-- For UI7 update the JS reference
	local ui7Check = var.Default("UI7Check", "false")
	if (utils.GetUI() == utils.IsUI7 and ui7Check == "false") then
		var.Set("UI7Check", "true")
		var.SetAttribute("device_json", "D_SmartMeter_UI7.json", PlugIn.THIS_DEVICE)
		utils.ReloadLuup()
	end

	-- See if user disabled plug-in 
	local isDisabled = luup.attr_get("disabled", PlugIn.THIS_DEVICE)
	if ((isDisabled == 1) or (isDisabled == "1")) then
		log.Log("Init: Plug-in version "..PlugIn.Version.." - DISABLED",2)
		PlugIn.Disabled = true
		var.Set("MeterType", "Plug-in disabled")
	else
		-- Check if connected via IP. Thanks to nlrb.
		local ip = var.GetAttribute("ip", PlugIn.THIS_DEVICE)
		if (ip ~= nil and ip ~= "") then
			local ipaddr, port = string.match(ip, "(.-):(.*)")
			if (port == nil) then
				ipaddr = ip
				port = 80
			end
			log.Debug("IP = " .. ipaddr .. ", port = " .. port)
			luup.io.open(PlugIn.THIS_DEVICE, ipaddr, tonumber(port))
--			luup.io.intercept()
		end
		-- Check serial port connection
		if (luup.io.is_connected(PlugIn.THIS_DEVICE) == false) then
			utils.SetLuupFailure(1, PlugIn.THIS_DEVICE)
			return false, "No IP:port or serial device specified. Visit the Serial Port configuration tab and choose how the device is attached.", string.format("%s[%d]", luup.devices[PlugIn.THIS_DEVICE].description, PlugIn.THIS_DEVICE)
		else
			log.Debug("Opening serial port")
		end
	end

	-- Read settings.
	PlugIn.ShowMultiTariff = tonumber(var.Default("ShowMultiTariff",0)) -- When 1 show T1 and T2 separately
	PlugIn.ShowExport = tonumber(var.Default("ShowExport",0)) -- When 1 show Import and Export separately
	PlugIn.ShowLines = tonumber(var.Default("ShowLines",0)) -- When 1 show Import / Export phase Lines
	PlugIn.UseGeneratedPower = tonumber(var.Default("UseGeneratedPower",0)) -- When 1 use power generated (e.g. solar) in calculations
	PlugIn.UpdateFrequency = tonumber(var.Default("UpdateFrequency",0)) -- When to reduce the update frequency of variables
	
	if (PlugIn.ShowExport == 1) then
		if (PlugIn.UseGeneratedPower == 1) then
			PlugIn.GeneratedPowerSource = var.Default("GeneratedPowerSource")
			PlugIn.GeneratorInterval = tonumber(var.Default("GeneratorInterval", 0))
		else
			PlugIn.GeneratorInterval = 0
		end
	else
		PlugIn.UseGeneratedPower = 0
		PlugIn.GeneratorInterval = 0
	end
	PlugIn.ShowGas = tonumber(var.Default("ShowGas",0)) -- When 1 show Import and Export separately
	-- Set some of the default options we want to read
	mapperRow(mapKeys.DSMRver, "DSMRVersion", PlugIn.SM_SID, SetVersion)
	mapperRow(mapKeys.Ta, "ActiveTariff", PlugIn.SM_SID, SetTariff)
	mapperRow(mapKeys.EqID, "MeterNumber", PlugIn.SM_SID, SetMeterNum)
	mapperRowChild(mapKeys.WholeHouse, "KWH", PlugIn.EM_SID, 0, nil, 1, "House", "House", PlugIn.PM_XML)
	mapperRowChild(mapKeys.ImpT1, "KWH", PlugIn.EM_SID, -1, SetKWH, 1, "ImportT1", "ImportT1", PlugIn.PM_XML)
	mapperRowChild(mapKeys.ImpT2, "KWH", PlugIn.EM_SID, -1, SetKWH, 1, "ImportT2", "ImportT2", PlugIn.PM_XML)
	if (PlugIn.UseGeneratedPower == 0) then
		mapperRow(mapKeys.ImpWatts, "Watts", PlugIn.EM_SID, SetWatts)
	else	
		mapperRow(mapKeys.ImpWatts, "Watts", PlugIn.EM_SID, SetWattsGen)
	end	
	mapperRowChild(mapKeys.L1ImpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, 1, "Line 1", "L1ImpWatts", PlugIn.PM_XML)
	mapperRowChild(mapKeys.L2ImpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, 1, "Line 2", "L2ImpWatts", PlugIn.PM_XML)
	mapperRowChild(mapKeys.L3ImpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, 1, "Line 3", "L3ImpWatts", PlugIn.PM_XML)
	mapperRow(mapKeys.L1Volt, "L1Volt", PlugIn.SM_SID, SetLineVolt)
	mapperRow(mapKeys.L2Volt, "L2Volt", PlugIn.SM_SID, SetLineVolt)
	mapperRow(mapKeys.L3Volt, "L3Volt", PlugIn.SM_SID, SetLineVolt)
	mapperRow(mapKeys.L1Amp, "L1Ampere", PlugIn.SM_SID, SetLineAmp)
	mapperRow(mapKeys.L2Amp, "L2Ampere", PlugIn.SM_SID, SetLineAmp)
	mapperRow(mapKeys.L3Amp, "L3Ampere", PlugIn.SM_SID, SetLineAmp)
	if (PlugIn.ShowExport == 1) then
		mapperRowChild(mapKeys.ExpT1, "KWH", PlugIn.EM_SID, -1, SetKWH, -1, "ExportT1", "ExportT1", PlugIn.PM_XML)
		mapperRowChild(mapKeys.ExpT2, "KWH", PlugIn.EM_SID, -1, SetKWH, -1, "ExportT2", "ExportT2", PlugIn.PM_XML)
		if (PlugIn.UseGeneratedPower == 0) then
			mapperRow(mapKeys.ExpWatts, "Watts", PlugIn.EM_SID, SetWatts, -1)
		else	
			mapperRow(mapKeys.ExpWatts, "Watts", PlugIn.EM_SID, SetWattsGen, -1)
		end	
		mapperRowChild(mapKeys.L1ExpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, -1, "", "L1ExpWatts", PlugIn.PM_XML)
		mapperRowChild(mapKeys.L2ExpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, -1, "", "L2ExpWatts", PlugIn.PM_XML)
		mapperRowChild(mapKeys.L3ExpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, -1, "", "L3ExpWatts", PlugIn.PM_XML)
	end	
	if (PlugIn.ShowGas == 1) then 
--		mapperRowChild(Gas, "GasMeter", PlugIn.GE_SID, 0, SetGas, 1, "ImportGas", "ImportGas", PlugIn.GE_XML)
		mapperRowChild(mapKeys.Gas_1, "GasMeter", PlugIn.GE_SID, 0, SetGas, 1, "ImportGas", "ImportGas", PlugIn.GE_XML)
		mapperRow(mapKeys.Gas_2, "", PlugIn.GE_SID, SetGas)
		mapperRow(mapKeys.Gas_3, "", PlugIn.GE_SID, SetGas)
		mapperRow(mapKeys.Gas_4, "", PlugIn.GE_SID, SetGas)
		mapperRow(mapKeys.Gas2, "", PlugIn.GE_SID, SetGas2)
		mapperRow(mapKeys.GEqID_1, "GasMeterNumber", PlugIn.SM_SID, SetGasMeterNum)
		mapperRow(mapKeys.GEqID_2, "", PlugIn.SM_SID, SetGasMeterNum)
		mapperRow(mapKeys.GEqID_3, "", PlugIn.SM_SID, SetGasMeterNum)
		mapperRow(mapKeys.GEqID_4, "", PlugIn.SM_SID, SetGasMeterNum)
	end

	-- Setup child device and mapping details.
	mapperData[mapKeys.Ta].val = var.Default("ActiveTariff",1)
	PlugIn.GeneratorPrevLen = var.Default("GeneratorOffset",0)
	if (PlugIn.ShowMultiTariff == 0 and PlugIn.ShowExport == 1) then 
		-- Tweak child descriptions if no multi tariff
		mapperData[mapKeys.ImpT1].desc = "Import"
		mapperData[mapKeys.ExpT1].desc = "Export"
	end
	-- set up logging to syslog	
	log.SetSyslog(var.Default("Syslog")) -- send to syslog if IP address and Port 'XXX.XX.XX.XXX:YYY' (default port 514)

	-- Create the child devices the user wants
	local childDevices = luup.chdev.start(PlugIn.THIS_DEVICE);  
	
    -- Create devices needed if not exist
	addMeterDevice(childDevices, mapKeys.WholeHouse)
	if (PlugIn.ShowMultiTariff == 1 or PlugIn.ShowExport == 1) then addMeterDevice(childDevices,mapKeys.ImpT1) end
	if (PlugIn.ShowMultiTariff == 1) then addMeterDevice(childDevices, mapKeys.ImpT2) end
	if (PlugIn.ShowExport == 1) then
		addMeterDevice(childDevices, mapKeys.ExpT1)
		if (PlugIn.ShowMultiTariff == 1) then addMeterDevice(childDevices, mapKeys.ExpT2) end
	end	
	if (PlugIn.ShowGas == 1) then addMeterDevice(childDevices, mapKeys.Gas_1) end
	if (PlugIn.ShowLines == 1) then
		addMeterDevice(childDevices, mapKeys.L1ImpWatts)
		addMeterDevice(childDevices, mapKeys.L2ImpWatts)
		addMeterDevice(childDevices, mapKeys.L3ImpWatts)
	end	
	-- Vera will reload here when there are new devices or changes to a child
	luup.chdev.sync(PlugIn.THIS_DEVICE, childDevices)

	-- When disabled, we are done here.
	if (PlugIn.Disabled == true) then
		return true, "Plug-in Disabled.", PlugIn.DESCRIPTION
	end	

	mapperData[mapKeys.Ta].dev = PlugIn.THIS_DEVICE
	-- Pickup device IDs from names
	findChild(mapKeys.WholeHouse)
	mapperData[mapKeys.WholeHouse].rtlog = LogGet(mapperData[mapKeys.WholeHouse])
	if (PlugIn.ShowMultiTariff == 1 or PlugIn.ShowExport == 1) then findChild(mapKeys.ImpT1) end
	if (PlugIn.ShowMultiTariff == 1) then 
		findChild(mapKeys.ImpT2) 
	else
		mapperData[mapKeys.ImpT2].dev = mapperData[mapKeys.ImpT1].dev
	end
	if (PlugIn.ShowExport == 1) then
		findChild(mapKeys.ExpT1)
		if (PlugIn.ShowMultiTariff == 1) then 
			findChild(mapKeys.ExpT2) 
		else
			mapperData[mapKeys.ExpT2].dev = mapperData[mapKeys.ExpT1].dev
		end
	end	
	if (PlugIn.ShowGas == 1) then 
		findChild(mapKeys.Gas_1)
		mapperData[mapKeys.Gas_1].rtlog = LogGet(mapperData[mapKeys.Gas_1])
	end
	if (PlugIn.ShowLines == 1) then
		findChild(mapKeys.L1ImpWatts)
		findChild(mapKeys.L2ImpWatts)
		findChild(mapKeys.L3ImpWatts)
		if (PlugIn.ShowExport == 1) then 
			mapperData[mapKeys.L1ExpWatts].dev = mapperData[mapKeys.L1ImpWatts].dev
			mapperData[mapKeys.L2ExpWatts].dev = mapperData[mapKeys.L2ImpWatts].dev
			mapperData[mapKeys.L3ExpWatts].dev = mapperData[mapKeys.L3ImpWatts].dev
		end
	end	
	-- For current watt readings map to right device ID
	if (PlugIn.ShowMultiTariff == 1) then 
		if (mapperData[mapKeys.Ta].val == 1) then 
			mapperData[mapKeys.ImpWatts].dev = mapperData[mapKeys.ImpT1].dev
			if (PlugIn.ShowExport == 1) then mapperData[mapKeys.ExpWatts].dev = mapperData[mapKeys.ExpT1].dev end
		else
			mapperData[mapKeys.ImpWatts].dev = mapperData[mapKeys.ImpT2].dev
			if (PlugIn.ShowExport == 1) then mapperData[mapKeys.ExpWatts].dev = mapperData[mapKeys.ExpT2].dev end
		end
	else	
		mapperData[mapKeys.ImpWatts].dev = mapperData[mapKeys.ImpT1].dev
		if (PlugIn.ShowExport == 1) then mapperData[mapKeys.ExpWatts].dev = mapperData[mapKeys.ExpT1].dev end
	end
	PlugIn.GeneratorPrevLen = tonumber(var.Default("GeneratorSampleDelay",0)) / 10
	if (PlugIn.GeneratorPrevLen > 0) then
		for i = 1, PlugIn.GeneratorPrevLen do
			GeneratorPrev[i] = 0
		end
	end	
	-- Set functions/variables to Global space if the need to be
	_G.mapperData = mapperData
	luup.call_delay("finishSetup", 30)
	luup.call_delay("SmartMeter_registerWithAltUI", 40, "", false)
	log.Debug("SmartMeter has started...")
	utils.SetLuupFailure(0, PlugIn.THIS_DEVICE)
	return true
end

---------------------------------------------------------------------------------------------
-- Data line has been received via serial. Process when ready
---------------------------------------------------------------------------------------------
function SmartMeter_Incoming(data)
    if ((not data) or PlugIn.Disabled == true or PlugIn.StartingUp == true or luup.is_ready(lul_device) == false) then
        return
    end
	local chr = string.sub(data,1,1)
	if chr == "/" then
		if PlugIn.UpdateFrequency > 0 then
			-- Skip messages until we hit requested update frequency
			log.Log("MessageNum : "..PlugIn.MessageNum)
			if PlugIn.MessageNum <= 1 then
				var.Set("MeterType", string.sub(data,2))
				PlugIn.InMessage = true
				PlugIn.MessageNum = PlugIn.UpdateFrequency / PlugIn.MessageFrequency
			else
				PlugIn.MessageNum = PlugIn.MessageNum - 1
			end
		else
			var.Set("MeterType", string.sub(data,2))
			PlugIn.InMessage = true
		end
	elseif chr == "!" then
		PlugIn.InMessage = false
	elseif PlugIn.InMessage then
		if (PlugIn.indGasComming) then
			-- GAS on DSMR 2.x and 3.0 where GAS reading is on its own line after key line 0-1:24.3.0.
			SetGas3("",data)
			PlugIn.indGasComming = false
		elseif chr ~= "" then
			-- Get line key
			local Key = data:match("[0-9%:%-%.%/]+")
			if Key then
				local elem = mapperData[Key]
				if elem then
					-- Call Set function
					local res, val = pcall(mapperData[Key].func, elem, data:sub(Key:len()+1))
					if res then
						log.Debug("Found key : "..Key.." for "..elem.var.." to set to value "..(val or 'nil'))
					else
						log.Log("Found key : "..Key.." for "..elem.var.." but failed to obtain value from " .. data:sub(Key:len()+1),2)
						log.Log("Err MSG: "..(val or 'nil'),2)
					end
				else	
					log.Debug("Not processing : "..(data or 'nil'))
				end
			else
				log.Debug("No key found in : "..(data or 'nil'))
			end
		end	
	end	
end
