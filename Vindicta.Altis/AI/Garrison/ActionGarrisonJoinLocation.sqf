#include "common.hpp"

/*
All crew of vehicles mounts assigned vehicles.
*/

#define pr private

// Duration of this action

CLASS("ActionGarrisonJoinLocation", "ActionGarrison")

	VARIABLE("loc");
	VARIABLE("locPos");

	// ------------ N E W ------------
	
	METHOD("new") {
		params [["_thisObject", "", [""]], ["_AI", "", [""]], ["_parameters", [], [[]]] ];
		
		pr _loc = CALLSM2("Action", "getParameterValue", _parameters, TAG_LOCATION);
		pr _locPos = CALLM0(_loc, "getPos");
		T_SETV("locPos", _locPos);
		
	} ENDMETHOD;
	
	// logic to run when the goal is activated
	METHOD("activate") {
		params [["_thisObject", "", [""]]];		
		
		pr _locPos = T_GETV("locPos");
		pr _gar = T_GETV("gar");
		CALLSM1("Location", "getNearestLocation", _locPos) params ["_loc", "_dist"];
		
		if (_dist < 0.5) then {
			pr _side = CALLM0(_gar, "getSide");
			pr _locGars = CALLM(_loc, "getGarrisons", [_side]);
			if (count _locGars > 0) then {
				// All's good, need to merge two garrisons now
				pr _args = [_gar]; // true will delete this garrison
				CALLM2(_locGars select 0, "postMethodAsync", "addGarrison", _args); // The other garrison can be on another computer
			} else {
				// There is no friendly garrison here, just attach here then
				CALLM1(_gar, "setLocation", _loc);
			};
			ACTION_STATE_COMPLETED
		} else {
			OOP_ERROR_1("There is no location at %1!", _locPos);
			// There is no location here any more, wtf
			ACTION_STATE_FAILED
		};
		

		
	} ENDMETHOD;
	
	// logic to run each update-step
	METHOD("process") {
		params [["_thisObject", "", [""]]];
		
		pr _state = CALLM0(_thisObject, "activateIfInactive");

		// Return the current state
		T_SETV("state", _state);
		_state
	} ENDMETHOD;
	
	// logic to run when the action is satisfied
	METHOD("terminate") {
		params [["_thisObject", "", [""]]];
		
	} ENDMETHOD; 
	
	
	
	// procedural preconditions
	// POS world state property comes from action parameters
	
	STATIC_METHOD("getPreconditions") {
		params [ ["_thisClass", "", [""]], ["_goalParameters", [], [[]]], ["_actionParameters", [], [[]]]];
		
		pr _loc = CALLSM2("Action", "getParameterValue", _actionParameters, TAG_LOCATION);
		pr _pos = CALLM0(_loc, "getPos");
		pr _ws = [WSP_GAR_COUNT] call ws_new;
		[_ws, WSP_GAR_POSITION, _pos] call ws_setPropertyValue;
		
		_ws
	} ENDMETHOD;

ENDCLASS;