#pragma semicolon 1
#pragma newdecls required

#define LIGHT_VERSION

#include <sourcemod>
// #include <sdkhooks>
#include <sdktools>
#include <tf2_stocks>
#include <dhooks>
#if !defined LIGHT_VERSION
#include <lowhelpers>
#endif

#define PLUGIN_VERSION 	"1.0"

#define DHookMode_Pre 	false
#define DHookMode_Post 	true

#if !defined LIGHT_VERSION
// #define Offset_Null 		0

#define EHANDLE_SIZE 		32
#define EHANDLE_BITS 		12
#define EHANDLE_INDEX 	((1 << EHANDLE_BITS) - 1)

#define DMG_GENERIC 		0

enum EHANDLE
{
	EHANDLE_Invalid = 0
}

enum ECritType
{
	CRIT_NONE = 0,
	CRIT_MINI,
	CRIT_FULL
}

enum struct CTakeDamageInfo
{
	// Since having arrays inside Pawn's structs turns it into a multi-dimensional array,
	// we'll have to have everything as separate fields to keep a one-dimensional structure
	float 		damageForce[3];
	float 		damagePosition[3];
	float 		reportedPosition[3];
	EHANDLE 	inflictor;
	EHANDLE 	attacker;
	EHANDLE 	weapon;
	float 		damage;
	float 		maxDamage;
	float 		baseDamage;
	int 		damageType;
	int 		damageCustom;
	int 		damageStats;
	int 		ammoType;
	int 		damagedOtherPlayers;
	int 		playerPenetrationCount;
	float 		damageBonus;
	EHANDLE 	damageBonusProvider;
	bool 		forceFriendlyFire;
	
	// Due to the way Pawn stores structs, everything after a bool field is inaccessible
	/*
	float 		damageForForce;
	ECritType 	critType;
	*/
	
	// Add some padding to keep the size not less than required
	int 		padding1;
	int 		padding2;
}
#endif

#if defined LIGHT_VERSION
Handle callENTINDEX;
#else
Handle callTakeDamage;
// Handle callKeyValuesGetName;
#endif

#if defined LIGHT_VERSION
Handle hookSetRPSResult;
#else
Handle hookPlayScene;
Handle hookDispatchRPSEffect;
Handle hookTakeDamage;
Handle hookShouldGib;
// Handle hookFireEvent;
#endif

#if defined LIGHT_VERSION
int offsetTauntRPSResult;
int offsetReceiverValue;
#endif

#if !defined LIGHT_VERSION
ConVar cvarPlayerGib;
#endif

bool shouldRPS[MAXPLAYERS + 1];
#if !defined LIGHT_VERSION
bool shouldGib[MAXPLAYERS + 1];
#endif

public Plugin myinfo = 
{
	name = "Rock, Paper, Scissors",
	author = "Dachtone",
	description = "Cheat in RPS",
	version = PLUGIN_VERSION,
	url = "http://steamcommunity.com/profiles/76561198050338268"
};

public void OnPluginStart()
{
	CreateConVar("rps_version", PLUGIN_VERSION, "Rock, Paper, Scissors Version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	
#if !defined LIGHT_VERSION
	cvarPlayerGib = FindConVar("tf_playergib");
#endif
	
	if (!SetupHooksAndCalls())
		return;
	
#if !defined LIGHT_VERSION
	HookEvent("rps_taunt_event", OnRPSEvent, EventHookMode_Pre);
#endif
	
	RegAdminCmd("sm_rps", AdminRPS, ADMFLAG_SLAY);
	
	LoadTranslations("common.phrases");
	LoadTranslations("rps.phrases");
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
			OnClientPutInServer(i);
	}
}

