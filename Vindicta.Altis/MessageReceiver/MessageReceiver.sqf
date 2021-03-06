//#define OOP_INFO
#define OOP_WARNING
#define OOP_ERROR
#include "..\OOP_Light\OOP_Light.h"
#include "..\Message\Message.hpp"
#include "..\CriticalSection\CriticalSection.hpp"
#include "MessageReceiver.hpp"

/*
Class: MessageReceiver
This class has capability to handle incoming messages. It also has ability to change its ownership in MP.
Inherited classes must implement a getMessageLoop method which must return the <MessageLoop> object to which a message can be sent.

Author: Sparker
15.06.2018
*/

#define pr private

#define WAIT_UNTIL_TIMEOUT_ENABLE
#define WAIT_UNTIL_TIMEOUT 120

// Number used to generate unique IDs when ownership requests are sent
g_ownerRqNextID = 0;
// Array for generating message IDs
g_rqArray = [0];

// A small function to mark the message with given ID as processed
// Parameters: [msgID, result]
MsgRcvr_fnc_setMsgDone = {
	params ["_msgID", ["_result", 0], "_dest"];
	pr _rqArrayElement = g_rqArray select _msgID; // g_rqArray was defined in messageReceiver.sqf
	// Make sure the proper receiver marks this message
	if ((_rqArrayElement select 2) == _dest) then {
		_rqArrayElement set [0, 1]; // Set the flag that the message has been processed
		_rqArrayElement set [1, _result];
		//diag_log format [" --- Message receiver has acknowledged message: %1,  msgID: %2", _dest, _msgID];
	} else {
		diag_log format ["[MessageReceiver] Error: message was acknowledged by wrong receiver. %1 was acknowledged by %2", _rqArrayElement, _dest];
	};
};

