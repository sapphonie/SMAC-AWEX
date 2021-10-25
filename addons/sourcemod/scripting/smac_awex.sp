// SMAC AntiWall EX
// It's like SMAC Wallhack, but not as crusty
// Modded by Sappho.IO

#pragma semicolon 1

/* SM Includes */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#undef REQUIRE_PLUGIN
#include <smac_stocks>

int g_iMaxTraces;

int g_iDownloadTable = INVALID_STRING_TABLE;
Handle g_hIgnoreSounds = INVALID_HANDLE;

int g_iPVSCache[MAXPLAYERS+1][MAXPLAYERS+1];
int g_iPVSSoundCache[MAXPLAYERS+1][MAXPLAYERS+1];
bool g_bIsVisible[MAXPLAYERS+1][MAXPLAYERS+1];
bool g_bIsObserver[MAXPLAYERS+1];
bool g_bIsFake[MAXPLAYERS+1];
bool g_bProcess[MAXPLAYERS+1];
bool g_bIgnore[MAXPLAYERS+1];
bool g_bForceIgnore[MAXPLAYERS+1];

int g_iWeaponOwner[MAX_EDICTS];
int g_iTeam[MAXPLAYERS+1];
float g_vMins[MAXPLAYERS+1][3];
float g_vMaxs[MAXPLAYERS+1][3];
float g_vAbsCentre[MAXPLAYERS+1][3];
float g_vEyePos[MAXPLAYERS+1][3];
float g_vEyeAngles[MAXPLAYERS+1][3];

int g_iTotalThreads = 1, g_iCurrentThread = 1, g_iThread[MAXPLAYERS+1] = { 1, ... };
int g_iCacheTicks, g_iTraceCount;
int g_iTickCount, g_iCmdTickCount[MAXPLAYERS+1];


public void OnPluginStart()
{
    // Convars.
    ConVar hCvar = null;


    hCvar = CreateConVar("smac_wallhack_maxtraces", "1280", "Max amount of traces that can be executed in one tick.", 0, true, 1.0);
    OnMaxTracesChanged(hCvar, "", "");
    HookConVarChange(hCvar, OnMaxTracesChanged);



    g_iDownloadTable = FindStringTable("downloadables");
    g_iCacheTicks = TIME_TO_TICK(0.75);

    RequireFeature(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS, "This module requires a newer version of SourceMod.");

    for (int i = 0; i < sizeof(g_bIsVisible); i++)
    {
        for (int j = 0; j < sizeof(g_bIsVisible[]); j++)
        {
            g_bIsVisible[i][j] = true;
        }
    }

    // Default sounds to ignore in sound hook.
    g_hIgnoreSounds = CreateTrie();
    SetTrieValue(g_hIgnoreSounds, "buttons/button14.wav", 1);
    SetTrieValue(g_hIgnoreSounds, "buttons/combine_button7.wav", 1);

    Wallhack_Enable();
}



public void OnConfigsExecuted()
{
    // Ignore all sounds in the download table.
    if (g_iDownloadTable == INVALID_STRING_TABLE)
    {
        return;
    }

    char sBuffer[PLATFORM_MAX_PATH];
    int iMaxStrings = GetStringTableNumStrings(g_iDownloadTable);

    for (int i = 0; i < iMaxStrings; i++)
    {
        ReadStringTable(g_iDownloadTable, i, sBuffer, sizeof(sBuffer));

        if (strncmp(sBuffer, "sound", 5) == 0)
        {
            SetTrieValue(g_hIgnoreSounds, sBuffer[6], 1);
        }
    }
}

public void OnClientPutInServer(int client)
{
    Wallhack_Hook(client);
    Wallhack_UpdateClientCache(client);
}

public void OnClientDisconnect(int client)
{
    // Stop checking clients right before they disconnect.
    g_bIsObserver[client] = false;
    g_bProcess[client] = false;
    g_bIgnore[client] = false;
    g_bForceIgnore[client] = false;
}

public void OnClientDisconnect_Post(int client)
{
    // Clear cache on post to ensure it's not updated again.
    for (int i = 0; i < sizeof(g_iPVSCache); i++)
    {
        g_iPVSCache[i][client] = 0;
        g_iPVSSoundCache[i][client] = 0;
        g_bIsVisible[i][client] = true;
    }
}