bool SetupHooksAndCalls()
{
	// Load GameData
	GameData data = LoadGameConfigFile("rps");
	if (data == null)
	{
		SetFailState("Unable to find the gamedata");
		return false;
	}
	
#if defined LIGHT_VERSION
	/* SetRPSResult */
	
	// DHooks
	Address addressSetRPSResult = GameConfGetAddress(data, "SetRPSResult");
	if (addressSetRPSResult == Address_Null)
	{
		delete data;
		SetFailState("Unable to get SetRPSResult address");
		return false;
	}
	
	// hookSetRPSResult = DHookCreateDetour(addressSetRPSResult, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
	hookSetRPSResult = DHookCreateDetour(addressSetRPSResult, CallConv_CDECL, ReturnType_Void, ThisPointer_Ignore);
	if (hookSetRPSResult == null)
	{
		delete data;
		SetFailState("Unable to create SetRPSResult detour");
		return false;
	}
	
	// void CTFPlayer::AcceptTauntWithPartner(CTFPlayer *initiator)
	DHookAddParam(hookSetRPSResult, HookParamType_Int, .custom_register = DHookRegister_ESI); // Treat the pointer as an integer
	DHookAddParam(hookSetRPSResult, HookParamType_Int, .custom_register = DHookRegister_EBX); // iInitiator
	DHookAddParam(hookSetRPSResult, HookParamType_Int, .custom_register = DHookRegister_EBP); // Base pointer
	
	// We have to preserve the value in this register for the original function to continue executing,
	// so we'll add it as a parameter and have DHooks copy its original value back upon hook completion
	DHookAddParam(hookSetRPSResult, HookParamType_Int, .custom_register = DHookRegister_ECX);
	
	if (!DHookEnableDetour(hookSetRPSResult, DHookMode_Pre, OnSetRPSResult))
	{
		delete data;
		SetFailState("Failed to enable SetRPSResult detour");
		return false;
	}
	
	/* m_iTauntRPSResult */
	
	char buffer[8];
	if (!GameConfGetKeyValue(data, "m_iTauntRPSResult", buffer, sizeof(buffer)))
	{
		delete data;
		SetFailState("Offset for m_iTauntRPSResult not found");
		return false;
	}
	
	offsetTauntRPSResult = StringToInt(buffer);
	
	/* iReceiver */
	
	if (!GameConfGetKeyValue(data, "iReceiver", buffer, sizeof(buffer)))
	{
		delete data;
		SetFailState("Offset for iReceiver not found");
		return false;
	}
	
	offsetReceiverValue = StringToInt(buffer);
	
	/* ENTINDEX */
	
	// SDKTools
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(data, SDKConf_Signature, "ENTINDEX"))
	{
		delete data;
		EndPrepSDKCall();
		
		SetFailState("Unable to start the preparation of ENTINDEX SDK call");
		
		return false;
	}
	
	// int ENTINDEX(CBaseEntity *pEnt)
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue); // Treat the pointer as an integer
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    
	callENTINDEX = EndPrepSDKCall();
	if (callENTINDEX == null)
	{
		delete data;
		SetFailState("Unable to prepare ENTINDEX SDK call");
		return false;
	}
