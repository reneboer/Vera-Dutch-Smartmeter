//# sourceURL=J_SmartMeter_UI7.js
// SmartMeter control UI for UI7
// Written by R.Boer. 
// V1.13 17 November 2018
//
// V1.13 Changes:
//		Fix for saving settings on ALTUI.
//
// V1.12 Changes:
//		Can reduce number of updates to reduce CPU load on Vera.
//		Nicer looking on ALTUI
//		Allow for less frequent Generator updates (15 & 30 minutes). Enphase has changed to 15 on local API.
//
// V1.7 Changes:
//		User can disable plugin. Signal status on control panel.

var SmartMeter = (function (api) {

	// Constants. Keep in sync with LUA code.
    var uuid = '12021512-0000-a0a0-b0b0-c0c030303032';
	var SM_SID = 'urn:rboer-com:serviceId:SmartMeter1';
	var ERR_MSG = "Error : ";
	var DIV_PREFIX = "rbSM_";		// Used in HTML div IDs to make them unique for this module
	var MOD_PREFIX = "SmartMeter";  // Must match module name above
	var bOnALTUI = false;

	// Forward declaration.
    var myModule = {};

    function onBeforeCpanelClose(args) {
		showBusy(false);
        // do some cleanup...
        console.log(MOD_PREFIX+', handler for before cpanel close');
    }

    function init() {
        // register to events...
        api.registerEventHandler('on_ui_cpanel_before_close', myModule, 'onBeforeCpanelClose');
		if (typeof ALTUI_revision=="string") {
			bOnALTUI = true;
		}
    }
	
	// Return HTML for settings tab
	function Settings() {
		init();
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var deviceList = api.getListOfDevices();
			var yesNo = [{'value':'0','label':'No'},{'value':'1','label':'Yes'}];
			var logLevel = [{'value':'1','label':'Error'},{'value':'2','label':'Warning'},{'value':'8','label':'Info'},{'value':'11','label':'Debug'}];
			var updateFreq = [{'value':'0','label':'Instant'},{'value':'10','label':'10 Seconds'},{'value':'30','label':'30 Seconds'},{'value':'60','label':'60 Seconds'},{'value':'300','label':'5 Minutes'}];
			var genIntervals = [{'value':'0','label':'Real-time'},{'value':'30','label':'30 seconds'},{'value':'60','label':'1 Minute'},{'value':'120','label':'2 minutes'},{'value':'180','label':'3 minutes'},{'value':'240','label':'4 minutes'},{'value':'300','label':'5 minutes'},{'value':'360','label':'6 minutes'},{'value':'420','label':'7 minutes'},{'value':'480','label':'8 minutes'},{'value':'540','label':'9 minutes'},{'value':'600','label':'10 minutes'},{'value':'900','label':'15 minutes'},{'value':'1800','label':'30 minutes'}];
			var genOffsets = [{'value':'0','label':'None'},{'value':'1','label':'10 seconds'},{'value':'2','label':'20 seconds'},{'value':'3','label':'30 seconds'},{'value':'4','label':'40 seconds'},{'value':'5','label':'50 seconds'},{'value':'6','label':'60 seconds'}];
			var powerMeters = [];
			var showExport = varGet(deviceID, 'ShowExport');
			var showGen = varGet(deviceID, 'UseGeneratedPower');
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
			// If there are no power metering devices, don't show the option.
			if (powerMeters.length === 0) { showExport = 0; }
			var html = '<div class="deviceCpanelSettingsPage">'+
				'<h3>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'</h3>';
			if (deviceObj.disabled == 1) {
				html += '<br>Plugin is disabled in Attributes.</div>';
			} else {	
				html += htmlAddPulldown(deviceID, 'Show High and Low Tariff meters', 'ShowMultiTariff', yesNo)+
				htmlAddPulldown(deviceID, 'Show Line 1-3 meters', 'ShowLines', yesNo)+
				htmlAddPulldown(deviceID, 'Show Export meter(s)', 'ShowExport', yesNo)+
				'<div id="'+DIV_PREFIX+deviceID+'_exp_div" style="display: '+((showExport === '1')?'block':'none')+';" >'+
				htmlAddPulldown(deviceID, 'Include Power Generator', 'UseGeneratedPower', yesNo)+
				'<div id="'+DIV_PREFIX+deviceID+'_gen_div" style="display: '+((showGen === '1')?'block':'none')+';" >'+
				htmlAddPulldown(deviceID, 'Power Generator device', 'GeneratedPowerSource', powerMeters)+
				htmlAddPulldown(deviceID, 'Power Generator Update interval', 'GeneratorInterval', genIntervals)+
				htmlAddPulldown(deviceID, 'Power Generator Update offset', 'GeneratorOffset', genOffsets)+
				'</div></div>'+
				htmlAddPulldown(deviceID, 'Show Gas meter', 'ShowGas', yesNo)+
				htmlAddPulldown(deviceID, 'Log level', 'LogLevel', logLevel)+
				htmlAddPulldown(deviceID, 'Update Frequency', 'UpdateFrequency', updateFreq)+
				htmlAddInput(deviceID, 'Syslog server IP Address:Port', 30, 'Syslog') + 
				htmlAddButton(deviceID, 'UpdateSettings')+
				'</div>'+
				'<script>'+
				' $("#'+DIV_PREFIX+'ShowExport'+deviceID+'").change(function() {'+
				' (($(this).val() == 1) ? $("#'+DIV_PREFIX+deviceID+'_exp_div").fadeIn() : $("#'+DIV_PREFIX+deviceID+'_exp_div").fadeOut()); } );'+
				' $("#'+DIV_PREFIX+'UseGeneratedPower'+deviceID+'").change(function() {'+
				' (($(this).val() == 1) ? $("#'+DIV_PREFIX+deviceID+'_gen_div").fadeIn() : $("#'+DIV_PREFIX+deviceID+'_gen_div").fadeOut()); } );'+
				'</script>';
			}
			api.setCpanelContent(html);
        } catch (e) {
            Utils.logError('Error in '+MOD_PREFIX+'.Settings(): ' + e);
        }
	}

	// Update variable in user_data and lu_status
	function varSet(deviceID, varID, varVal, sid) {
		if (typeof(sid) == 'undefined') { sid = SM_SID; }
		api.setDeviceStateVariablePersistent(deviceID, sid, varID, varVal);
	}
	// Get variable value. When variable is not defined, this new api returns false not null.
	function varGet(deviceID, varID, sid) {
		try {
			if (typeof(sid) == 'undefined') { sid = SM_SID; }
			var res = api.getDeviceState(deviceID, sid, varID);
			if (res !== false && res !== null && res !== 'null' && typeof(res) !== 'undefined') {
				return res;
			} else {
				return '';
			}	
        } catch (e) {
            return '';
        }
	}
	function UpdateSettings(deviceID) {
		// Save variable values so we can access them in LUA without user needing to save
		showBusy(true);
		varSet(deviceID,'ShowMultiTariff',htmlGetPulldownSelection(deviceID, 'ShowMultiTariff'));
		varSet(deviceID,'ShowLines',htmlGetPulldownSelection(deviceID, 'ShowLines'));
		varSet(deviceID,'ShowExport',htmlGetPulldownSelection(deviceID, 'ShowExport'));
		varSet(deviceID,'UseGeneratedPower',htmlGetPulldownSelection(deviceID, 'UseGeneratedPower'));
		varSet(deviceID,'GeneratedPowerSource',htmlGetPulldownSelection(deviceID, 'GeneratedPowerSource'));
		varSet(deviceID,'GeneratorInterval',htmlGetPulldownSelection(deviceID, 'GeneratorInterval'));
		varSet(deviceID,'GeneratorOffset',htmlGetPulldownSelection(deviceID, 'GeneratorOffset'));
		varSet(deviceID,'ShowGas',htmlGetPulldownSelection(deviceID, 'ShowGas'));
		varSet(deviceID,'UpdateFrequency',htmlGetPulldownSelection(deviceID, 'UpdateFrequency'));
		varSet(deviceID,'LogLevel',htmlGetPulldownSelection(deviceID, 'LogLevel'));
		varSet(deviceID,'Syslog',htmlGetElemVal(deviceID, 'Syslog'));
		application.sendCommandSaveUserData(true);
		setTimeout(function() {
			doReload(deviceID);
			showBusy(false);
			try {
				api.ui.showMessagePopup(Utils.getLangString("ui7_device_cpanel_details_saved_success","Device details saved successfully."),0);
			}
			catch (e) {
				Utils.logError(MOD_PREFIX+': UpdateSettings(): ' + e);
			}
		}, 3000);	
	}
	// Standard update for plug-in pull down variable. We can handle multiple selections.
	function htmlGetPulldownSelection(di, vr) {
		var value = $('#'+DIV_PREFIX+vr+di).val() || [];
		return (typeof value === 'object')?value.join():value;
	}
	// Get the value of an HTML input field
	function htmlGetElemVal(di,elID) {
		var res;
		try {
			res=$('#'+DIV_PREFIX+elID+di).val();
		}
		catch (e) {	
			res = '';
		}
		return res;
	}
	// Add a label and pulldown selection
	function htmlAddPulldown(di, lb, vr, values) {
		try {
			var selVal = varGet(di, vr);
			var html = '<div id="'+DIV_PREFIX+vr+di+'_div" class="clearfix labelInputContainer">'+
				'<div class="pull-left inputLabel '+((bOnALTUI) ? 'form-control form-control-sm form-control-plaintext' : '')+'" style="width:280px;">'+lb+'</div>'+
				'<div class="pull-left customSelectBoxContainer">'+
				'<select id="'+DIV_PREFIX+vr+di+'" class="customSelectBox '+((bOnALTUI) ? 'form-control form-control-sm' : '')+'">';
			for(var i=0;i<values.length;i++){
				html += '<option value="'+values[i].value+'" '+((values[i].value==selVal)?'selected':'')+'>'+values[i].label+'</option>';
			}
			html += '</select>'+
				'</div>'+
				'</div>';
			return html;
		} catch (e) {
			Utils.logError(MOD_PREFIX+': htmlAddPulldown(): ' + e);
			return '';
		}
	}
	// Add a standard input for a plug-in variable.
	function htmlAddInput(di, lb, si, vr, sid, df) {
		var val = (typeof df != 'undefined') ? df : varGet(di,vr,sid);
		var html = '<div id="'+DIV_PREFIX+vr+di+'_div" class="clearfix labelInputContainer" >'+
					'<div class="pull-left inputLabel '+((bOnALTUI) ? 'form-control form-control-sm form-control-plaintext' : '')+'" style="width:280px;">'+lb+'</div>'+
					'<div class="pull-left">'+
						'<input class="customInput '+((bOnALTUI) ? 'altui-ui-input form-control form-control-sm' : '')+'" size="'+si+'" id="'+DIV_PREFIX+vr+di+'" type="text" value="'+val+'">'+
					'</div>'+
				'</div>';
		return html;
	}
	// Add a Save Settings button
	function htmlAddButton(di, cb) {
		html = '<div class="cpanelSaveBtnContainer labelInputContainer clearfix">'+	
			'<input class="vBtn pull-right btn" type="button" value="Save Changes" onclick="'+MOD_PREFIX+'.'+cb+'(\''+di+'\');"></input>'+
			'</div>';
		return html;
	}

	// Show/hide the interface busy indication.
	function showBusy(busy) {
		if (busy === true) {
			try {
					api.ui.showStartupModalLoading(); // version v1.7.437 and up
				} catch (e) {
					api.ui.startupShowModalLoading(); // Prior versions.
				}
		} else {
			api.ui.hideModalLoading(true);
		}
	}
	function doReload(deviceID) {
		api.performLuActionOnDevice(0, "urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {});
	}

	// Expose interface functions
    myModule = {
		// Internal for panels
        uuid: uuid,
        init: init,
        onBeforeCpanelClose: onBeforeCpanelClose,
		UpdateSettings: UpdateSettings,

		// For JSON calls
        Settings: Settings,
    };
    return myModule;
})(api);