public Action Event_PlayerStateChanged(Event event, const char[] name, bool dontBroadcast)
{
    // Not all data has been updated at this time. Wait until the next tick to update cache.
    CreateTimer(0.001, Timer_PlayerStateChanged, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PlayerStateChanged(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (IS_CLIENT(client) && IsClientInGame(client))
    {
        Wallhack_UpdateClientCache(client);
    }

    return Plugin_Stop;
}

void Wallhack_UpdateClientCache(int client)
{
    g_iTeam[client] = GetClientTeam(client);
    g_bIsObserver[client] = IsClientObserver(client);
    g_bIsFake[client] = IsFakeClient(client);
    g_bProcess[client] = IsPlayerAlive(client);

    // Clients that should not be tested for visibility.
    g_bIgnore[client] = g_bForceIgnore[client];
}



public void OnMaxTracesChanged(ConVar convar, char[] oldValue, char[] newValue)
{
    g_iMaxTraces = GetConVarInt(convar);
}

void Wallhack_Enable()
{

    HookEvent("player_spawn", Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_team", Event_PlayerStateChanged, EventHookMode_Post);


    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            Wallhack_Hook(i);
            Wallhack_UpdateClientCache(i);
        }
    }

    int maxEdicts = GetEntityCount();
    for (int i = MaxClients + 1; i < maxEdicts; i++)
    {
        if (IsValidEdict(i))
        {
            int owner = GetEntPropEnt(i, Prop_Data, "m_hOwnerEntity");

            if (IS_CLIENT(owner))
            {
                g_iWeaponOwner[i] = owner;
            }
        }
    }
}

/**
 * Hooks
 */
void Wallhack_Hook(int client)
{
    SDKHook(client, SDKHook_SetTransmit, Hook_SetTransmit);
}


public Action Hook_NormalSound(int clients[MAXPLAYERS], int& numClients, char sample[PLATFORM_MAX_PATH],
                            int& entity, int& channel, float& volume, int& level, int& pitch, int& flags,
                            char soundEntry[PLATFORM_MAX_PATH], int& seed)
{
    /* Emit sounds to clients who aren't being transmitted the entity. */
    int dummy;

    if (!entity || !IsValidEdict(entity) || GetTrieValue(g_hIgnoreSounds, sample, dummy))
    {
        return Plugin_Continue;
    }

    int iOwner = (entity > MaxClients) ? g_iWeaponOwner[entity] : entity;

    if (!IS_CLIENT(iOwner))
    {
        return Plugin_Continue;
    }




    int[] newClients = new int[MaxClients];
    bool[] bAddClient = new bool[view_as<int>(MaxClients+1)];
    int newTotal;

    // Check clients that get the sound by default.
    for (int i = 0; i < numClients; i++)
    {
        int client = clients[i];

        // SourceMod and game engine don't always agree.
        if (!IsClientInGame(client))
        {
            continue;
        }

        // These clients need the entity information for prediction.
        if (client == iOwner)
        {
            newClients[newTotal++] = client;
            continue;
        }

        // Body sounds (footsteps, jumping, etc) will be kept strict to the PVS because they're quiet anyway.
        // Weapons can be heard from larger distances.
        if (channel == SNDCHAN_BODY)
        {
            bAddClient[client] = g_bIsVisible[iOwner][client];
        }
        else
        {
            bAddClient[client] = true;
        }
    }

    // Emit with entity information.
    if (newTotal)
    {
        EmitSound(newClients, newTotal, sample, entity, channel, level, flags, volume, pitch);
        newTotal = 0;
    }

    // Determine which clients still need this sound.
    for (int i = 1; i <= MaxClients; i++)
    {
        // A client in the PVS will be expected to predict the sound even if we're blocking transmit.
        if (bAddClient[i] || ((g_bProcess[i] || g_bIsObserver[i]) && !g_bIsVisible[iOwner][i] && g_iPVSSoundCache[iOwner][i] > g_iTickCount))
        {
            newClients[newTotal++] = i;
        }
    }

    // Emit without entity information.
    if (newTotal)
    {
        float vOrigin[3];
        GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", vOrigin);
        EmitSound(newClients, newTotal, sample, SOUND_FROM_WORLD, channel, level, flags, volume, pitch, _, vOrigin);
    }

    return Plugin_Stop;
}





/**
 * OnGameFrame
 */
public void OnGameFrame()
{
    g_iTickCount = GetGameTickCount();

    // Increment to next thread.
    if (++g_iCurrentThread > g_iTotalThreads)
    {
        g_iCurrentThread = 1;

        // Reassign threads
        if (g_iTraceCount)
        {
            // Calculate total needed threads for the next pass.
            g_iTotalThreads = g_iTraceCount / g_iMaxTraces + 1;

            // Assign each client to a thread.
            int iThreadAssign = 1;

            for (int i = 1; i <= MaxClients; i++)
            {
                if (g_bProcess[i])
                {
                    g_iThread[i] = iThreadAssign;

                    if (++iThreadAssign > g_iTotalThreads)
                    {
                        iThreadAssign = 1;
                    }
                }
            }

            g_iTraceCount = 0;
        }
    }

}

public Action Hook_SetTransmit(int entity,int client)
{
    if (entity == client)
    {
        return Plugin_Continue;
    }

    static int iLastChecked[MAXPLAYERS+1][MAXPLAYERS+1];


    // Data is transmitted multiple times per tick. Only run calculations once.
    if (iLastChecked[entity][client] == g_iTickCount)
    {
        return g_bIsVisible[entity][client] ? Plugin_Continue : Plugin_Handled;
    }

    iLastChecked[entity][client] = g_iTickCount;

    if (g_bProcess[client])
    {
        if (g_bProcess[entity]  && !g_bIgnore[client])
        {
            if (g_iThread[client] == g_iCurrentThread)
            {
                // Grab client data before running traces.
                UpdateClientData(client);
                UpdateClientData(entity);

                if (IsAbleToSee(entity, client))
                {
                    g_bIsVisible[entity][client] = true;
                    g_iPVSCache[entity][client] = g_iTickCount + g_iCacheTicks;
                }
                else if (g_iTickCount > g_iPVSCache[entity][client])
                {
                    g_bIsVisible[entity][client] = false;
                }
            }
        }
        else
        {
            g_bIsVisible[entity][client] = true;
        }
    }
    else if (g_bProcess[entity] && GetClientObserverMode(client) == OBS_MODE_IN_EYE)
    {
        // Observers in first-person will clone the visiblity of their target.
        int iTarget = GetClientObserverTarget(client);

        if (IS_CLIENT(iTarget))
        {
            g_bIsVisible[entity][client] = g_bIsVisible[entity][iTarget];
        }
        else
        {
            g_bIsVisible[entity][client] = true;
        }
    }
    else
    {
        g_bIsVisible[entity][client] = true;
    }

    return g_bIsVisible[entity][client] ? Plugin_Continue : Plugin_Handled;
}


public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
    if (!g_bProcess[client])
    {
        return Plugin_Continue;
    }

    g_vEyeAngles[client] = angles;
    g_iCmdTickCount[client] = tickcount;


    /* TODO: DO WE ONLY NEED TO DO THIS FOR THE HEAVY MINIGUN??? */

    //Force player's items to not transmit
    for (int slot = 0; slot <= 10; slot++)
    {
        int item = GetPlayerWeaponSlot(client, slot);
        if (IsValidEntity(item))
        {
            SetEdictFlags(item, (GetEdictFlags(item) & ~FL_EDICT_ALWAYS));
        }
    }
    //Force disguise weapon to not transmit
    int disguiseWeapon = GetEntPropEnt(client, Prop_Send, "m_hDisguiseWeapon");
    if (IsValidEntity(disguiseWeapon))
    {
        SetEdictFlags(disguiseWeapon, (GetEdictFlags(disguiseWeapon) & ~FL_EDICT_ALWAYS));
    }


    return Plugin_Continue;
}