#else
	/* PlayScene */
	
	// DHooks
	/*
	hookPlayScene = DHookCreate(Offset_Null, HookType_Entity, ReturnType_Float, ThisPointer_CBaseEntity, OnPlayScene);
	if (hookPlayScene == null)
	{
		delete data;
		SetFailState("Unable to create CTFPlayer::PlayScene hook");
		return false;
	}
	
	if (!DHookSetFromConf(hookPlayScene, data, SDKConf_Virtual, "CTFPlayer::PlayScene"))
	{
		delete data;
		SetFailState("Offset not found for CTFPlayer::PlayScene");
		return false;
	}

	// void float CTFPlayer::PlayScene(const char *pszScene, float flDelay = 0.0f, AI_Response *response = NULL, IRecipientFilter *filter = NULL)
	DHookAddParam(hookPlayScene, HookParamType_CharPtr);
	DHookAddParam(hookPlayScene, HookParamType_Float);
	DHookAddParam(hookPlayScene, HookParamType_ObjectPtr);
	DHookAddParam(hookPlayScene, HookParamType_ObjectPtr);
	*/
	
	hookPlayScene = DHookCreateFromConf(data, "CTFPlayer::PlayScene");
	if (hookPlayScene == null)
	{
		delete data;
		SetFailState("Unable to create CTFPlayer::PlayScene hook");
		return false;
	}
	
	/* DispatchRPSEffect */
	
	// DHooks
	/*
	hookDispatchRPSEffect = DHookCreateDetour(Address_Null, CallConv_CDECL, ReturnType_Void, ThisPointer_Ignore);
	if (hookDispatchRPSEffect == null)
	{
		delete data;
		SetFailState("Unable to create DispatchRPSEffect detour");
		return false;
	}
	
	if (!DHookSetFromConf(hookDispatchRPSEffect, data, SDKConf_Signature, "DispatchRPSEffect"))
	{
		delete data;
		SetFailState("Signature not found for DispatchRPSEffect");
		return false;
	}
	
	// void DispatchRPSEffect(const CTFPlayer *pPlayer, const char* pszParticleName)
	DHookAddParam(hookDispatchRPSEffect, HookParamType_CBaseEntity, .custom_register = DHookRegister_EBX);
	DHookAddParam(hookDispatchRPSEffect, HookParamType_CharPtr, .custom_register = DHookRegister_EDX);
	*/
	
	hookDispatchRPSEffect = DHookCreateFromConf(data, "DispatchRPSEffect");
	if (hookDispatchRPSEffect == null)
	{
		delete data;
		SetFailState("Unable to create DispatchRPSEffect hook");
		return false;
	}
	
	if (!DHookEnableDetour(hookDispatchRPSEffect, DHookMode_Pre, OnDispatchRPSEffect))
	{
		delete data;
		SetFailState("Failed to enable DispatchRPSEffect detour");
		return false;
	}
	
	/* TakeDamage */
	
	// SDKTools
	StartPrepSDKCall(SDKCall_Entity);
	if (!PrepSDKCall_SetFromConf(data, SDKConf_Signature, "CBaseEntity::TakeDamage"))
	{
		delete data;
		EndPrepSDKCall();
		
		SetFailState("Unable to start the preparation of CBaseEntity::TakeDamage SDK call");
		
		return false;
	}
	
	// int CBaseEntity::TakeDamage(const CTakeDamageInfo *info)
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // Treat the pointer as an integer
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    
	callTakeDamage = EndPrepSDKCall();
	if (callTakeDamage == null)
	{
		delete data;
		SetFailState("Unable to prepare CBaseEntity::TakeDamage SDK call");
		return false;
	}
	
	// DHooks
	/*
	hookTakeDamage = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Int, ThisPointer_CBaseEntity);
	if (hookTakeDamage == null)
	{
		delete data;
		SetFailState("Unable to create CBaseEntity::TakeDamage detour");
		return false;
	}
	
	if (!DHookSetFromConf(hookTakeDamage, data, SDKConf_Signature, "CBaseEntity::TakeDamage"))
	{
		delete data;
		SetFailState("Signature not found for CBaseEntity::TakeDamage");
		return false;
	}
	
	// int CBaseEntity::TakeDamage(const CTakeDamageInfo *info)
	// 4 * 3 * 3 + 4 * 3 + 4 * 3 + 4 * 6 + 4 + 4 + 1 + 4 + 4
	DHookAddParam(hookTakeDamage, HookParamType_ObjectPtr); // .flag = DHookPass_ByRef
	// DHookAddParam(hookTakeDamage, HookParamType_Int); // Treat the pointer as an integer
	*/
	
	hookTakeDamage = DHookCreateFromConf(data, "CBaseEntity::TakeDamage");
	if (hookTakeDamage == null)
	{
		delete data;
		SetFailState("Unable to create CBaseEntity::TakeDamage hook");
		return false;
	}
	
	if (!DHookEnableDetour(hookTakeDamage, DHookMode_Pre, OnTakeDamage))
	{
		delete data;
		SetFailState("Failed to enable CBaseEntity::TakeDamage detour");
		return false;
	}
	
	/* ShouldGib */
	
	// DHooks
	/*
	hookShouldGib = DHookCreate(Offset_Null, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity, OnShouldGib);
	if (hookShouldGib == null)
	{
		delete data;
		SetFailState("Unable to create CTFPlayer::ShouldGib hook");
		return false;
	}
	
	if (!DHookSetFromConf(hookShouldGib, data, SDKConf_Virtual, "CTFPlayer::ShouldGib"))
	{
		delete data;
		SetFailState("Offset not found for CTFPlayer::ShouldGib");
		return false;
	}
	
	// bool CTFPlayer::ShouldGib(const CTakeDamageInfo *info)
	// 4 * 3 * 3 + 4 * 3 + 4 * 3 + 4 * 6 + 4 + 4 + 1 + 4 + 4
	DHookAddParam(hookShouldGib, HookParamType_ObjectPtr); // .flag = DHookPass_ByRef
	*/
	
	hookShouldGib = DHookCreateFromConf(data, "CTFPlayer::ShouldGib");
	if (hookShouldGib == null)
	{
		delete data;
		SetFailState("Unable to create CTFPlayer::ShouldGib hook");
		return false;
	}
	
	/* FireEvent */
	
	/*
	// DHooks
	hookFireEvent = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
	if (hookFireEvent == null)
	{
		delete data;
		SetFailState("Unable to create CGameEventManager::FireEvent detour");
		return false;
	}
	
	if (!DHookSetFromConf(hookFireEvent, data, SDKConf_Signature, "CGameEventManager::FireEvent"))
	{
		delete data;
		SetFailState("Signature not found for CGameEventManager::FireEvent");
		return false;
	}
	
	// bool CGameEventManager::FireEvent(IGameEvent *event, bool bServerOnly)
	DHookAddParam(hookFireEvent, HookParamType_ObjectPtr);
	DHookAddParam(hookFireEvent, HookParamType_Bool);
	
	if (!DHookEnableDetour(hookFireEvent, DHookMode_Pre, OnFireEvent))
	{
		delete data;
		SetFailState("Failed to enable CGameEventManager::FireEvent detour");
		return false;
	}
	*/
	
	/* KeyValues::GetName */
	
	/*
	// SDKTools
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(data, SDKConf_Signature, "KeyValues::GetName"))
	{
		delete data;
		EndPrepSDKCall();
		
		SetFailState("Unable to start the preparation of KeyValues::GetName SDK call");
		
		return false;
	}
	
	// const char *KeyValues::GetName()
	// PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // Treat the pointer as an integer
	PrepSDKCall_SetReturnInfo(SDKType_String, SDKPass_Pointer);
    
	callKeyValuesGetName = EndPrepSDKCall();
	if (callKeyValuesGetName == null)
	{
		delete data;
		SetFailState("Unable to prepare KeyValues::GetName SDK call");
		return false;
	}
	*/