CLASS("MessageReceiver", "Storable")

	VARIABLE_ATTR("owner", [ATTR_SAVE]);

	/*
	Method: new
	Sets initial ownership of the object
	*/
	METHOD("new") {
		params [ ["_thisObject", "", [""]] ];
		
		PROFILER_COUNTER_INC("MessageReceiver");
		
		SETV(_thisObject, "owner", CLIENT_OWNER);
		if (IS_PUBLIC(_thisObject)) then {
			PUBLIC_VAR(_thisObject, "owner");
		};
	} ENDMETHOD;

	/*
	Method: delete
	Deletes this MessageReceiver and deletes messages directed to it from its <MessageLoop>

	Warning: should be called by the thread(<MessageLoop>) which owns this object
	*/
	METHOD("delete") {
		params [ ["_thisObject", "", [""]] ];
		
		PROFILER_COUNTER_DEC("MessageReceiver");
		
		CRITICAL_SECTION {
			private _msgLoop = CALLM(_thisObject, "getMessageLoop", []);
			//diag_log format ["[MessageReceiver:delete] Info: deleting object %1, its message loop: %2", _thisObject, CALLM0(_thisObject, "getMessageLoop")];
			// Delete all remaining messages directed to this object to make sure they will not be handled after the object is deleted
			CALLM(_msgLoop, "deleteReceiverMessages", [_thisObject]);

			if (IS_PUBLIC(_thisObject)) then {
				T_SETV("owner", nil);
				PUBLIC_VAR(_thisObject, "owner");
			};
		};
	} ENDMETHOD;

	/*
	Method: getMessageLoop
	Derived classes must implement this method if they need to receive messages.

	Returns: <MessageLoop> object
	*/
	METHOD("getMessageLoop") {
		""
	} ENDMETHOD;

	/*
	Method: handleMessage
	Handles messages sent to this MessageReceiver. Called by <MessageLoop> inside its thread.

	Access: called by framework. But you can call it manually if you are sure that there will be no race conditions.

	Derived classes can implement this method like this:

	Returns: you can return whatever you need from here to later retrieve it by waitUntilMessageDone.

	--- Code
	switch(_msgType) do {
		case "DO_STUFF": {...};
		case "DO_OTHER_STUFF" : {...};
		default: {return baseClass::handleMessage(msg);}
	}
	---
	*/
	METHOD("handleMessage") { //Derived classes must implement this method
		params [ ["_thisObject", "", [""]] , ["_msg", [], [[]]] ];
		// Please leave your message ...
		diag_log format ["[MessageReceiver] handleMessage: %1", _msg];
		false // message not handled
	} ENDMETHOD;

	/*
	Method: postMessage
	Posts a message into the MessageLoop of this object
	The object can exist on this machine or on another machine
	If it exists on another machine, it still must be represented on this machine, at least it must have the "owner" variable set properly.

	Parameters: _msg, _returnMsgID

	_msg - the <Message> to send to this object.
	_returnMsgID - Optional, Bool, default is false. If true, the framework generates a valid message ID which can be passed to waitUntilMessageDone or messageDone functions.

	Warning: _returnMsgID=true allocates resources that are deallocated by waitUntilMessageDone or messageDone.
	If you don't need to wait for the message processing completion, set _returnMsgID to false.

	Returns: Number, message ID if _returnMsgID is true, MESSAGE_ID_INVALID otherwise.
	*/
	METHOD("postMessage") {
		params [ ["_thisObject", "", [""]] , ["_msg", [], [[]]], ["_returnMsgID", false] ];

		OOP_INFO_1("postMessage: %1", _msg);

		// Check owner of this object
		pr _owner = GETV(_thisObject, "owner");
		// Is the message directed to an object on the same machine?
		if (_owner == CLIENT_OWNER) then {
			pr _messageLoop = CALL_METHOD(_thisObject, "getMessageLoop", []);
			if (_messageLoop == "") exitWith { diag_log format ["[MessageReceiver:postMessage] Error: %1 is not assigned to a message loop", _thisObject];};
			_msg set [MESSAGE_ID_DESTINATION, _thisObject]; //In case message sender forgot to set the destination

			// Do we need to return the msgID?
			if (_returnMsgID) then {
				// Generate a new msgID
				pr _msgID = 0;
				CRITICAL_SECTION_START
					_msgID = g_rqArray find 0;
					if (_msgID == -1) then {
						_msgID = g_rqArray pushback [0, 0, _thisObject]; // When message has been handled, the result will be stored here, 0 will be replaced with 1
					} else {
						g_rqArray set [_msgID, [0, 0, _thisObject]];
					};
					// Set the message id in the message structure, so that messageLoop understands if it needs to set a flag when the message is done
					_msg set [MESSAGE_ID_SOURCE_ID, _msgID];

					OOP_INFO_1("postMessage: generated msgID: %1", _msgID);

					// Post the message to the thread, give it the message ID so that it marks the message as processed
					CALLM1(_messageLoop, "postMessage", _msg);
				CRITICAL_SECTION_END

				//Return message ID value
				_msgID
			} else {
				// Only post the message, messageLoop will decide if it needs to set the messageDone flag and on which machine
				pr _messageLoop = CALL_METHOD(_thisObject, "getMessageLoop", []);
				CALLM1(_messageLoop, "postMessage", _msg);

				// Return a special value in case it gets used by waitUntilMessageDone or messageDone by mistake
				MESSAGE_ID_INVALID
			};
		} else {
			// Tell the other machine to handle this message
			OOP_INFO_0("Sending msg to a remote machine");
			if (_returnMsgID) then {
				// Generate a new message ID
				pr _msgID = 0;
				CRITICAL_SECTION_START
					_msgID = g_rqArray find 0;
					if (_msgID == -1) then {
						_msgID = g_rqArray pushback [0, 0, _thisObject]; // When message has been handled, the result will be stored here, 0 will be replaced with 1
					} else {
						g_rqArray set [_msgID, [0, 0, _thisObject]];
					};
				CRITICAL_SECTION_END

				// Set the message id in the message structure, so that messageLoop understands if it needs to set a flag when the message is done
				_msg set [MESSAGE_ID_SOURCE_ID, _msgID];

				// Post the message on the remote machine
				// Set the _returnMsgID so that it doesn't generate a new message ID on the remote machine and overrides it in the message
				REMOTE_EXEC_CALL_METHOD(_thisObject, "postMessage", [_msg], _owner);

				// Return the _msgID
				_msgID
			} else {
				// The receiver is on the remote machine and we don't need to return the message ID
				// Just send the message to the remote machine and exit
				// Set the _returnMsgID so that it doesn't generate a new message ID on the remote machine and overrides it in the message
				REMOTE_EXEC_CALL_METHOD(_thisObject, "postMessage", [_msg], _owner);

				// Return a special value in case it gets used by waitUntilMessageDone or messageDone by mistake
				MESSAGE_ID_INVALID
			};
		};
	} ENDMETHOD;

	/*
	Method: messageDone
	Returns true if the message with given msgID was done
	A proper msgID must be provided. Always returns true for negative msgID.
	Warning: Returns proper result only once for given msgID

	Parameters: _msgID
	_msgID - the message ID returned by postMessage.

	Returns: Bool
	*/
	STATIC_METHOD("messageDone") {
		params ["_thisClass", "_msgID"];

		// Bail if provided a negative number
		if (_msgID < 0) exitWith {
			if (_msgID == MESSAGE_ID_INVALID) then {
				diag_log format ["[MessageReceiver:messageDone] Error: provided message ID that was not requested. You must request a valid message ID first."];
			};
			true
		};

		// Bail if _msgID has already been processed
		if ((g_rqArray select _msgID) isEqualTo 0) exitWith {
			diag_log format ["[MessageReceiver::messageDone] Error: message with ID %1 has already been processed!", _msgID];
		};

		pr _rqArray = g_rqArray;
		if ((g_rqArray select _msgID select 0) == 1) then {
			// Mark the array element of g_rqArray as ready to be reused
			g_rqArray set [_msgID, 0];
			true
		} else {
			false
		}
	} ENDMETHOD;

	/*
	Method: waitUntilMessageDone

	Parameters: _msgID
	_msgID - the message ID returned by postMessage.

	Returns: whatever was returned by handleMessage of the messageReceiver that was processing the message
	*/
	METHOD("waitUntilMessageDone") {
		params [ ["_thisObject", "", [""]], ["_msgID", 0, [0]] ];

		// Bail if provided a negative number
		if (_msgID < 0) exitWith {
			if (_msgID == MESSAGE_ID_INVALID) then {
				diag_log format ["[MessageReceiver:waitUntilMessageDone] Error: Object: %1, provided message ID that was not requested. You must request a valid message ID first.", _thisObject];
			};
			true
		};

		// Bail if _msgID has already been processed
		if ((g_rqArray select _msgID) isEqualTo 0) exitWith {
			diag_log format ["[MessageReceiver::waitUntilMessageDone] Error: message with ID %1 has already been processed!", _msgID];
		};

		// Wait until a local messageLoop or remote messageLoop marks the message as processed
		#ifdef WAIT_UNTIL_TIMEOUT_ENABLE
		private _timeStartedWaiting = time;
		#endif

		pr _return = 0;
		waitUntil {
			//diag_log "Waiting...";
			OOP_INFO_1("waiting for msgID to be done: %1", _msgID);

			#ifdef WAIT_UNTIL_TIMEOUT_ENABLE
			if (time - _timeStartedWaiting > WAIT_UNTIL_TIMEOUT) then {
				OOP_ERROR_0("waitUntilMessageDone has exceeded threshold!");
				if (!isNil "_thisScript") then {
					OOP_ERROR_1("  This script: %1", _thisScript);
				};
				OOP_ERROR_0("  Active SQF scripts:");
				OOP_ERROR_1("%1", diag_activeSQFScripts);
				{
					/*  scriptName: String - function or filename. Custom name can be set with scriptName
						fileName: String
						isRunning: Boolean
						currentLine: Number - line currently executing */
					_x params ["_scriptName", "_fileName", "_isRunning", "_currentLine"];
					OOP_ERROR_1("  Script name: %1", _scriptName);
					OOP_ERROR_1("    File name: %1", _fileName);
					OOP_ERROR_1("    Is running: %1", _isRunning);
					OOP_ERROR_1("    Current line: %1", _currentLine);
				} forEach diag_activeSQFScripts;
				DUMP_CALLSTACK;
				
				// Format text
				private _text = format["Server is under heavy load! %1 message queue overloaded.", _thisObject];

				// Broadcast notification
				REMOTE_EXEC_CALL_STATIC_METHOD("NotificationFactory", "createSystem", [_text], 0, false);

				// Broadcast it to system chat too
				["SERVER WARNING:"] remoteExec ["systemChat"];
				[_text] remoteExec ["systemChat"];

				// Reset warning timer
				_timeStartedWaiting = time;
			};
			#endif

			(g_rqArray select _msgID select 0) == 1
		};
		_return = g_rqArray select _msgID select 1;

		// Mark the array element of g_rqArray as ready to be reused
		g_rqArray set [_msgID, 0];

		_return
	} ENDMETHOD;

	// ----------------------------------------------------------------------------------------------------
	//
	// 						O W N E R S H I P   M E T H O D S
	//
	// ----------------------------------------------------------------------------------------------------

	// Group: ownership transfer

	// ------------------------------------------------------------------------------------------------------
	// D O N ' T   O V E R R I D E   T H E S E   M E T H O D S   I N   I N H E R I T E D   C L A S S E S
	// ------------------------------------------------------------------------------------------------------

	/*
	Method: setOwner
	Changes owner of a MessageReceiver.

	Parameters: _newOwner

	_newOwner - owner ID of the machine that will receive ownership

	Warning: must be called in scheduled environment as it waits until the other machine accepts ownership.

	Returns: Bool, true if ownership was changed successfully, false otherwise.
	*/
	// Must be called on the machine that owns this object to change ownership
	// For safety this should be called in the thread that owns the object
	// Don't override this in inherited classes!
	// Returns true/falls depending on success
	/* private */ METHOD("setOwner") {
		params [ ["_thisObject", "", [""]], ["_newOwner", 0, [0]] ];

		// Bail if this machine doesn't own this object
		pr _owner = GETV(_thisObject, "owner");
		if (_owner != CLIENT_OWNER) exitWith {
			diag_log format ["[MessageReceiver:setOwner] Error: can't change ownership of object %1 from %2 to %3. Reason: object is owned not by this machine. This machine owner ID:%4.",
				_thisObject, _owner, _newOwner, CLIENT_OWNER];

			// Return failure
			false
		};

		// Bail if non-existant newOwner was supplied
		pr _ownerNotFound = (((allPlayers + (entities "HeadlessClient_F")) findif {owner _x == _newOwner}) == -1);
		if ( _ownerNotFound || ((_newOwner == 2) && !isMultiplayer) || (CLIENT_OWNER == 0 && _newOwner == 2) || (_newOwner == 0) ) exitWith {
			if (_ownerNotFound) then {
				diag_log format ["[MessageReceiver:setOwner] Error: can't change ownership of object %1 from %2 to %3. Reason: new owner not found.",
					_thisObject, _owner, _newOwner, CLIENT_OWNER];
			} else {
				diag_log format ["[MessageReceiver:setOwner] Error: can't change ownership of object %1 from %2 to %3. Reason: new owner is invalid.",
					_thisObject, _owner, _newOwner, CLIENT_OWNER];
			};

			// Return failure
			false
		};

		// Ask the other machine to take ownership

		// Serialize data of this object
		pr _serData = CALLM(_thisObject, "serialize", []);
		pr _parent = OBJECT_PARENT_CLASS_STR(_thisObject); // Get the class this object belongs to
		// Generate a unique ID for this message
		pr _uniqueID = g_ownerRqNextID;
		CRITICAL_SECTION_START
			g_ownerRqNextID = g_ownerRqNextID + 1; // Run this in a critical section. Is it really needed or is a=a+1 atomic?
		CRITICAL_SECTION_END
		// Send message to the other machine
		pr _ackVarName = OWNER_CHANGE_ACK(_uniqueID); // Variable that will be set to 1 when the other machine acks the ownership change
		missionNamespace setVariable [_ackVarName, nil];
		[_thisObject, _parent, _uniqueID, _serdata] remoteExecCall [CLASS_METHOD_NAME_STR("MessageReceiver", "receiveOwnership"), _newOwner, false];
		pr _timeTimeout = time + OWNER_CHANGE_ACK_TIMEOUT;
		waitUntil {
			(! (isNil _ackVarName)) || (time > _timeTimeout)
		};

		// Did the ownership change timeout?
		if (time > _timeTimeout) exitWith {

			// Try to invalidate the object's owner at the other machine
			[[_thisObject, CLIENT_OWNER], {SETV(_this select 0, "owner", _this select 1);}] remoteExecCall ["call", _newOwner, false];

			diag_log format ["[MessageReceiver:setOwner] Error: can't change ownership of object %1 from %2 to %3. Reason: timeout.",
				_thisObject, _owner, _newOwner, CLIENT_OWNER];

			// Return failure
			false
		};

		// The other machine has successfully accepted the new object
		// Now transfer ownership of underlying objects, if they exist
		if (! (CALLM1(_thisObject, "transferOwnership", _newOwner))) exitWith {
			// Failed to lose ownership
			// Probably failed to transfer other objects

			// Invalidate the object at the other machine
			// So that the other machine doesn't thing that it owns the object
			[[_thisObject, CLIENT_OWNER], {SETV(_this select 0, "owner", _this select 1);}] remoteExecCall ["call", _newOwner, false];

			// Take the object back
			SETV(_thisObject, "owner", CLIENT_OWNER);

			// Return failure
			false
		};

		SETV(_thisObject, "owner", _newOwner);

		// I can't believe we have accomplished this
		diag_log format ["[MessageReceiver:setOwner] Success: changed owner of %1 to %2", _thisObject, _newOwner];
		true

	} ENDMETHOD;

	/*
	Method: receiveOwnership
	Called on remote machine when an ownership change is in the process.

	Access: Internal use only! Don't override!

	Parameters: _objParent, _uniqueID, _serialData

	Returns: nil
	*/
	/* private */ STATIC_METHOD("receiveOwnership") {
		params [ ["_objNameStr", "", [""]], ["_objParent", "", [""]], ["_uniqueID", 0, [0]], ["_serialData", 0]];

		diag_log format ["Receive ownership was called: %1", _this];

		// Create a new object with provided name
		pr _newObj = NEW_EXISTING(_objParent, _objNameStr);
		SETV(_newObj, "owner", CLIENT_OWNER);

		// Deserialize data into the new object
		pr _deserSuccess = CALLM(_newObj, "deserialize", [_serialData]);

		diag_log format ["[MessageReceiver::receiveOwnership] Info: Transfering %1. Sending ACK to %2", _objNameStr, remoteExecutedOwner];

		// Send an ACK back to the original machine
		[_uniqueID, {missionNamespace setVariable [OWNER_CHANGE_ACK(_this), 1];}] remoteExecCall ["call", remoteExecutedOwner, false];
	} ENDMETHOD;




	// --------------------------------------------------------------------------------------------
	// YOU MUST OVERRIDE THESE METHODS IF YOU NEED TO CHANGE OWNERSHIP OF OBJECTS OF YOUR INHERITED CLASS
	// --------------------------------------------------------------------------------------------
	/*
	Method: serialize
	Must return a single value which can be deserialized by deserialize method to restore value of an object.

	Override if you need to transfer ownership of objects of your inherited class.

	Returns: anything you need which can be sent over network.
	*/
	/* virtual */ METHOD("serialize") {
		params [["_thisObject", "", [""]]];
		diag_log format ["[MessageReceiver:serialize] Error: method serialize is not implemented for %1!", _thisObject];

		// Return serialized data in any format
		0
	} ENDMETHOD;

	/*
	Method: deserialize
	Takes the output of serialize and restores values of an object

	Override if you need to transfer ownership of objects of your inherited class.

	Returns: nil
	*/
	/* virtual */ METHOD("deserialize") {
		params [["_thisObject", "", [""]], "_serialData"];
		diag_log format ["[MessageReceiver:serialize] Error: method deserialize is not implemented for %1!", _thisObject];
	} ENDMETHOD;

	/*
	Method: transferOwnership
	Called on local machine when an ownership transfer is in the progress.
	If your class has objects that must be transfered through the same mechanism, you must handle transfer of ownership of such objects here.
	If transfer of all objects has happened properly, must return true.

	You can also clear unneeded variables of this object here.

	Parameters: _newOwner

	_newOwner - owner ID of the machine that will receive ownership

	Returns: Bool
	*/
	/* virtual */ METHOD("transferOwnership") {
		params [ ["_thisObject", "", [""]], ["_newOwner", 0, [0]] ];
		diag_log format ["[MessageReceiver:transferOwnership] Error: method transferOwnership is not implemented for %1!", _thisObject];
		false
	} ENDMETHOD;



	// Storage methods

	METHOD("postDeserialize") {
		params [P_THISOBJECT, P_OOP_OBJECT("_storage")];

		// Must broadcast public variables
		SETV(_thisObject, "owner", CLIENT_OWNER); // Now we own this obviously
		if (IS_PUBLIC(_thisObject)) then {
			PUBLIC_VAR(_thisObject, "owner");
		};

		true
	} ENDMETHOD;

	/* override */ STATIC_METHOD("saveStaticVariables") {
		params [P_THISCLASS, P_OOP_OBJECT("_storage")];

		pr _value = +g_rqArray;
		CALLM2(_storage, "save", "MessageReceiver_rqArray", _value);
	} ENDMETHOD;

	/* override */ STATIC_METHOD("loadStaticVariables") {
		params [P_THISCLASS, P_OOP_OBJECT("_storage")];

		g_rqArray = CALLM1(_storage, "load", "MessageReceiver_rqArray");
	} ENDMETHOD;

ENDCLASS;