void UpdateClientData(int client)
{
    /* Only update client data once per tick. */
    static int iLastCached[MAXPLAYERS+1];

    if (iLastCached[client] == g_iTickCount)
    {
        return;
    }

    iLastCached[client] = g_iTickCount;

    GetClientMins(client, g_vMins[client]);
    GetClientMaxs(client, g_vMaxs[client]);
    GetClientAbsOrigin(client, g_vAbsCentre[client]);
    GetClientEyePosition(client, g_vEyePos[client]);

    // Adjust vectors relative to the model's absolute centre.
    g_vMaxs[client][2] /= 2.0;
    g_vMins[client][2] -= g_vMaxs[client][2];
    g_vAbsCentre[client][2] += g_vMaxs[client][2];

    // Adjust vectors based on the clients velocity.
    float vVelocity[3];
    GetClientAbsVelocity(client, vVelocity);

    if (!IsVectorZero(vVelocity))
    {
        // Lag compensation.
        int iTargetTick;

        if (g_bIsFake[client])
        {
            iTargetTick = g_iTickCount - 1;
        }
        else
        {
            // Based on CLagCompensationManager::StartLagCompensation.
            float fCorrect = GetClientLatency(client, NetFlow_Outgoing);
            int iLerpTicks = TIME_TO_TICK(GetEntPropFloat(client, Prop_Data, "m_fLerpTime"));

            // Assume sv_maxunlag == 1.0f seconds.
            fCorrect += TICK_TO_TIME(iLerpTicks);
            fCorrect = ClampValue(fCorrect, 0.0, 1.0);

            iTargetTick = g_iCmdTickCount[client] - iLerpTicks;

            if (FloatAbs(fCorrect - TICK_TO_TIME(g_iTickCount - iTargetTick)) > 0.2)
            {
                // Difference between cmd time and latency is too big > 200ms.
                // Use time correction based on latency.
                iTargetTick = g_iTickCount - TIME_TO_TICK(fCorrect);
            }
        }

        // Use velocity before it's modified.
        float vTemp[3];
        vTemp[0] = FloatAbs(vVelocity[0]) * 0.01;
        vTemp[1] = FloatAbs(vVelocity[1]) * 0.01;
        vTemp[2] = FloatAbs(vVelocity[2]) * 0.01;

        // Calculate predicted positions for the next frame.
        float vPredicted[3];
        ScaleVector(vVelocity, TICK_TO_TIME((g_iTickCount - iTargetTick) * g_iTotalThreads));
        AddVectors(g_vAbsCentre[client], vVelocity, vPredicted);

        // Make sure the predicted position is still inside the world.
        TR_TraceHullFilter(vPredicted, vPredicted, view_as<float>({-5.0, -5.0, -5.0}), view_as<float>({5.0, 5.0, 5.0}), MASK_PLAYERSOLID_BRUSHONLY, Filter_WorldOnly);
        g_iTraceCount++;

        if (!TR_DidHit())
        {
            g_vAbsCentre[client] = vPredicted;
            AddVectors(g_vEyePos[client], vVelocity, g_vEyePos[client]);
        }

        // Expand the mins/maxs to help smooth during fast movement.
        if (vTemp[0] > 1.0)
        {
            g_vMins[client][0] *= vTemp[0];
            g_vMaxs[client][0] *= vTemp[0];
        }
        if (vTemp[1] > 1.0)
        {
            g_vMins[client][1] *= vTemp[1];
            g_vMaxs[client][1] *= vTemp[1];
        }
        if (vTemp[2] > 1.0)
        {
            g_vMins[client][2] *= vTemp[2];
            g_vMaxs[client][2] *= vTemp[2];
        }
    }
}