#endif
	
	/* Clean up */
	
	delete data;
	
	return true;
}

public void OnClientPutInServer(int client)
{
#if !defined LIGHT_VERSION
	if (DHookEntity(hookPlayScene, DHookMode_Pre, client, INVALID_FUNCTION, OnPlayScene) == -1)
	{
		SetFailState("Unable to hook PlayScene");
		return;
	}
	
	if (DHookEntity(hookShouldGib, DHookMode_Post, client, INVALID_FUNCTION, OnShouldGib) == -1)
	{
		SetFailState("Unable to hook ShouldGib");
		return;
	}
	
	// SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
#endif
	
	shouldRPS[client] = false;
#if !defined LIGHT_VERSION
	shouldGib[client] = false;
#endif
}

public void OnClientDisconnect(int client)
{
	shouldRPS[client] = false;
#if !defined LIGHT_VERSION
	shouldGib[client] = false;
#endif
}

#if defined LIGHT_VERSION
// void CTFPlayer::AcceptTauntWithPartner(CTFPlayer *initiator)
public MRESReturn OnSetRPSResult(Handle params)
{
	Address clientCBaseEntity = DHookGetParam(params, 1);
	int client = GetClientFromCBaseEntity(clientCBaseEntity);
	if (!IsValidClient(client))
		return MRES_Ignored;
	
	int partner = GetEntPropEnt(client, Prop_Send, "m_hHighFivePartner");
	if (!IsValidClient(partner))
		return MRES_Ignored;
	
	if (shouldRPS[client] == shouldRPS[partner])
		return MRES_Ignored;
	
	Address addressTauntRPSResult = clientCBaseEntity + view_as<Address>(offsetTauntRPSResult);
	int result = LoadFromAddress(addressTauntRPSResult, NumberType_Int32);
	if ((shouldRPS[client] && result < 3) || (shouldRPS[partner] && result >= 3))
		return MRES_Ignored;
	
	switch (result)
	{
		case 0:
			result = 5;
		case 1:
			result = 3;
		case 2:
			result = 4;
		case 3:
			result = 1;
		case 4:
			result = 2;
		case 5:
			result = 0;
	}
	StoreToAddress(addressTauntRPSResult, result, NumberType_Int32);
	
	int initiatorValue = DHookGetParam(params, 2);
	
	Address ebp = DHookGetParam(params, 3);
	Address addressReceiverValue = ebp - view_as<Address>(offsetReceiverValue);
	int receiverValue = LoadFromAddress(addressReceiverValue, NumberType_Int32);
	
	DHookSetParam(params, 2, receiverValue);
	StoreToAddress(addressReceiverValue, initiatorValue, NumberType_Int32);
	
	return MRES_ChangedHandled;
}
#else
// void float CTFPlayer::PlayScene(const char *pszScene, float flDelay = 0.0f, AI_Response *response = NULL, IRecipientFilter *filter = NULL)
public MRESReturn OnPlayScene(int client, Handle returnHandle, Handle params)
{
	if (!IsValidClient(client))
		return MRES_Ignored;
	
	int partner = GetEntPropEnt(client, Prop_Send, "m_hHighFivePartner");
	if (!IsValidClient(partner))
		return MRES_Ignored;
	
	if (shouldRPS[client] == shouldRPS[partner])
		return MRES_Ignored;
	
	char sceneName[PLATFORM_MAX_PATH];
	DHookGetParamString(params, 1, sceneName, sizeof(sceneName));
	
	int length = 0;
	int count = 0;
	int nameStart = 0;
	while (sceneName[length] != '\0')
	{
		if (sceneName[length] != '\\')
		{
			length++;
			continue;
		}
		
		count++;
		
		if (count == 4)
			nameStart = length + 1;
		
		length++;
	}
	
	if (count != 4 || nameStart == 0 || nameStart + 10 > length)
		return MRES_Ignored;
	
	length = nameStart;
	count = 0;
	char element;
	bool won = false;
	while (sceneName[length] != '\0')
	{
		if (sceneName[length] != '_')
		{
			length++;
			continue;
		}
		
		count++;
			
		if (count == 2)
			element = sceneName[length + 1];
		else if (count == 3)
			won = sceneName[length + 1] == 'w';
		
		length++;
	}
	
	if (count < 3 || count > 4 || (element != 'r' && element != 'p' && element != 's'))
		return MRES_Ignored;
	
	bool initiator = count == 4;
	
	if (won == shouldRPS[client])
		return MRES_Ignored;
	
	char elementName[16];
	switch (element)
	{
		case 'r':
			elementName = won ? "scissors" : "paper";
		case 'p':
			elementName = won ? "rock" : "scissors";
		case 's':
			elementName = won ? "paper" : "rock";
	}
	
	char class[16];
	switch (TF2_GetPlayerClass(client))
	{
		case TFClass_Scout:
			class = "scout";
		case TFClass_Soldier:
			class = "soldier";
		case TFClass_Pyro:
			class = "pyro";
		case TFClass_DemoMan:
			class = "demo";
		case TFClass_Heavy:
			class = "heavy";
		case TFClass_Engineer:
			class = "engineer";
		case TFClass_Medic:
			class = "medic";
		case TFClass_Sniper:
			class = "sniper";
		case TFClass_Spy:
			class = "spy";
	}
	
	Format(sceneName, sizeof(sceneName), "scenes\\player\\%s\\low\\taunt_rps_%s_%s%s.vcd", class, elementName, won ? "lose" : "win", initiator ? "" : "_noinit");
	
	DHookSetParamString(params, 1, sceneName);
	
	return MRES_ChangedHandled;
}

