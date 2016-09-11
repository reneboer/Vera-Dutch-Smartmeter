--[==[
	Module L_SmartMeter.lua
	Written by R.Boer. 
	V1.8 22 May 2016

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

local socketLib = require("socket")
local PlugIn = {
	Version = "1.8",
	DESCRIPTION = "Smart Meter", 
	SM_SID = "urn:rboer-com:serviceId:SmartMeter1", 
	EM_SID = "urn:micasaverde-com:serviceId:EnergyMetering1", 
	GE_SID = "urn:rboer-com:serviceId:SmartMeterGAS1", 
	PM_XML = "D_PowerMeter1.xml", 
	GE_XML = "D_SmartMeterGAS.xml",
	THIS_DEVICE = 0,
	Disabled = false,
	syslog,
	LogLevel = 3,
	ShowMultiTariff = 0,
	ShowExport = 0,
	ShowGas = 0,
	UseGeneratedPower = 0,
	GeneratedPowerSource = '',
	GeneratorInterval = 0,
	GeneratorIsIdle = true,
	GeneratorInd = 0,
	GeneratorPrevLen = 0,
	StartingUp = true,
	indGasComming = false -- Some meter types split Gas reading over two lines
}
local GeneratorPrev = {}
local mapperData = {}  

-- Keys for Smart Meter values
local Mt, DSMRver, Ta, EqID = "/", "1-3:0.2.8", "0-0:96.14.0", "0-0:96.1.1"
local ImpT1, ImpT2, ExpT1, ExpT2 = "1-0:1.8.1", "1-0:1.8.2", "1-0:2.8.1", "1-0:2.8.2"
local ImpWatts, ExpWatts = "1-0:1.7.0", "1-0:2.7.0"
local L1Volt, L2Volt, L3Volt = "1-0:32.7.0", "1-0:52.7.0", "1-0:72.7.0"
local L1Amp, L2Amp, L3Amp = "1-0:31.7.0", "1-0:51.7.0", "1-0:71.7.0"
local L1ImpWatts, L2ImpWatts, L3ImpWatts = "1-0:21.7.0", "1-0:41.7.0", "1-0:61.7.0"
local L1ExpWatts, L2ExpWatts, L3ExpWatts = "1-0:22.7.0", "1-0:42.7.0", "1-0:62.7.0"
local Gas, Gas2, GEqID = "0-1:24.2.1", "0-1:24.3.0", "0-1:96.1.0"
local WholeHouse = "9-9:9.9.9" -- Dummy Meter reading type for WholeHouse device
local FRC_PFX = "_frac" -- post fix for fractional values. We display meter readings without fractions on the UI.
local SM_LOG = "SMLog" -- Log values needed for Whole House with Power Generator calculations and Gas Meter.

local Icon = {
	Variable = "IconSet",	-- Variable controlling the iconsVariable
	IDLE = '0',		-- No background
	OK = '1',		-- Green
	BUSY = '2',		-- Blue
	WAIT = '3',		-- Amber
	ERROR = '4'		-- Red
}
local TaskData = {
	Description = "Smart Meter",
	taskHandle = -1,
	ERROR = 2,
	ERROR_PERM = -2,
	SUCCESS = 4,
	BUSY = 1
}
local PluginImages = { 'SmartMeter' }

---------------------------------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------------------------------
local function log(text, level) 
	local level = (level or 10)
	if (PlugIn.LogLevel >= level) then
		if (PlugIn.syslog) then
			local slvl
			if (level == 1) then slvl = 2 
			elseif (level == 2) then slvl = 4 
			elseif (level == 3) then slvl = 5 
			elseif (level == 4) then slvl = 5 
			elseif (level == 7) then slvl = 6 
			elseif (level == 8) then slvl = 6 
			else slvl = 7
			end
			PlugIn.syslog:send(text,slvl) 
		else
			if (level == 10) then level = 50 end
			luup.log(PlugIn.DESCRIPTION .. ": " .. text or "no text", (level or 50)) 
		end	
	end	
end 
-- Get variable value.
-- Use SM_SID and THIS_DEVICE as defaults
local function varGet(name, device, service)
	local value = luup.variable_get(service or PlugIn.SM_SID, name, tonumber(device or PlugIn.THIS_DEVICE))
	return (value or '')
end
-- Update variable when value is different than current.
-- Use SM_SID and THIS_DEVICE as defaults
local function varSet(name, value, device, service)
	local service = service or PlugIn.SM_SID
	local device = tonumber(device or PlugIn.THIS_DEVICE)
	local old = varGet(name, device, service)
	if (tostring(value) ~= old) then 
		luup.variable_set(service, name, value, device)
	end
end
--get device Variables, creating with default value if non-existent
local function defVar(name, default, device, service)
	local service = service or PlugIn.SM_SID
	local device = tonumber(device or PlugIn.THIS_DEVICE)
	local value = luup.variable_get(service, name, device) 
	if (not value) then
		value = default	or ''							-- use default value or blank
		luup.variable_set(service, name, value, device)	-- create missing variable with default value
	end
	return value
end
-- Set message in task window.
local function task(text, mode) 
	local mode = mode or TaskData.ERROR 
	if (mode ~= TaskData.SUCCESS) then 
		if (mode == TaskData.ERROR_PERM) then
			log("task: " .. (text or "no text"), 1) 
		else	
			log("task: " .. (text or "no text")) 
		end 
	end 
	TaskData.taskHandle = luup.task(text, (mode == TaskData.ERROR_PERM) and TaskData.ERROR or mode, TaskData.Description, TaskData.taskHandle) 
end 
-- Set a luup failure message
local function setluupfailure(status,devID)
	if (luup.version_major < 7) then status = status ~= 0 end        -- fix UI5 status type
	luup.set_failure(status,devID)
end
-- Syslog server support. From Netatmo plugin by akbooer
local function syslog_server (ip_and_port, tag, hostname)
	local sock = socketLib.udp()
	local facility = 1    -- 'user'
	local emergency, alert, critical, error, warning, notice, info, debug = 0,1,2,3,4,5,6,7
	local ip, port = ip_and_port:match "^(%d+%.%d+%.%d+%.%d+):(%d+)$"
	if not ip or not port then return nil, "invalid IP or PORT" end
	local serialNo = luup.pk_accesspoint
	hostname = ("Vera-"..serialNo) or "Vera"
	if not tag or tag == '' then tag = PlugIn.DESCRIPTION end
	tag = tag:gsub("[^%w]","") or PlugIn.DESCRIPTION  -- only alphanumeric, no spaces or other
	local function send (self, content, severity)
		content  = tostring (content)
		severity = tonumber (severity) or info
		local priority = facility*8 + (severity%8)
		local msg = ("<%d>%s %s %s: %s\n"):format (priority, os.date "%b %d %H:%M:%S", hostname, tag, content)
		sock:send (msg) 
	end
	local ok, err = sock:setpeername(ip, port)
	if ok then ok = {send = send} end
	return ok, err
end
-- Set the status Icon
local function setStatusIcon(status)
	varSet(Icon.Variable, status)
end
-- Luup Reload function for UI5,6 and 7
local function luup_reload()
	if (luup.version_major < 6) then 
		luup.call_action("urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {}, 0)
	else
		luup.reload()
	end
end
-- Create links for UI6 or UI7 image locations if missing.
local function check_images(imageTable)
	local imagePath =""
	local sourcePath = "/www/cmh/skins/default/icons/"
	if (luup.version_major >= 7) then
		imagePath = "/www/cmh/skins/default/img/devices/device_states/"
	elseif (luup.version_major == 6) then
		imagePath = "/www/cmh_ui6/skins/default/icons/"
	else
		-- Default if for UI5, no idea what applies to older versions
		imagePath = "/www/cmh/skins/default/icons/"
	end
	if (imagePath ~= sourcePath) then
		for i = 1, #imageTable do
			local source = sourcePath..imageTable[i]..".png"
			local target = imagePath..imageTable[i]..".png"
			os.execute(("[ ! -e %s ] && ln -s %s %s"):format(target, source, target))
		end
	end	
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
	local lgstr = varGet(SM_LOG, meter.dev, meter.sid)
	local a,b,c,d,e = lgstr:match("(%d+),(%d+),(%d+),(%d+),(%d+)") or -1, 0, 0, 0, 0
	if (lgstr:sub(1,1) == "-") then a = a * -1 end
	return {v1=tonumber(a), v2=tonumber(b),v3=tonumber(c),ts=tonumber(d),v5=tonumber(e)}
end
local function LogSet(meter,val1,val2,val3,timest,val5)
	local lt = meter.rtlog
	lt.v1 = val1 or -1
	lt.v2 = val2 or 0
	lt.v3 = val3 or 0
	lt.ts = timest or 0
	lt.v5 = val5 or 0
	varSet(SM_LOG, lt.v1..","..lt.v2..","..lt.v3..","..lt.ts..","..lt.v5, meter.dev, meter.sid)
end
local function LogMerge(lt)
	return lt.v1..","..lt.v2..","..lt.v3..","..lt.ts..","..lt.v5
end
function SmartMeter_registerWithAltUI()
	-- Register with ALTUI once it is ready
	local ALTUI_SID = "urn:upnp-org:serviceId:altui1"
	for k, v in pairs(luup.devices) do
		if (v.device_type == "urn:schemas-upnp-org:device:altui:1") then
			if luup.is_ready(k) then
				log("Found ALTUI device "..k.." registering devices.")
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
				log("ALTUI plugin is not yet ready, retry in a bit..")
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
	varSet(elem.var, math.floor(newVal), elem.dev, elem.sid)
	varSet(elem.var .. FRC_PFX, newVal, elem.dev, elem.sid)
end
-- Set KWH values
local function SetKWH(meter, dataStr)
	local elem = meter
	local newVal = tonumber(dataStr:match("%d+.%d+")) 
	if (newVal ~= elem.val) then
		elem.val = newVal
		local impVal = 0
		local expVal = 0
		local impT1Elem = mapperData[ImpT1]
		local impT2Elem = mapperData[ImpT2]
		local whElem = mapperData[WholeHouse]
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
			local expT1Elem = mapperData[ExpT1]
			local expT2Elem = mapperData[ExpT2]
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
		varSet(elem.lab, math.floor(newVal))
		varSet(whElem.lab, math.floor(impVal - expVal))
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
			varSet(elem.var, newVal, elem.dev, elem.sid)
			elem.val = newVal
		end
	end
	-- We only calculate the below when the reading is not zero and start up has completed. No need to do it twice for Import and Export in one round. 
	if (newVal == 0) then return 0 end
	local whElem = mapperData[WholeHouse]
	-- Just set WholeHouse value to follow meter value
	local dirVal = newVal * elem.dir
	if (newVal ~= 0) and (dirVal ~= whElem.val) then
		whElem.val = dirVal
		varSet(elem.var, dirVal, whElem.dev, whElem.sid)
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
			varSet(elem.var, newVal, elem.dev, elem.sid)
			elem.val = newVal
		end
	end
	-- We only calculate the below when the reading is not zero and start up has completed. No need to do it twice for Import and Export in one round. 
	if (newVal == 0) then return 0 end
	local whElem = mapperData[WholeHouse]
	-- See if we have an active power generator to include, then we are not updating the Whole House reading here unless it is real time
	if (PlugIn.GeneratorInterval == 0) then
		-- Just set WholeHouse value to follow meter value
		local dirVal = newVal * elem.dir
		-- If we have a real time power reader, add its wattage to the Whole House value
		if (PlugIn.GeneratedPowerSource ~= "") then
			local genWatts = tonumber(varGet("Watts", PlugIn.GeneratedPowerSource, PlugIn.EM_SID))
			dirVal = dirVal + genWatts
		end
		if (newVal ~= 0) and (dirVal ~= whElem.val) then
			whElem.val = dirVal
			varSet(elem.var, dirVal, whElem.dev, whElem.sid)
		end
	else	
		-- We use the value of some samples back to compensate for polling delay in solar
		local whWH = BufferValue(math.floor(tonumber(varGet("KWH" .. FRC_PFX, whElem.dev, whElem.sid)) * 1000))
		-- See if value from Generator has changed
		local now = os.time()
		local genWH = math.floor(tonumber(varGet("KWH", PlugIn.GeneratedPowerSource, PlugIn.EM_SID)) * 1000)
		local int = math.abs(os.difftime(now, whElem.rtlog.ts))
		if (whElem.rtlog.v1 == -1) then
			-- Is the first update after install
			varSet("Watts", 0, whElem.dev, whElem.sid)
			LogSet(whElem, genWH, genWH, whWH, now, PlugIn.GeneratorInterval)
			log("SetWatts Generator Initialize.",7)
		else
			if (genWH > whElem.rtlog.v1) then
				local whWatts = math.floor(((genWH - whElem.rtlog.v1) + (whWH - whElem.rtlog.v3)) * 3600 / int)
				if (type(whWatts) == "number") and (whWatts >= 0) and (whWatts < 50000) then 
					log("SetWatts Generator Active: set House Watts to " .. whWatts.." over "..int.." seconds.",7)
					varSet("Watts", whWatts, whElem.dev, whElem.sid)
					LogSet(whElem, genWH, whElem.rtlog.v1, whWH, now, int)
				else	
					log("SetWatts Generator Active: Value for Watts out of range "..(whWatts or "nil").." over "..int.." seconds.",7)
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
					local whWH = math.floor(tonumber(varGet("KWH" .. FRC_PFX, whElem.dev, whElem.sid)) * 1000)
					local whWatts = math.floor((whWH - whElem.rtlog.v3) * 3600 / int)
					if (type(whWatts) == "number" and whWatts >= 0 and whWatts < 50000) then 
						log("SetWatts Generator Idle: set House Watts to " .. whWatts.." over "..int.." seconds.",7)
						varSet("Watts", whWatts, whElem.dev, whElem.sid)
					else	
						log("SetWatts Generator Idle: Value for Watts out of range " .. (whWatts or "nil").." over "..int.." seconds.",7)
						varSet("Watts", newVal, whElem.dev, whElem.sid)
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
	local elem = meter
	if (elem.dev == nil) then return "" end
	-- See if we have a new reading value by looking at the timestamp from the meter.
	local dateTime, DLS = dataStr:match("(%d+)(.)")
	local yr, mnth, dy, hh, mm , ss = dateTime:match("(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
	local convertedTimestamp = os.time({year = '20'..yr, month = mnth, day = dy, hour = hh, min = mm, sec = ss, isdst = (DTS == 'S')})
	local int = math.abs(os.difftime(convertedTimestamp, elem.rtlog.ts))
	-- Get last gas reading and the time stamp
	local newVal = tonumber(string.match(dataStr:match("(%d+.%d+*m3)"), "%d+.%d+"))
	if (int ~= 0) then
		if (newVal ~= elem.val) then
			varSet(elem.var, math.floor(newVal), elem.dev, elem.sid)
			varSet(elem.var .. FRC_PFX, newVal, elem.dev, elem.sid)
			elem.val = newVal
		end	
		-- Calculate flow value
		local newLiters = math.floor(newVal * 1000)
		if (elem.rtlog.v1 == -1) then
			-- Is the first update after install
			varSet("Flow", 0, elem.dev, elem.sid)
			LogSet(elem, newLiters, newLiters, 0, convertedTimestamp, 0)
		else
			-- Calculate flow per hour value if it has changed.
			if (newLiters ~= elem.rtlog.v1) then
				local usage = math.floor((newLiters - elem.rtlog.v1) * 3600 / int)
				if (type(usage) ~= "number") or (usage < 0) or (usage > 50000) then 
					log("SetGas Flowing: untrusted number for flow " .. usage.." over "..int.." seconds. Setting to zero.",7)
					usage = 0
				else
					log("SetGas Flowing: set l/h to " .. usage.." over "..int.." seconds.",7)
				end	
				varSet("Flow", usage, elem.dev, elem.sid)
				LogSet(elem, newLiters, elem.rtlog.v1, usage, convertedTimestamp, int)
			else
				-- No change, so no flow
				varSet("Flow", 0, elem.dev, elem.sid)
				LogSet(elem, elem.rtlog.v1, elem.rtlog.v1, 0, convertedTimestamp, int)
			end
			-- Set new Gas value on main plugin
			varSet(elem.lab, math.floor(newVal))
		end
	end
	return newVal
end
-- Handle GAS for meters that have it on a separate line for DSMR 2.2 and 3.0 standard.
local function SetGas2(meter, dataStr) 
--	local elem = meter
	local elem = mapperData[Gas]
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
	local elem = meter
	if (elem.dev == nil) then return "" end
	local newVal = tonumber(dataStr:match("%d+.%d+"))
	local int = math.abs(os.difftime(elem.tst, elem.rtlog.ts))
	if (newVal ~= elem.val) then
		varSet(elem.var, math.floor(newVal), elem.dev, elem.sid)
		varSet(elem.var .. FRC_PFX, newVal, elem.dev, elem.sid)
		elem.val = newVal
	end	
	-- Calculate flow value
	local newLiters = math.floor(newVal * 1000)
	if (elem.rtlog.v1 == -1) then
		-- Is the first update after install
		varSet("Flow", 0, elem.dev, elem.sid)
		LogSet(elem, newLiters, newLiters, 0, elem.tst, 0)
	else
		-- Calculate flow per hour value if it has changed.
		if (newLiters > elem.rtlog.v1) then
			local usage = math.floor((newLiters - elem.rtlog.v1) * 3600 / int)
			if (type(usage) ~= "number") or (usage < 0) or (usage > 50000) then 
				log("SetGas Flowing: untrusted number for flow " .. usage.." over "..int.." seconds. Setting to zero.",7)
				usage = 0
			else
				log("SetGas Flowing: set l/h to " .. usage.." over "..int.." seconds.",7)
			end	
			varSet("Flow", usage, elem.dev, elem.sid)
			LogSet(elem, newLiters, elem.rtlog.v1, usage, elem.tst, int)
		else	
			varSet("Flow", 0, elem.dev, elem.sid)
			LogSet(elem, math.floor(newVal * 1000), elem.rtlog.v1, 0, elem.tst, int)
		end
		-- Set new Gas value on main plugin
		varSet(elem.lab, math.floor(newVal))
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
		varSet(elem.var, newVal, elem.dev, elem.sid)
		if (PlugIn.ShowMultiTariff == 1) then 
			local impElem = mapperData[ImpWatts]
			varSet(impElem.var, 0, impElem.dev, impElem.sid)
			if (newVal == 1) then 
				impElem.dev = mapperData[ImpT1].dev
			elseif (newVal == 2) then 
				impElem.dev = mapperData[ImpT2].dev
			end
			if (PlugIn.ShowExport == 1) then 
				local expElem = mapperData[ExpWatts]
				varSet(expElem.var, 0, expElem.dev, expElem.sid)
				if (newVal == 1) then 
					expElem.dev = mapperData[ExpT1].dev
				elseif (newVal == 2) then 
					expElem.dev = mapperData[ExpT2].dev
				end
			end
		end
	end
	return newVal
end
-- Set meter description
local function SetMeter(meter, dataStr) 
	local elem = meter
	if (dataStr ~= elem.val) then
		varSet(elem.var, dataStr)
		elem.val = dataStr
	end
	-- We only need to set this value once as it never changes after startup. So clear definition till next time.
	mapperData[elem.key] = nil
	return dataStr
end
-- Set meter P1 output version 
local function SetVersion(meter, dataStr) 
	local elem = meter
	local newVal = dataStr:match("%d+")
	if (newVal ~= elem.val) then
		varSet(elem.var, newVal)
		elem.val = newVal
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
		varSet(elem.var, newVal)
		elem.val = newVal
	end
	return newVal
end
-- Line Amps (V4.04 and up)
local function SetLineAmp(meter, dataStr) 
	local elem = meter
	local newVal = tonumber(dataStr:match("%d+"))
	if (newVal ~= elem.val) then
		varSet(elem.var, newVal)
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
			varSet(elem.var, newVal * elem.dir, elem.dev, elem.sid) 
		end
		elem.val = newVal
		-- Set new matching Watts value on main plugin
		varSet(elem.lab, newVal)
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
		varSet(elem.var, resstr)
		elem.val = newVal
	end
	-- We only need to set this value once as it never changes after startup. So clear definition till next time.
	mapperData[elem.key] = nil
	return newVal
end
--[==[ -- Mapping for each key value we are interested in.
local mapperData = {
	[Mt] = {var = "MeterType", sid = SM_SID, dev = nil, val = "", func = SetMeter, dir = 1, desc = "", xml = nil},
	[DSMRver] = {var = "DSMRVersion", sid = SM_SID, dev = nil, val = 0, func = SetVersion, dir = 1, desc = "", xml = nil},
	[Ta] = {var = "ActiveTariff", sid = SM_SID, dev = nil, val = 0, func = SetTariff, dir = 1, desc = "", xml = nil},
	[EqID] = {var = "MeterNumber", sid = SM_SID, dev = nil, val = 0, func = SetMeterNum, dir = 1, desc = "", xml = nil},
	[L1Volt] = {var = "L1Volt", sid = SM_SID, dev = nil, val = 0, func = SetLineVolt, dir = 1, sum = 0, desc = "", lab = "", xml = nil},
	[L2Volt] = {var = "L2Volt", sid = SM_SID, dev = nil, val = 0, func = SetLineVolt, dir = 1, sum = 0, desc = "", lab = "", xml = nil},
	[L3Volt] = {var = "L3Volt", sid = SM_SID, dev = nil, val = 0, func = SetLineVolt, dir = 1, sum = 0, desc = "", lab = "", xml = nil},
	[L1Amp] = {var = "L1Ampere", sid = SM_SID, dev = nil, val = 0, func = SetLineAmp, dir = 1, sum = 0, desc = "", lab = "", xml = nil},
	[L2Amp] = {var = "L2Ampere", sid = SM_SID, dev = nil, val = 0, func = SetLineAmp, dir = 1, sum = 0, desc = "", lab = "", xml = nil},
	[L3Amp] = {var = "L3Ampere", sid = SM_SID, dev = nil, val = 0, func = SetLineAmp, dir = 1, sum = 0, desc = "", lab = "", xml = nil},
	[L1ImpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetLineWatts, dir = 1, sum = 0, desc = "Line 1", lab = "L1ImpWatts", xml = PM_XML},
	[L2ImpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetLineWatts, dir = 1, sum = 0, desc = "Line 2", lab = "L2ImpWatts", xml = PM_XML},
	[L3ImpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetLineWatts, dir = 1, sum = 0, desc = "Line 3", lab = "L3ImpWatts", xml = PM_XML},
	[L1ExpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetLineWatts, dir = -1, sum = 0, desc = "", lab = "L1ExpWatts", xml = PM_XML},
	[L2ExpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetLineWatts, dir = -1, sum = 0, desc = "", lab = "L2ExpWatts", xml = PM_XML},
	[L3ExpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetLineWatts, dir = -1, sum = 0, desc = "", lab = "L3ExpWatts", xml = PM_XML},
	[ImpT1] = {var = "KWH", sid = EM_SID, dev = nil, val = -1, func = SetKWH, dir = 1, sum = 0, desc = "ImportT1", lab = "ImportT1", xml = PM_XML},
	[ImpT2] = {var = "KWH", sid = EM_SID, dev = nil, val = -1, func = SetKWH, dir = 1, sum = 0, desc = "ImportT2", lab = "ImportT2", xml = PM_XML},
	[ExpT1] = {var = "KWH", sid = EM_SID, dev = nil, val = -1, func = SetKWH, dir = -1, sum = 0, desc = "ExportT1", lab = "ExportT1", xml = PM_XML},
	[ExpT2] = {var = "KWH", sid = EM_SID, dev = nil, val = -1, func = SetKWH, dir = -1, sum = 1, desc = "ExportT2", lab = "ExportT2", xml = PM_XML},
	[ImpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetWatts, dir = 1, sum = 0, desc = "", xml = nil},
	[ExpWatts] = {var = "Watts", sid = EM_SID, dev = nil, val = 0, func = SetWatts, dir = -1, sum = 1, desc = "", xml = nil},
	[Gas2]= {var = "", sid = GE_SID, dev = nil, val = 0, func = SetGas2, dir = 1, desc = "", xml = nil},
	[Gas]= {var = "GasMeter", sid = GE_SID, dev = nil, val = 0, func = SetGas, dir = 1, desc = "ImportGas", lab = "ImportGas", xml = GE_XML, logrt = nil},
	[GEqID] = {var = "GasMeterNumber", sid = SM_SID, dev = nil, val = 0, func = SetMeterNum, dir = 1, desc = "", xml = nil},
	[WholeHouse]= {var = "KWH", sid = EM_SID, dev = nil, val = 0, func = nil, dir = 1, desc = "House", lab = "House", xml = PM_XML, logrt = nil}
}
--]==]

-- Find the device ID of the type and set the in memory value to the current.
local function findChild(meterID)
	local elem = mapperData[meterID]
	for k, v in pairs(luup.devices) do
		if (v.device_num_parent == PlugIn.THIS_DEVICE and v.id == "SM_"..(elem.desc or "notvalid")) then
			elem.dev = k
			elem.val = defVar(elem.var, 0, elem.dev, elem.sid)
			-- Disable delete button
			defVar("HideDeleteButton", 1, elem.dev, "urn:micasaverde-com:serviceId:HaDevice1")
			return true
		end
	end

	-- Dump a copy of the Global Module list for debugging purposes.
	for k, v in pairs(luup.devices) do
		log("Device Number: " .. k ..
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
	log("Creating child device id " .. meterName .. " (" .. childName .. ")")
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
	varSet("AppMemoryUsed", AppMemoryUsed) 
	luup.call_delay("checkMemory", 600)
end

-- After a minute set flag so we are sure all dependent plug ins are stable.
function finishSetup()
	log("finishSetup")
	PlugIn.StartingUp = false
	if (PlugIn.GeneratedPowerSource ~= "") then
		local genWatts = tonumber(varGet("Watts", PlugIn.GeneratedPowerSource, PlugIn.EM_SID))
		PlugIn.GeneratorIsIdle = (genWatts == 0)
	end	
	checkMemory()
end

-- Start up plug in
function SmartMeter_Init(lul_device)
	PlugIn.THIS_DEVICE = lul_device
	log("Starting "..PlugIn.DESCRIPTION.." device: " .. tostring(PlugIn.THIS_DEVICE),3)
	varSet("Version", PlugIn.Version)
	local syslogInfo = defVar("Syslog")	-- send to syslog if IP address and Port 'XXX.XX.XX.XXX:YYY' (default port 514)
	PlugIn.LogLevel = tonumber(defVar("LogLevel", 1))
	-- For UI7 update the JS reference
	local ui7Check = defVar("UI7Check", "false")
	if (luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
		varSet("UI7Check", "true")
		luup.attr_set("device_json", "D_SmartMeter_UI7.json", PlugIn.THIS_DEVICE)
		luup_reload()
	end

	-- See if user disabled plug-in 
	local isDisabled = luup.attr_get("disabled", PlugIn.THIS_DEVICE)
	if ((isDisabled == 1) or (isDisabled == "1")) then
		log("Init: Plug-in version "..PlugIn.Version.." - DISABLED",2)
		PlugIn.Disabled = true
		varSet("MeterType", "Plug-in disabled")
	else
		-- Check if connected via IP. Thanks to nlrb.
		local ip = luup.attr_get("ip", PlugIn.THIS_DEVICE)
		if (ip ~= nil and ip ~= "" and ip ~= "127.0.0.1") then
			local ipaddr, port = string.match(ip, "(.-):(.*)")
			if (port == nil) then
				ipaddr = ip
				port = 80
			end
			log("IP = " .. ipaddr .. ", port = " .. port)
			luup.io.open(PlugIn.THIS_DEVICE, ipaddr, tonumber(port))
--			luup.io.intercept()
		end
		-- Check serial port connection
		if (luup.io.is_connected(PlugIn.THIS_DEVICE) == false) then
			setluupfailure(1, PlugIn.THIS_DEVICE)
			return false, "No IP:port or serial device specified. Visit the Serial Port configuration tab and choose how the device is attached.", string.format("%s[%d]", luup.devices[PlugIn.THIS_DEVICE].description, PlugIn.THIS_DEVICE)
		else
			log("Opening serial port")
		end
	end

	-- Make sure icons are accessible when they should be. 
	check_images(PluginImages)
	-- Read settings.
	PlugIn.ShowMultiTariff = tonumber(defVar("ShowMultiTariff",0)) -- When 1 show T1 and T2 separately
	PlugIn.ShowExport = tonumber(defVar("ShowExport",0)) -- When 1 show Import and Export separately
	PlugIn.ShowLines = tonumber(defVar("ShowLines",0)) -- When 1 show Import / Export phase Lines
	PlugIn.UseGeneratedPower = tonumber(defVar("UseGeneratedPower",0)) -- When 1 use power generated (e.g. solar) in calculations
	if (PlugIn.ShowExport == 1) then
		if (PlugIn.UseGeneratedPower == 1) then
			PlugIn.GeneratedPowerSource = defVar("GeneratedPowerSource")
			PlugIn.GeneratorInterval = tonumber(defVar("GeneratorInterval", 0))
		else
			PlugIn.GeneratorInterval = 0
		end
	else
		PlugIn.UseGeneratedPower = 0
		PlugIn.GeneratorInterval = 0
	end
	PlugIn.ShowGas = tonumber(defVar("ShowGas",0)) -- When 1 show Import and Export separately
	-- Set some of the default options we want to read
	mapperRow(Mt, "MeterType", PlugIn.SM_SID, SetMeter)
	mapperRow(DSMRver, "DSMRVersion", PlugIn.SM_SID, SetVersion)
	mapperRow(Ta, "ActiveTariff", PlugIn.SM_SID, SetTariff)
	mapperRow(EqID, "MeterNumber", PlugIn.SM_SID, SetMeterNum)
	mapperRowChild(WholeHouse, "KWH", PlugIn.EM_SID, 0, nil, 1, "House", "House", PlugIn.PM_XML)
	mapperRowChild(ImpT1, "KWH", PlugIn.EM_SID, -1, SetKWH, 1, "ImportT1", "ImportT1", PlugIn.PM_XML)
	mapperRowChild(ImpT2, "KWH", PlugIn.EM_SID, -1, SetKWH, 1, "ImportT2", "ImportT2", PlugIn.PM_XML)
	if (PlugIn.UseGeneratedPower == 0) then
		mapperRow(ImpWatts, "Watts", PlugIn.EM_SID, SetWatts)
	else	
		mapperRow(ImpWatts, "Watts", PlugIn.EM_SID, SetWattsGen)
	end	
	mapperRowChild(L1ImpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, 1, "Line 1", "L1ImpWatts", PlugIn.PM_XML)
	mapperRowChild(L2ImpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, 1, "Line 2", "L2ImpWatts", PlugIn.PM_XML)
	mapperRowChild(L3ImpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, 1, "Line 3", "L3ImpWatts", PlugIn.PM_XML)
	mapperRow(L1Volt, "L1Volt", PlugIn.SM_SID, SetLineVolt)
	mapperRow(L2Volt, "L2Volt", PlugIn.SM_SID, SetLineVolt)
	mapperRow(L3Volt, "L3Volt", PlugIn.SM_SID, SetLineVolt)
	mapperRow(L1Amp, "L1Ampere", PlugIn.SM_SID, SetLineAmp)
	mapperRow(L2Amp, "L2Ampere", PlugIn.SM_SID, SetLineAmp)
	mapperRow(L3Amp, "L3Ampere", PlugIn.SM_SID, SetLineAmp)
	if (PlugIn.ShowExport == 1) then
		mapperRowChild(ExpT1, "KWH", PlugIn.EM_SID, -1, SetKWH, -1, "ExportT1", "ExportT1", PlugIn.PM_XML)
		mapperRowChild(ExpT2, "KWH", PlugIn.EM_SID, -1, SetKWH, -1, "ExportT2", "ExportT2", PlugIn.PM_XML)
		if (PlugIn.UseGeneratedPower == 0) then
			mapperRow(ExpWatts, "Watts", PlugIn.EM_SID, SetWatts, -1)
		else	
			mapperRow(ExpWatts, "Watts", PlugIn.EM_SID, SetWattsGen, -1)
		end	
		mapperRowChild(L1ExpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, -1, "", "L1ExpWatts", PlugIn.PM_XML)
		mapperRowChild(L2ExpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, -1, "", "L2ExpWatts", PlugIn.PM_XML)
		mapperRowChild(L3ExpWatts, "Watts", PlugIn.EM_SID, 0, SetLineWatts, -1, "", "L3ExpWatts", PlugIn.PM_XML)
	end	
	if (PlugIn.ShowGas == 1) then 
		mapperRowChild(Gas, "GasMeter", PlugIn.GE_SID, 0, SetGas, 1, "ImportGas", "ImportGas", PlugIn.GE_XML)
		mapperRow(Gas2, "", PlugIn.GE_SID, SetGas2)
		mapperRow(GEqID, "GasMeterNumber", PlugIn.SM_SID, SetMeterNum)
	end

	-- Setup child device and mapping details.
	mapperData[Ta].val = defVar("ActiveTariff",1)
	mapperData[Mt].val = defVar("MeterType", "Unknown")
	PlugIn.GeneratorPrevLen = defVar("GeneratorOffset",0)
	if (PlugIn.ShowMultiTariff == 0 and PlugIn.ShowExport == 1) then 
		-- Tweak child descriptions if no multi tariff
		mapperData[ImpT1].desc = "Import"
		mapperData[ExpT1].desc = "Export"
	end
	-- set up logging to syslog	
	if (syslogInfo ~= '') then
		log('Starting UDP syslog service...',7) 
		local err
		local syslogTag = luup.devices[PlugIn.THIS_DEVICE].description or PlugIn.DESCRIPTION 
		PlugIn.syslog, err = syslog_server (syslogInfo, syslogTag)
		if (not PlugIn.syslog) then log('UDP syslog service error: '..err,2) end
	end

	-- Create the child devices the user wants
	local childDevices = luup.chdev.start(PlugIn.THIS_DEVICE);  
	
    -- Create devices needed if not exist
	addMeterDevice(childDevices, WholeHouse)
	if (PlugIn.ShowMultiTariff == 1 or PlugIn.ShowExport == 1) then addMeterDevice(childDevices,ImpT1) end
	if (PlugIn.ShowMultiTariff == 1) then addMeterDevice(childDevices, ImpT2) end
	if (PlugIn.ShowExport == 1) then
		addMeterDevice(childDevices, ExpT1)
		if (PlugIn.ShowMultiTariff == 1) then addMeterDevice(childDevices, ExpT2) end
	end	
	if (PlugIn.ShowGas == 1) then addMeterDevice(childDevices, Gas) end
	if (PlugIn.ShowLines == 1) then
		addMeterDevice(childDevices, L1ImpWatts)
		addMeterDevice(childDevices, L2ImpWatts)
		addMeterDevice(childDevices, L3ImpWatts)
	end	
	-- Vera will reload here when there are new devices or changes to a child
	luup.chdev.sync(PlugIn.THIS_DEVICE, childDevices)

	-- When disabled, we are done here.
	if (PlugIn.Disabled == true) then
		return true, "Plug-in Disabled.", PlugIn.DESCRIPTION
	end	

	mapperData[Mt].dev = PlugIn.THIS_DEVICE
	mapperData[Ta].dev = PlugIn.THIS_DEVICE
	-- Pickup device IDs from names
	findChild(WholeHouse)
	mapperData[WholeHouse].rtlog = LogGet(mapperData[WholeHouse])
	if (PlugIn.ShowMultiTariff == 1 or PlugIn.ShowExport == 1) then findChild(ImpT1) end
	if (PlugIn.ShowMultiTariff == 1) then 
		findChild(ImpT2) 
	else
		mapperData[ImpT2].dev = mapperData[ImpT1].dev
	end
	if (PlugIn.ShowExport == 1) then
		findChild(ExpT1)
		if (PlugIn.ShowMultiTariff == 1) then 
			findChild(ExpT2) 
		else
			mapperData[ExpT2].dev = mapperData[ExpT1].dev
		end
	end	
	if (PlugIn.ShowGas == 1) then 
		findChild(Gas)
		mapperData[Gas].rtlog = LogGet(mapperData[Gas])
	end
	if (PlugIn.ShowLines == 1) then
		findChild(L1ImpWatts)
		findChild(L2ImpWatts)
		findChild(L3ImpWatts)
		if (PlugIn.ShowExport == 1) then 
			mapperData[L1ExpWatts].dev = mapperData[L1ImpWatts].dev
			mapperData[L2ExpWatts].dev = mapperData[L2ImpWatts].dev
			mapperData[L3ExpWatts].dev = mapperData[L3ImpWatts].dev
		end
	end	
	-- For current watt readings map to right device ID
	if (PlugIn.ShowMultiTariff == 1) then 
		if (mapperData[Ta].val == 1) then 
			mapperData[ImpWatts].dev = mapperData[ImpT1].dev
			if (PlugIn.ShowExport == 1) then mapperData[ExpWatts].dev = mapperData[ExpT1].dev end
		else
			mapperData[ImpWatts].dev = mapperData[ImpT2].dev
			if (PlugIn.ShowExport == 1) then mapperData[ExpWatts].dev = mapperData[ExpT2].dev end
		end
	else	
		mapperData[ImpWatts].dev = mapperData[ImpT1].dev
		if (PlugIn.ShowExport == 1) then mapperData[ExpWatts].dev = mapperData[ExpT1].dev end
	end
	PlugIn.GeneratorPrevLen = tonumber(defVar("GeneratorSampleDelay",0)) / 10
	if (PlugIn.GeneratorPrevLen > 0) then
		for i = 1, PlugIn.GeneratorPrevLen do
			GeneratorPrev[i] = 0
		end
	end	
	-- Set functions/variables to Global space if the need to be
	_G.mapperData = mapperData
	luup.call_delay("finishSetup", 30)
	luup.call_delay("SmartMeter_registerWithAltUI", 40, "", false)
	log("SmartMeter has started...")
	setluupfailure(0, PlugIn.THIS_DEVICE)
	return true
end

---------------------------------------------------------------------------------------------
-- Data line has been received via serial. Process when ready
---------------------------------------------------------------------------------------------
function SmartMeter_Incoming(data)
    if (luup.is_ready(lul_device) == false or PlugIn.Disabled == true or PlugIn.StartingUp == true) then
        return
    end
	
	if (data:len() > 0) then
		if (PlugIn.indGasComming) then
			-- GAS on DSMR 2.x and 3.0 where GAS reading is on its own line after key line 0-1:24.3.0.
			local elem = mapperData[Gas]
			SetGas3(elem,data)
			PlugIn.indGasComming = false
		else
			-- Get line key
			local Key = data:match("[0-9%:%-%.%/]+")
			if Key then
				local elem = mapperData[Key]
				if elem then
					-- Call Set function
					local res, val = pcall(mapperData[Key].func, elem, data:sub(Key:len()+1))
					if res then
						log("Found key : "..Key.." for "..elem.var.." to set to value "..(val or 'nil'))
					else
						log("Found key : "..Key.." for "..elem.var.." but failed to obtain value from " .. data:sub(Key:len()+1),2)
						log("Err MSG: "..(val or 'nil'),2)
					end
				else	
					log("Not processing : "..(data or 'nil'))
				end
			else
				log("No key found in : "..(data or 'nil'))
			end
		end	
	end	
end