/**
 * Calculations
 */
bool IsAbleToSee(int entity,int client)
{

    // Skip all traces if the player isn't within the field of view.
    if (IsInFieldOfView(g_vEyePos[client], g_vEyeAngles[client], g_vAbsCentre[entity]))
    {
        // Check if centre is visible.
        if (IsPointVisible(g_vEyePos[client], g_vAbsCentre[entity]))
        {
            return true;
        }

        // Check outer 4 corners of player.
        if (IsRectangleVisible(g_vEyePos[client], g_vAbsCentre[entity], g_vMins[entity], g_vMaxs[entity], 1.50))
        {
            return true;
        }

        // Check inner 4 corners of player.
        if (IsRectangleVisible(g_vEyePos[client], g_vAbsCentre[entity], g_vMins[entity], g_vMaxs[entity], 0.50))
        {
            return true;
        }
    }

    return false;
}

// some comments would be helpful here silence0
bool IsInFieldOfView(const float start[3], const float angles[3], const float end[3])
{
    float normal[3];
    float plane[3];

    GetAngleVectors(angles, normal, NULL_VECTOR, NULL_VECTOR);
    SubtractVectors(end, start, plane);
    NormalizeVector(plane, plane);

    return GetVectorDotProduct(plane, normal) > 0.0; // Cosine(Deg2Rad(179.9 / 2.0))
}

public bool Filter_WorldOnly(int entity,int mask)
{
    return false;
}