// void DispatchRPSEffect(const CTFPlayer *pPlayer, const char* pszParticleName)
public MRESReturn OnDispatchRPSEffect(Handle params)
{
	int client = DHookGetParam(params, 1);
	if (!IsValidClient(client))
		return MRES_Ignored;
	
	int partner = GetEntPropEnt(client, Prop_Send, "m_hHighFivePartner");
	if (!IsValidClient(partner))
		return MRES_Ignored;
	
	if (shouldRPS[client] == shouldRPS[partner])
		return MRES_Ignored;
	
	static bool initiator = false;
	initiator = !initiator;
	
	if (!initiator)
	{
		int temp = client;
		client = partner;
		partner = temp;
	}
	
	/*
	static const char *s_pszTauntRPSParticleNames[] =
	{
		"rps_rock_red",
		"rps_paper_red",
		"rps_scissors_red",
		"rps_rock_red_win",
		"rps_paper_red_win",
		"rps_scissors_red_win",
		"rps_rock_blue",
		"rps_paper_blue",
		"rps_scissors_blue",
		"rps_rock_blue_win",
		"rps_paper_blue_win",
		"rps_scissors_blue_win"
	};
	*/
	
	char particleName[32];
	DHookGetParamString(params, 2, particleName, sizeof(particleName));
	
	int length = 0;
	while (particleName[length] != '\0')
		length++;
	
	bool won = particleName[length - 1] == 'n';
	
	if (won == shouldRPS[client])
		return MRES_Ignored;
	
	char elementName[16];
	switch (particleName[4])
	{
		case 'r':
			elementName = won ? "scissors" : "paper";
		case 'p':
			elementName = won ? "rock" : "scissors";
		case 's':
			elementName = won ? "paper" : "rock";
	}
	
	Format(particleName, sizeof(particleName), "rps_%s_%s%s", elementName, TF2_GetClientTeam(client) == TFTeam_Red ? "red" : "blue", won ? "" : "_win");
	
	DHookSetParamString(params, 2, particleName);
	
	return MRES_ChangedHandled;
}

