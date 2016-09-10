//# sourceURL=J_SmartMeter.js
// SmartMeter control UI for UI5/6
// Written by R.Boer. 
// V1.7 17 March 2016
//
// V1.7 Changes:
//		User can disable plugin. Signal status on control panel.

// Constants. Keep in sync with LUA code.
var SM_SID = 'urn:rboer-com:serviceId:SmartMeter1';
var ERR_MSG = "Error : ";

// Return HTML for settings tab
function SmartMeterSettings(deviceID) {
	var deviceObj = get_device_obj(deviceID);
	var devicePos = get_device_index(deviceID);
	var deviceList = jsonp.ud.devices;
	var yesNo = [{'value':'0','label':'No'},{'value':'1','label':'Yes'}];
	var logLevel = [{'value':'1','label':'Error'},{'value':'2','label':'Warning'},{'value':'8','label':'Info'},{'value':'10','label':'Debug'}];
	var genIntervals = [{'value':'0','label':'Real-time'},{'value':'30','label':'30 seconds'},{'value':'60','label':'1 Minute'},{'value':'120','label':'2 minutes'},{'value':'180','label':'3 minutes'},{'value':'240','label':'4 minutes'},{'value':'300','label':'5 minutes'},{'value':'360','label':'6 minutes'},{'value':'420','label':'7 minutes'},{'value':'480','label':'8 minutes'},{'value':'540','label':'9 minutes'},{'value':'600','label':'10 minutes'}];
	var genOffsets = [{'value':'0','label':'None'},{'value':'1','label':'10 seconds'},{'value':'2','label':'20 seconds'},{'value':'3','label':'30 seconds'},{'value':'4','label':'40 seconds'},{'value':'5','label':'50 seconds'},{'value':'6','label':'60 seconds'}];
	var powerMeters = [];
	for (i=0; i<deviceList.length; i++) {
		// include PowerMeter devices except from our own
		if ((deviceList[i].category_num == 21) && (deviceList[i].id_parent != deviceID)) {
			powerMeters.push({ 'value':deviceList[i].id,'label':deviceList[i].name });
		}
		// Include standard BinaryLights as that includes a Watts value
		if ((deviceList[i].category_num == 3) && (deviceList[i].device_type == 'urn:schemas-upnp-org:device:BinaryLight:1')) {
			powerMeters.push({ 'value':deviceList[i].id,'label':deviceList[i].name });
		}
	}
    var html = '<table border="0" cellpadding="0" cellspacing="3" width="100%"><tbody>'+
		'<tr><td colspan="2"><b>Device #'+deviceID+'</b>&nbsp;&nbsp;&nbsp;'+((deviceObj.name)?deviceObj.name:'')+'</td></tr>';
	if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
		html += '<tr><td colspan="2">&nbsp;</td></tr><tr><td colspan="2"><br>Plugin is disabled in Attributes.</td></tr>';
	} else {	
		html += smhtmlAddPulldown(deviceID, 'Show High and Low Tariff meters', 'ShowMultiTariff', yesNo, true)+
		smhtmlAddPulldown(deviceID, 'Show Line 1-3 meters', 'ShowLines', yesNo, true)+
		smhtmlAddPulldown(deviceID, 'Show Export meter(s)', 'ShowExport', yesNo, true);
		if (powerMeters.length > 0) {
			html += smhtmlAddPulldown(deviceID, 'Include Power Generator', 'UseGeneratedPower', yesNo, true)+
			smhtmlAddPulldown(deviceID, 'Power Generator device', 'GeneratedPowerSource', powerMeters, true)+
			smhtmlAddPulldown(deviceID, 'Power Generator Update interval', 'GeneratorInterval', genIntervals, true)+
			smhtmlAddPulldown(deviceID, 'Power Generator Update offset', 'GeneratorOffset', genOffsets, true);
		}	
		html += smhtmlAddPulldown(deviceID, 'Show Gas meter', 'ShowGas', yesNo, true)+
		smhtmlAddPulldown(deviceID, 'Log level', 'LogLevel', logLevel, true)+
		smhtmlAddInput(deviceID, 'Syslog server IP Address:Port', 30, 'Syslog');
	}	
	html += '</tbody></table>';
    set_panel_html(html);
}


// Update variable, check for limits on applicable ones
function smVariable_set(deviceID, varID, newValue) {
	smVarSet(deviceID, varID, newValue);
}	

function smVarSet(deviceID, varID, newValue, sid) {
	if (typeof(sid) == 'undefined') { sid = SM_SID; }
	set_device_state(deviceID,  sid, varID, newValue, 0);	// Save in user_data so it is there after luup reload
	set_device_state(deviceID,  sid, varID, newValue, 1); // Save in lu_status so it is directly available for others.
}

function smVarGet(deviceID, varID, sid) {
	if (typeof(sid) == 'undefined') { sid = SM_SID; }
	var res = get_device_state(deviceID,sid,varID);
	res = (res == null) ? '' : res;
	return res;
}

// Standard update for  plug-in pull down variable. We can handle multiple selections.
function smhtmlGetPulldownSelection(di, vr) {
	var value = [];
	var s = document.getElementById('smID_'+vr+di);
	for (var i = 0; i < s.options.length; i++) {
		if (s.options[i].selected === true) {
			value.push(s.options[i].value);
		}
	}
	return value.join();
}

// Add a label and pulldown selection
function smhtmlAddPulldown(di, lb, vr, values, onchange) {
	var extra = '';
	onchange = (onchange === null) ? false : onchange;
	var selVal = smVarGet(di, vr);
	if (onchange === true) {
		extra ='onChange="smUpdatePulldown('+di+',\''+vr+'\',this.value)" ';
	}
	var html = '<tr><td>'+lb+'</td><td>'+
		'<select id="smID_'+vr+di+'" '+extra+'class="styled">';
	for(var i=0;i<values.length;i++){
		html += '<option value="'+values[i].value+'" '+((values[i].value==selVal)?'selected':'')+'>'+values[i].label+'</option>';
	}
	html += '</select></td></tr>';
	return html;
}
function smUpdatePulldown(di, vr) {
	var value = [];
	var s = document.getElementById('smID_'+vr+di);
	for (var i = 0; i < s.options.length; i++) {
		if (s.options[i].selected === true) {
			value.push(s.options[i].value);
		}
	}
	smVarSet(di, vr, value.join());
}

function smhtmlAddInput(di, lb, si, vr, sid) {
	val = (typeof df != 'undefined') ? df : smVarGet(di,vr,sid);
	var html = '<tr><td>'+lb+'</td><td><input type="text" size="'+si+'" id="smID_'+vr+di+'" value="'+val+'" '+
		'onchange="smVariable_set('+di+',\''+vr+'\' , this.value);"></td></tr>';
	return html;
}
