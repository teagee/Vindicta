#include "common.hpp"

/*
Class: AI.CmdrAI.CmdrAction.Actions.TakeOrJoinCmdrAction

Base class for Take and Join like CmdrAI actions.
Takes a source garrison id, from which a detachment can be formed to perform the action.
See implementations in TakeLocationCmdrAction and ReinforceCmdrAction.

Parent: <CmdrAction>
*/
CLASS("TakeOrJoinCmdrAction", "CmdrAction")
	VARIABLE("srcGarrId");
	VARIABLE("targetVar");
	VARIABLE("detachmentEffVar");	// Efficiency
	VARIABLE("detachmentCompVar");	// Composition
	VARIABLE("detachedGarrIdVar");
	VARIABLE("startDateVar");

#ifdef DEBUG_CMDRAI
	VARIABLE("debugColor");
	VARIABLE("debugSymbol");
#endif

	/*
	Constructor: new
	
	Create a TakeOrJoinCmdrAction. See derived classes for details.
	
	Parameters:
		_srcGarrId - Number, <Model.GarrisonModel> id from which to send the detachment performing the action.
	*/
	METHOD("new") {
		params [P_THISOBJECT, P_NUMBER("_srcGarrId")];

		T_SETV("srcGarrId", _srcGarrId);

		// Start date for this action, default to immediate
		private _startDateVar = T_CALLM1("createVariable", DATE_NOW);
		T_SETV("startDateVar", _startDateVar);

		// Desired detachment efficiency changes when updateScore is called. This shouldn't happen once the action
		// has been started, but this constructor is called before that point.
		private _detachmentEffVar = T_CALLM1("createVariable", EFF_ZERO);
		T_SETV("detachmentEffVar", _detachmentEffVar);
		private _detachmentCompVar = T_CALLM1("createVariable", +T_comp_null);
		T_SETV("detachmentCompVar", _detachmentCompVar);

		// Target can be modified during the action, if the initial target dies, so we want it to save/restore.
		private _targetVar = T_CALLM("createVariable", [[]]);
		T_SETV("targetVar", _targetVar);
	} ENDMETHOD;

	METHOD("delete") {
		params [P_THISOBJECT];

		{ DELETE(_x) } forEach T_GETV("transitions");

#ifdef DEBUG_CMDRAI
		deleteMarker (_thisObject + "_line");
		//deleteMarker (_thisObject + "_line2");
		deleteMarker (_thisObject + "_label");
#endif
	} ENDMETHOD;

	/* protected override */ METHOD("createTransitions") {
		params [P_THISOBJECT];

		T_PRVAR(srcGarrId);
		T_PRVAR(detachmentEffVar);
		T_PRVAR(detachmentCompVar);
		T_PRVAR(targetVar);
		T_PRVAR(startDateVar);
		
		// Call MAKE_AST_VAR directly because we don't won't the CmdrAction to automatically push and pop this value 
		// (it is a constant for this action so it doesn't need to be saved and restored)
		private _srcGarrIdVar = T_CALLM1("createVariable", _srcGarrId);

		// Split garrison Id is set by the split AST, so we want it to be saved and restored when simulation is run
		// (so the real value isn't affected by simulation runs, see CmdrAction.applyToSim for details).
		private _splitGarrIdVar = T_CALLM("createVariable", [MODEL_HANDLE_INVALID]);
		T_SETV("detachedGarrIdVar", _splitGarrIdVar);

		private _splitAST_Args = [
				_thisObject,						// This action (for debugging context)
				[CMDR_ACTION_STATE_START], 			// First action we do
				CMDR_ACTION_STATE_SPLIT, 			// State change if successful
				CMDR_ACTION_STATE_END, 				// State change if failed (go straight to end of action)
				_srcGarrIdVar, 						// Garrison to split (constant)
				_detachmentCompVar,					// COmposition of detachment
				_detachmentEffVar, 					// Efficiency we want the detachment to have (constant)
				_splitGarrIdVar]; 					// variable to recieve Id of the garrison after it is split
		private _splitAST = NEW("AST_SplitGarrison", _splitAST_Args);

		private _assignAST_Args = [
				_thisObject, 						// This action, gets assigned to the garrison
				[CMDR_ACTION_STATE_SPLIT], 			// Do this after splitting
				CMDR_ACTION_STATE_ASSIGNED, 		// State change when successful (can't fail)
				_splitGarrIdVar]; 					// Id of garrison to assign the action to
		private _assignAST = NEW("AST_AssignActionToGarrison", _assignAST_Args);

		private _waitAST_Args = [
				_thisObject,						// This action (for debugging context)
				[CMDR_ACTION_STATE_ASSIGNED], 		// Start wait after we assigned the action to the detachment
				CMDR_ACTION_STATE_READY_TO_MOVE, 	// State change if successful2
				CMDR_ACTION_STATE_END, 				// State change if failed (go straight to end of action)
				_startDateVar,						// Date to wait until
				_splitGarrIdVar];					// Garrison to wait (checks it is still alive)
		private _waitAST = NEW("AST_WaitGarrison", _waitAST_Args);	

		T_GET_AST_VAR("targetVar") params ["_targetType", "_target"];

		private _moveAST = if(_targetType == TARGET_TYPE_GARRISON) then {
			// If we are merging to a garrison we will just move there and merge
			private _moveAST_Args = [
					_thisObject, 						// This action (for debugging context)
					[CMDR_ACTION_STATE_READY_TO_MOVE], 		
					CMDR_ACTION_STATE_MOVED, 			// State change when successful
					CMDR_ACTION_STATE_END,				// State change when garrison is dead (just terminate the action)
					CMDR_ACTION_STATE_TARGET_DEAD, 		// State change when target is dead
					_splitGarrIdVar, 					// Id of garrison to move
					_targetVar, 						// Target to move to (initially the target garrison)
					T_CALLM1("createVariable", 200)]; 				// Radius to move within
			NEW("AST_MoveGarrison", _moveAST_Args)
		} else {
			// If we are occupying a location we will attack and clear the area then occupy it (attack includes move)
			private _attackAST_Args = [
					_thisObject,
					[CMDR_ACTION_STATE_READY_TO_MOVE], 	// Once we are split and assigned the action we can go
					CMDR_ACTION_STATE_MOVED,			// State when we succeed, it leads to occupying the location
					CMDR_ACTION_STATE_END, 				// If we are dead then go to end
					CMDR_ACTION_STATE_MOVED,			// If we timeout then occupy the location
					_splitGarrIdVar, 					// Id of the garrison doing the attacking
					_targetVar, 						// Target to attack (cluster or garrison supported)
					T_CALLM1("createVariable", 500)];					// Move radius
			NEW("AST_GarrisonAttackTarget", _attackAST_Args)
		};

		private _mergeAST_Args = [
				_thisObject,
				[CMDR_ACTION_STATE_MOVED], 			// Merge once we reach the destination (whatever it is)
				CMDR_ACTION_STATE_END, 				// Once merged we are done
				CMDR_ACTION_STATE_END, 				// If the detachment is dead then we can just end the action
				CMDR_ACTION_STATE_TARGET_DEAD, 		// If the target is dead then reselect a new target
				_splitGarrIdVar, 					// Id of the garrison we are merging
				_targetVar]; 						// Target to merge to (garrison or location is valid)
		private _mergeAST = NEW("AST_MergeOrJoinTarget", _mergeAST_Args);

		private _newTargetAST_Args = [
				_thisObject,
				[CMDR_ACTION_STATE_TARGET_DEAD], 	// We select a new target when the old one is dead
				CMDR_ACTION_STATE_READY_TO_MOVE, 	// State change when successful
				_srcGarrIdVar, 						// Originating garrison (default we return to)
				_splitGarrIdVar, 					// Id of the garrison we are moving (for context)
				_targetVar]; 						// New target
		private _newTargetAST = NEW("AST_SelectFallbackTarget", _newTargetAST_Args);

		[_splitAST, _assignAST, _waitAST, _moveAST, _mergeAST, _newTargetAST]
	} ENDMETHOD;
	
	/* protected override */ METHOD("getLabel") {
		params [P_THISOBJECT, P_STRING("_world")];

		T_PRVAR(srcGarrId);
		T_PRVAR(state);
		private _srcGarr = CALLM(_world, "getGarrison", [_srcGarrId]);
		private _srcEff = GETV(_srcGarr, "efficiency");

		private _startDate = T_GET_AST_VAR("startDateVar");
		private _timeToStart = if(_startDate isEqualTo []) then {
			" (unknown)"
		} else {
			private _numDiff = (dateToNumber _startDate - dateToNumber DATE_NOW);
			if(_numDiff > 0) then {
				private _dateDiff = numberToDate [0, _numDiff];
				private _mins = _dateDiff#4 + _dateDiff#3*60;

				format [" (start in %1 mins)", _mins]
			} else {
				" (started)"
			}
		};

		private _targetName = [_world, T_GET_AST_VAR("targetVar")] call Target_fnc_GetLabel;
		private _detachedGarrId = T_GET_AST_VAR("detachedGarrIdVar");
		if(_detachedGarrId == MODEL_HANDLE_INVALID) then {
			format ["%1 %2%3 -> %4%5", _thisObject, LABEL(_srcGarr), _srcEff, _targetName, _timeToStart]
		} else {
			private _detachedGarr = CALLM(_world, "getGarrison", [_detachedGarrId]);
			private _detachedEff = GETV(_detachedGarr, "efficiency");
			format ["%1 %2%3 -> %4%5 -> %6%7", _thisObject, LABEL(_srcGarr), _srcEff, LABEL(_detachedGarr), _detachedEff, _targetName, _timeToStart]
		};
	} ENDMETHOD;

	METHOD("updateIntelFromDetachment") {
		params [P_THISOBJECT, P_OOP_OBJECT("_world"), P_OOP_OBJECT("_intel")];
		ASSERT_OBJECT_CLASS(_world, "WorldModel");
		//ASSERT_OBJECT_CLASS(_intel, "IntelCommanderActionAttack");
		
		// Update progress of the detachment
		private _detachedGarrId = T_GET_AST_VAR("detachedGarrIdVar");
		if(_detachedGarrId != MODEL_HANDLE_INVALID) then {
			private _detachedGarr = CALLM(_world, "getGarrison", [_detachedGarrId]);
			SETV(_intel, "garrison", GETV(_detachedGarr, "actual"));
			SETV(_intel, "pos", GETV(_detachedGarr, "pos"));
			SETV(_intel, "posCurrent", GETV(_detachedGarr, "pos"));
			SETV(_intel, "strength", GETV(_detachedGarr, "efficiency"));

			// Send intel to the garrison doing this action
			T_CALLM1("setPersonalGarrisonIntel", _detachedGarr);

			if (T_GETV("state") == CMDR_ACTION_STATE_READY_TO_MOVE) then {
				T_CALLM1("setIntelState", INTEL_ACTION_STATE_ACTIVE);
			};
		};
	} ENDMETHOD;
	
	/* protected override */ METHOD("debugDraw") {
		params [P_THISOBJECT, P_STRING("_world")];

		T_PRVAR(srcGarrId);
		private _srcGarr = CALLM(_world, "getGarrison", [_srcGarrId]);
		ASSERT_OBJECT(_srcGarr);
		private _srcGarrPos = GETV(_srcGarr, "pos");

		private _targetPos = [_world, T_GET_AST_VAR("targetVar")] call Target_fnc_GetPos;

		if(_targetPos isEqualType []) then {
			T_PRVAR(debugColor);
			T_PRVAR(debugSymbol);

			[_srcGarrPos, _targetPos, _debugColor, 8, _thisObject + "_line"] call misc_fnc_mapDrawLine;

			private _centerPos = _srcGarrPos vectorAdd ((_targetPos vectorDiff _srcGarrPos) apply { _x * 0.25 });
			private _mrk = _thisObject + "_label";
			createmarker [_mrk, _centerPos];
			_mrk setMarkerType _debugSymbol;
			_mrk setMarkerColor _debugColor;
			_mrk setMarkerPos _centerPos;
			_mrk setMarkerAlpha 1;
			_mrk setMarkerText T_CALLM("getLabel", [_world]);
		};

		// private _detachedGarrId = T_GET_AST_VAR("detachedGarrIdVar");
		// if(_detachedGarrId != MODEL_HANDLE_INVALID) then {
		// 	private _detachedGarr = CALLM(_world, "getGarrison", [_detachedGarrId]);
		// 	ASSERT_OBJECT(_detachedGarr);
		// 	private _detachedGarrPos = GETV(_detachedGarr, "pos");
		// 	[_detachedGarrPos, _centerPos, "ColorBlack", 4, _thisObject + "_line2"] call misc_fnc_mapDrawLine;
		// };
	} ENDMETHOD;

ENDCLASS;