/*
public Action OnTakeDamage(int client, int& attacker, int& inflictor, float& damage, int& damageType, int& weaponType, float damageForce[3], float damagePosition[3])
{
	if (!IsValidClient(client) || !IsValidClient(attacker))
		return Plugin_Continue;
	
	if (!shouldRPS[client] || (shouldRPS[client] && shouldRPS[attacker]))
		return Plugin_Continue;
	
	// CTakeDamageInfo(CBaseEntity *pInflictor, CBaseEntity *pAttacker, CBaseEntity *pWeapon, float flDamage, int bitsDamageType, int iKillType = 0)
	// CTakeDamageInfo(pWinner, pWinner, NULL, 999, DMG_GENERIC, 0)
	
	if (damage != 999.0 || damageType != DMG_GENERIC)
		return Plugin_Continue;
	
	shouldGib[attacker] = true;
	SDKHooks_TakeDamage(attacker, client, client, damage, damageType, weaponType, damageForce, damagePosition);
	shouldGib[attacker] = false;
	
	return Plugin_Handled;
}
*/

// int CBaseEntity::TakeDamage(const CTakeDamageInfo *info)
public MRESReturn OnTakeDamage(int client, Handle returnHandle, Handle params)
{
	if (!IsValidClient(client) || !TF2_IsPlayerInCondition(client, TFCond_Taunting))
		return MRES_Ignored;
	
	// Address damageInfo = DHookGetParam(params, 1);
	
	// 4 * 3 * 3 + 4
	int attacker = DHookGetParamObjectPtrVar(params, 1, 40, ObjectValueType_Ehandle);
	// int attacker = GetClientFromEHANDLE(LoadFromAddress(damageInfo + view_as<Address>(40), NumberType_Int32));
	if (!IsValidClient(attacker) || !TF2_IsPlayerInCondition(attacker, TFCond_Taunting))
		return MRES_Ignored;
	
	if (!shouldRPS[client] || shouldRPS[attacker])
		return MRES_Ignored;
	
	// 40 + 4 * 2
	float damage = DHookGetParamObjectPtrVar(params, 1, 48, ObjectValueType_Float);
	// float damage = view_as<float>(LoadFromAddress(damageInfo + view_as<Address>(48), NumberType_Int32));
	
	// 48 + 4 * 3
	int damageType = DHookGetParamObjectPtrVar(params, 1, 60, ObjectValueType_Int);
	// int damageType = LoadFromAddress(damageInfo + view_as<Address>(60), NumberType_Int32);
	
	// CTakeDamageInfo(pWinner, pWinner, NULL, 999, DMG_GENERIC, 0)
	if (damage != 999.0 || damageType != DMG_GENERIC)
		return MRES_Ignored;
	
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(attacker));
	pack.WriteCell(GetClientUserId(client));
	// pack.WriteCell(true); // Should player gib
	RequestFrame(FrameCallTakeDamage, pack);
	
	DHookSetReturn(returnHandle, 0);
	return MRES_Supercede;
}