public bool Filter_NoPlayers(int entity,int mask)
{
    return entity > MaxClients && !IS_CLIENT(GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity"));
}

bool IsPointVisible(const float start[3], const float end[3])
{

    TR_TraceRayFilter(start, end, MASK_VISIBLE, RayType_EndPoint, Filter_WorldOnly);

    g_iTraceCount++;

    if (TR_GetFraction() == 1.0)
    {
        return true;
    }
    return false;
}


bool IsRectangleVisible(const float start[3], const float end[3], const float mins[3], const float maxs[3], float scale=1.0)
{
    float ZpozOffset = maxs[2];
    float ZnegOffset = mins[2];
    float WideOffset = ((maxs[0] - mins[0]) + (maxs[1] - mins[1])) / 4.0;

    // This rectangle is just a point!
    if (ZpozOffset == 0.0 && ZnegOffset == 0.0 && WideOffset == 0.0)
    {
        return IsPointVisible(start, end);
    }

    // Adjust to scale.
    ZpozOffset *= scale;
    ZnegOffset *= scale;
    WideOffset *= scale;

    // Prepare rotation matrix.
    float angles[3], fwd[3], right[3];

    SubtractVectors(start, end, fwd);
    NormalizeVector(fwd, fwd);

    GetVectorAngles(fwd, angles);
    GetAngleVectors(angles, fwd, right, NULL_VECTOR);

    float vRectangle[4][3], vTemp[3];

    // If the player is on the same level as us, we can optimize by only rotating on the z-axis.
    if (FloatAbs(fwd[2]) <= 0.7071)
    {
        ScaleVector(right, WideOffset);

        // Corner 1, 2
        vTemp = end;
        vTemp[2] += ZpozOffset;
        AddVectors(vTemp, right, vRectangle[0]);
        SubtractVectors(vTemp, right, vRectangle[1]);

        // Corner 3, 4
        vTemp = end;
        vTemp[2] += ZnegOffset;
        AddVectors(vTemp, right, vRectangle[2]);
        SubtractVectors(vTemp, right, vRectangle[3]);

    }
    else if (fwd[2] > 0.0) // Player is below us.
    {
        fwd[2] = 0.0;
        NormalizeVector(fwd, fwd);

        ScaleVector(fwd, scale);
        ScaleVector(fwd, WideOffset);
        ScaleVector(right, WideOffset);

        // Corner 1
        vTemp = end;
        vTemp[2] += ZpozOffset;
        AddVectors(vTemp, right, vTemp);
        SubtractVectors(vTemp, fwd, vRectangle[0]);

        // Corner 2
        vTemp = end;
        vTemp[2] += ZpozOffset;
        SubtractVectors(vTemp, right, vTemp);
        SubtractVectors(vTemp, fwd, vRectangle[1]);

        // Corner 3
        vTemp = end;
        vTemp[2] += ZnegOffset;
        AddVectors(vTemp, right, vTemp);
        AddVectors(vTemp, fwd, vRectangle[2]);

        // Corner 4
        vTemp = end;
        vTemp[2] += ZnegOffset;
        SubtractVectors(vTemp, right, vTemp);
        AddVectors(vTemp, fwd, vRectangle[3]);
    }
    else // Player is above us.
    {
        fwd[2] = 0.0;
        NormalizeVector(fwd, fwd);

        ScaleVector(fwd, scale);
        ScaleVector(fwd, WideOffset);
        ScaleVector(right, WideOffset);

        // Corner 1
        vTemp = end;
        vTemp[2] += ZpozOffset;
        AddVectors(vTemp, right, vTemp);
        AddVectors(vTemp, fwd, vRectangle[0]);

        // Corner 2
        vTemp = end;
        vTemp[2] += ZpozOffset;
        SubtractVectors(vTemp, right, vTemp);
        AddVectors(vTemp, fwd, vRectangle[1]);

        // Corner 3
        vTemp = end;
        vTemp[2] += ZnegOffset;
        AddVectors(vTemp, right, vTemp);
        SubtractVectors(vTemp, fwd, vRectangle[2]);

        // Corner 4
        vTemp = end;
        vTemp[2] += ZnegOffset;
        SubtractVectors(vTemp, right, vTemp);
        SubtractVectors(vTemp, fwd, vRectangle[3]);
    }

    // Run traces on all corners.
    for (int i = 0; i < 4; i++)
    {
        if (IsPointVisible(start, vRectangle[i]))
        {
            return true;
        }
    }

    return false;
}




