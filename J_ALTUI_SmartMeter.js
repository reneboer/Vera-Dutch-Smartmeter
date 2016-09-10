//# sourceURL=J_ALTUI_SmartMeter.js

var ALTUI_SmartMeterDisplays = ( function( window, undefined ) {  
	
	// Constants. Keep in sync with LUA code.
	SM_SID = "urn:rboer-com:serviceId:SmartMeter1";
	GE_SID = "urn:rboer-com:serviceId:SmartMeterGAS1";

	//---------------------------------------------------------
	// PRIVATE functions
	//---------------------------------------------------------
	
	// return the html string inside the .panel-body of the .altui-device#id panel
	function _drawSmartMeter(device) {
		var html = "";
		var meterTemplate = "<div class='text-muted' style='font-size:11px'><br>Meter Type : {0}";		
		var meter = MultiBox.getStatus(device, SM_SID, 'MeterType'); 
		html += meterTemplate.format(meter);
		var tariffTemplate = "<br>Active Tariff: {0} (1=low, 2=high)</div>";		
		var tariff = MultiBox.getStatus(device, SM_SID, 'ActiveTariff'); 
		html += tariffTemplate.format(tariff);
		return html;
	};
	
	
	// return the html string inside the .panel-body of the .altui-device#id panel
	function _drawSmartMeterGas(device) {
		var html = "";
		var gasTemplate = "<div class='altui-watts '>{0} <small>l/h</small></div>";		
		var watts = parseFloat(MultiBox.getStatus(device, GE_SID, 'Flow')); 
		if (isNaN(watts)==false) 
			html += gasTemplate.format(watts);
		return html;
	};

	
  // explicitly return public methods when this object is instantiated
  return {
	//---------------------------------------------------------
	// PUBLIC  functions
	//---------------------------------------------------------
	drawSmartMeter       : _drawSmartMeter,
	drawSmartMeterGas    : _drawSmartMeterGas
  };
})( window );
	