void FrameCallTakeDamage(DataPack pack)
{
	pack.Reset();
	
	int client = GetClientOfUserId(pack.ReadCell());
	if (!IsValidClient(client))
	{
		delete pack;
		return;
	}
	
	int attacker = GetClientOfUserId(pack.ReadCell());
	if (!IsValidClient(attacker))
	{
		delete pack;
		return;
	}
	
	// bool gib = pack.ReadCell() == 1;
	
	delete pack;
	
	EHANDLE attackerHandle = GetClientEHANDLE(attacker);
	
	// CTakeDamageInfo(pWinner, pWinner, NULL, 999, DMG_GENERIC, 0)
	CTakeDamageInfo damageInfo;
	damageInfo.inflictor = attackerHandle;
	damageInfo.attacker = attackerHandle;
	damageInfo.damage = 999.0;
	damageInfo.damageType = DMG_GENERIC;
	
	
	// if (gib)
	shouldGib[client] = true;
	SDKCall(callTakeDamage, client, GetVariableAddress(damageInfo.damageForce[0]));
	// if (gib)
	shouldGib[client] = false;
}

// bool CTFPlayer::ShouldGib(const CTakeDamageInfo *info)
public MRESReturn OnShouldGib(int client, Handle returnHandle, Handle params)
{
	if (!shouldGib[client])
		return MRES_Ignored;
	
	if (DHookGetReturn(returnHandle))
		return MRES_Ignored;
	
	int gib = cvarPlayerGib.IntValue;
	if (gib != 1)
	{
		DHookSetReturn(returnHandle, gib > 1);
		return MRES_Supercede;
	}
	
	if (GameRules_GetProp("m_bPlayingMannVsMachine") == 1)
	{
		DHookSetReturn(returnHandle, false);
		return MRES_Supercede;
	}
	
	DHookSetReturn(returnHandle, true);
	return MRES_Supercede;
}

public Action OnRPSEvent(Event event, const char[] name, bool dontBroadcast)
{
	int winner = event.GetInt("winner");
	int winnerRPS = event.GetInt("winner_rps");
	
	int loser = event.GetInt("loser");
	int loserRPS = event.GetInt("loser_rps");
	
	if (!shouldRPS[loser] || shouldRPS[winner])
		return Plugin_Continue;
	
	event.SetInt("winner", loser);
	event.SetInt("winner_rps", loserRPS);
	
	event.SetInt("loser", winner);
	event.SetInt("loser_rps", winnerRPS);
	
	return Plugin_Changed;
}

// bool CGameEventManager::FireEvent(IGameEvent *event, bool bServerOnly)
/*
public MRESReturn OnFireEvent(Address thisPointer, Handle returnHandle, Handle params)
{
*/
	/*
	class CGameEvent
	{
		CGameEventDescriptor	*m_pDescriptor;
		KeyValues				*m_pDataKeys;
	};
	*/
	
	/*
	Address keyValuesPointer = DHookGetParamObjectPtrVar(params, 1, 4, ObjectValueType_Int);
	if (keyValuesPointer == Address_Null)
		return MRES_Ignored;
	
	char eventName[16];
	SDKCall(callKeyValuesGetName, keyValuesPointer, eventName, sizeof(eventName));
	
	PrintToRootAdmins("[Debug] CGameEventManager::FireEvent(\"%s\")", eventName);
	*/
	
	/*
	Address descriptorPointer = DHookGetParamObjectPtrVar(params, 1, 0, ObjectValueType_Int);
	if (descriptorPointer == Address_Null)
		return MRES_Ignored;
	
	Address eventNamePointer = view_as<Address>(LoadFromAddress(descriptorPointer, NumberType_Int32));
	if (eventNamePointer == Address_Null)
		return MRES_Ignored;
	*/
	
	/*
	const int eventNameMaxLength = 15;
	int length = 0;
	char eventName[eventNameMaxLength + 1];
	char temp;
	while (length < eventNameMaxLength)
	{
		temp = LoadFromAddress(eventNamePointer, NumberType_Int8);
		if (temp == '\0')
			break;
		
		eventName[length] = temp;
		length++;
		
		eventNamePointer++;
	}
	eventName[length] = '\0';
	*/
	
	/*
	char temp = LoadFromAddress(eventNamePointer, NumberType_Int8);
	
	PrintToRootAdmins("[Debug] eventNamePointer = 0x%X, *eventNamePointer = %c, &*eventNamePointer = 0x%X", eventNamePointer, temp, GetVariableAddress(temp));
	*/
	
/*
	return MRES_Ignored;
}
*/
#endif

public Action AdminRPS(int client, int args)
{
	if (args < 1)
	{
		if (!IsValidClient(client))
			return Plugin_Handled;
		
		shouldRPS[client] = !shouldRPS[client];
		
		char name[32];
		GetClientName(client, name, sizeof(name));
		PrintToChat(client, "[SM] %t.", shouldRPS[client] ? "Player will cheat" : "Player will play fair", name);
		LogAction(client, client, "\"%L\" toggled RPS cheat for \"%L\"", client, client);
		
		return Plugin_Handled;
	}
	
	char pattern[32];
	GetCmdArg(1, pattern, sizeof(pattern));
	
	int targets[MAXPLAYERS];
	char target_name[32];
	bool tn_is_ml;
	int count = ProcessTargetString(pattern, client, targets, MAXPLAYERS, COMMAND_FILTER_CONNECTED, target_name, sizeof(target_name), tn_is_ml);
	if (count <= 0)
	{
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}
	
	for (int i = 0; i < count; i++)
	{
		shouldRPS[targets[i]] = !shouldRPS[targets[i]];
		LogAction(client, targets[i], "\"%L\" toggled RPS cheat for \"%L\"", client, targets[i]);
	}
	
	if (count == 1)
	{
		char name[32];
		GetClientName(targets[0], name, sizeof(name));
		if (IsValidClient(client))
			PrintToChat(client, "[SM] %t.", shouldRPS[targets[0]] ? "Player will cheat" : "Player will play fair", name);
		else
			ReplyToCommand(client, "[SM] %t.", shouldRPS[targets[0]] ? "Player will cheat" : "Player will play fair", name);
	}
	else
	{
		if (IsValidClient(client))
			PrintToChat(client, "[SM] %t.", "Toggled cheat for players", target_name);
		else
			ReplyToCommand(client, "[SM] %t.", "Toggled cheat for players", target_name);
	}
	
	return Plugin_Handled;
}

#if defined LIGHT_VERSION
stock int GetClientFromCBaseEntity(Address pointer)
{
	return SDKCall(callENTINDEX, pointer);
}
#else
stock int GetClientFromEHANDLE(EHANDLE handle)
{
	return handle & EHANDLE_INDEX;
}

stock int GetClientSerialFromEHANDLE(EHANDLE handle)
{
	return handle >> EHANDLE_BITS;
}

stock EHANDLE GetClientEHANDLE(int client)
{
	/*
	if (!IsValidClient(client))
		return 0;
	
	return GetClientSerial(client) << EHANDLE_BITS | client;
	*/
	
	// The first bit seems to not be set in real EHANDLE, get rid of it
	return view_as<EHANDLE>(EntIndexToEntRef(client) & ((1 << (EHANDLE_SIZE - 1)) - 1));
}
#endif

/*
stock void PrintToRootAdmins(const char[] string, any ...)
{
	int length = strlen(string) + 255;
	char[] formattedString = new char[length];
	VFormat(formattedString, length, string, 2);
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && CheckCommandAccess(i, "sm_access_root", ADMFLAG_ROOT, true))
			PrintToChat(i, formattedString);
	}
}
*/

stock bool IsValidClient(int client)
{
	if (client <= 0 || client > MaxClients)
		return false;

	if (!IsClientConnected(client) || !IsClientInGame(client))
		return false;
	
	if (IsClientSourceTV(client) || IsClientReplay(client))
		return false;
	
	return true;
}