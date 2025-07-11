#pragma semicolon 1

#include <sourcemod>
#include <sdktools>

#define MAX_TRACKS 64
#define MUSIC_CHANNEL 6
#define VOTESKIP_DURATION 10.0
#define TRACK_BUFFER 0.5

// Global Variables
char g_TrackList[MAX_TRACKS][PLATFORM_MAX_PATH];
int g_TrackDurations[MAX_TRACKS];
char g_TrackNames[MAX_TRACKS][PLATFORM_MAX_PATH];
int g_TrackCount = 0;

int g_CurrentTrack = -1;
bool g_IsPlaying = false;
bool g_IsInPlaybackTransition = false;
Handle g_MusicTimer = INVALID_HANDLE;
int g_MusicTimerID = 0; // Unique ID for timers

bool g_VoteInProgress = false;
int g_YesVotes = 0;
ArrayList g_VotedClients;
ArrayList g_TrackVoteCooldowns;
float g_ClientVolumes[MAXPLAYERS + 1]; // Stores individual client volumes

float g_TrackStartTime; // Stores GetGameTime() when current track started
float g_NullVectorFloat[3] = {0.0, 0.0, 0.0}; // Used for non-spatialized sounds

bool g_TracksLoadedForMap = false; // Flag to ensure tracks are loaded only once per map
int g_PluginInstanceID = 0; // Unique ID for plugin instance/map changes

// Structure to pass data to the volume fade timer.
enum struct VolumeFadeData
{
    int client;
    float targetVolume;
    float trackStartTime;
    int trackIndex;
    int timerID;
    int pluginInstanceID;
}

// --- FORWARD DECLARATIONS ---
forward Action Cmd_MusicPlay(int client, int args);
forward Action Cmd_MusicSkip(int client, int args);
forward Action Cmd_MusicStop(int client, int args);
forward Action Cmd_MusicHelp(int client, int args);
forward Action Cmd_VoteSkip(int client, int args);
forward Action Cmd_MusicVolume(int client, int args);
forward Action Cmd_MusicSettings(int client, int args);
forward Action Cmd_MusicList(int client, int args);
forward Action Cmd_MusicSync(int client, int args);

forward int Menu_MusicHelp(Menu menu, MenuAction action, int client, int item);

forward Action Timer_InitialLoadTracks(Handle timer);
forward Action Timer_DelayedLoadTracks(Handle timer);
forward Action Timer_RetryLoadTracks(Handle timer);
forward Action Timer_DelayedAutoplay(Handle timer, any data);
forward Action Timer_AdvertiseHelp(Handle timer);
forward Action Timer_InitiateVolumeFade(Handle timer, any data);
forward Action Timer_VolumeFadeStep2(Handle timer, any data);
forward Action Timer_FinalFadeApply(Handle timer, any data);
forward Action Timer_VoteSkipEnd(Handle timer);
forward Action Timer_NextTrack(Handle timer, any data);

forward void DelayedLoadTracks();
forward bool PlayTrack(int index, const char[] source);
forward void StopTrackForAll(int index);
forward bool MusicPlugin_IsAuthorized(int client);
forward bool LoadTracks();

public Action Cmd_MusicSettings(int client, int args)
{
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSettings] Client %N (Index: %d) requested settings.", client, client);
    PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🎧 Your Volume: %.2f", g_ClientVolumes[client]);
    return Plugin_Handled;
}

public void OnPluginStart()
{
    PrintToServer("[MusicPlugin Debug] [OnPluginStart] Plugin starting. Registering commands...");
    RegConsoleCmd("sm_musicplay", Cmd_MusicPlay);
    RegConsoleCmd("sm_musicskip", Cmd_MusicSkip);
    RegConsoleCmd("sm_musicstop", Cmd_MusicStop);
    RegConsoleCmd("sm_musichelp", Cmd_MusicHelp);
    RegConsoleCmd("sm_voteskip", Cmd_VoteSkip);
    RegConsoleCmd("sm_musicvol", Cmd_MusicVolume);
    RegConsoleCmd("sm_musicsettings", Cmd_MusicSettings);
    RegConsoleCmd("sm_musiclist", Cmd_MusicList);
    RegConsoleCmd("sm_musicsync", Cmd_MusicSync);
    PrintToServer("[MusicPlugin Debug] [OnPluginStart] Commands registered.");

    g_VotedClients = new ArrayList();
    g_TrackVoteCooldowns = new ArrayList();
    PrintToServer("[MusicPlugin Debug] [OnPluginStart] ArrayLists for client votes and cooldowns initialized.");

    CreateTimer(120.0, Timer_AdvertiseHelp, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    PrintToServer("[MusicPlugin Debug] [OnPluginStart] Advertise help timer created (120s repeat).");

    g_TracksLoadedForMap = false;
    PrintToServer("[MusicPlugin Debug] [OnPluginStart] Initialized g_TracksLoadedForMap to false.");

    g_PluginInstanceID++;
    PrintToServer("[MusicPlugin Debug] [OnPluginStart] Plugin instance ID: %d.", g_PluginInstanceID);

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/musiclist.txt");
    if (!FileExists(path))
    {
        LogError("[MusicPlugin] ❌ musiclist.txt not found at %s on plugin start. Tracks will not load until fixed.", path);
    }
    else
    {
        File f = OpenFile(path, "r");
        if (f == null)
        {
            LogError("[MusicPlugin] ❌ Failed to open musiclist.txt at %s on plugin start. Check permissions.", path);
        }
        else
        {
            CloseHandle(f);
            PrintToServer("[MusicPlugin Debug] [OnPluginStart] musiclist.txt found and readable at %s.", path);
        }
    }

    CreateTimer(5.0, Timer_InitialLoadTracks, _);
    PrintToServer("[MusicPlugin] ✅ OnPluginStart() - Plugin initialized.");
}

public void OnClientPutInServer(int client)
{
    PrintToServer("[MusicPlugin Debug] [OnClientPutInServer] Client %N (Index: %d) connected.", client, client);
    g_ClientVolumes[client] = 0.03; // Default volume for new clients
    PrintToServer("[MusicPlugin Debug] [OnClientPutInServer] Client %N (Index: %d) volume initialized to %.2f. (Confirmed assigned value)", client, client, g_ClientVolumes[client]);

    if (g_IsPlaying && g_CurrentTrack != -1)
    {
        float current_game_time = GetGameTime();
        float elapsed_time = current_game_time - g_TrackStartTime;

        if (elapsed_time < 0.0)
        {
            PrintToServer("[MusicPlugin Debug] [OnClientPutInServer] WARNING: Calculated elapsed time %.3f was negative. Forcing to 0.0.", elapsed_time);
            elapsed_time = 0.0;
        }
        else if (elapsed_time > float(g_TrackDurations[g_CurrentTrack]))
        {
            PrintToServer("[MusicPlugin Debug] [OnClientPutInServer] WARNING: Calculated elapsed time %.3f exceeded track duration %d. Capping to duration.", elapsed_time, g_TrackDurations[g_CurrentTrack]);
            elapsed_time = float(g_TrackDurations[g_CurrentTrack]);
        }

        PrintToServer("[MusicPlugin Debug] [OnClientPutInServer] Emitting current track '%s' to new client %N (Index: %d) at timestamp %.3f and applied volume %.2f.", g_TrackNames[g_CurrentTrack], client, client, elapsed_time, g_ClientVolumes[client]);
        EmitSoundToClient(
            client,
            g_TrackList[g_CurrentTrack],
            client,
            MUSIC_CHANNEL,
            SNDLEVEL_NORMAL,
            SND_NOFLAGS,
            g_ClientVolumes[client],
            100,
            -1,
            g_NullVectorFloat,
            g_NullVectorFloat,
            false,
            elapsed_time
        );
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ▶ Now Playing: \x03%s", g_TrackNames[g_CurrentTrack]);
    }
}

public void OnClientDisconnect(int client)
{
    PrintToServer("[MusicPlugin Debug] [OnClientDisconnect] Client %N (Index: %d) disconnected. Resetting volume data.", client, client);
    g_ClientVolumes[client] = 0.03;

    int index = g_VotedClients.FindValue(client);
    if (index != -1)
    {
        g_VotedClients.Erase(index);
        PrintToServer("[MusicPlugin Debug] [OnClientDisconnect] Client %N (Index: %d) removed from g_VotedClients.", client, client);
    }
    index = g_TrackVoteCooldowns.FindValue(client);
    if (index != -1)
    {
        g_TrackVoteCooldowns.Erase(index);
        PrintToServer("[MusicPlugin Debug] [OnClientDisconnect] Client %N (Index: %d) removed from g_TrackVoteCooldowns.", client, client);
    }
}

public void OnMapStart()
{
    PrintToServer("[MusicPlugin Debug] [OnMapStart] >>> OnMapStart hook triggered! <<<");
    PrintToServer("[MusicPlugin Debug] [OnMapStart] Map started. Resetting plugin state...");
    PrintToServer("[MusicPlugin] 🌍 OnMapStart() - Resetting plugin state.");

    g_TrackCount = 0;
    g_CurrentTrack = -1;
    g_IsPlaying = false;
    g_IsInPlaybackTransition = false;
    g_VoteInProgress = false;
    g_YesVotes = 0;
    g_TrackStartTime = 0.0;
    g_TracksLoadedForMap = false;
    PrintToServer("[MusicPlugin Debug] [OnMapStart] g_TracksLoadedForMap reset to false for new map.");

    if (g_VotedClients != null)
    {
        g_VotedClients.Clear();
        PrintToServer("[MusicPlugin Debug] [OnMapStart] g_VotedClients ArrayList cleared.");
    }
    if (g_TrackVoteCooldowns != null)
    {
        g_TrackVoteCooldowns.Clear();
        PrintToServer("[MusicPlugin Debug] [OnMapStart] g_TrackVoteCooldowns ArrayList cleared.");
    }

    if (g_MusicTimer != INVALID_HANDLE)
    {
        PrintToServer("[MusicPlugin Debug] [OnMapStart] Killing existing music timer (ID: %d).", g_MusicTimerID);
        KillTimer(g_MusicTimer);
        g_MusicTimer = INVALID_HANDLE;
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [OnMapStart] No active music timer to kill.");
    }

    g_PluginInstanceID++;
    PrintToServer("[MusicPlugin Debug] [OnMapStart] Plugin instance ID incremented to: %d.", g_PluginInstanceID);

    CreateTimer(1.0, Timer_DelayedLoadTracks, _);
    PrintToServer("[MusicPlugin Debug] [OnMapStart] Plugin state reset complete. Track loading scheduled.");
}

public void OnRoundStart()
{
    PrintToServer("[MusicPlugin Debug] [OnRoundStart] Round started. Tracks are loaded on OnMapStart.");
}

public Action Timer_InitialLoadTracks(Handle timer)
{
    PrintToServer("[MusicPlugin Debug] [Timer_InitialLoadTracks] Attempting initial track load...");
    DelayedLoadTracks();
    return Plugin_Stop;
}

public Action Timer_DelayedLoadTracks(Handle timer)
{
    PrintToServer("[MusicPlugin Debug] [Timer_DelayedLoadTracks] Timer triggered. Calling DelayedLoadTracks().");
    DelayedLoadTracks();
    return Plugin_Stop;
}

public void DelayedLoadTracks()
{
    PrintToServer("[MusicPlugin Debug] [DelayedLoadTracks] Attempting to load tracks...");
    if (LoadTracks())
    {
        PrintToServer("[MusicPlugin Debug] [DelayedLoadTracks] Tracks loaded successfully. Count: %d.", g_TrackCount);
        if (g_TrackCount > 0)
        {
            PrintToServer("[MusicPlugin Debug] [DelayedLoadTracks] Initiating autoplay after 1.0s delay.", g_TrackCount);
            CreateTimer(1.0, Timer_DelayedAutoplay, g_PluginInstanceID);
        }
        else
        {
            PrintToServer("[MusicPlugin Debug] [DelayedLoadTracks] No tracks found after successful load. Autoplay skipped.");
        }
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [DelayedLoadTracks] Track load failed. Scheduling retry in 5 seconds.");
        CreateTimer(5.0, Timer_RetryLoadTracks, _);
    }
}

public Action Timer_RetryLoadTracks(Handle timer)
{
    PrintToServer("[MusicPlugin Debug] [Timer_RetryLoadTracks] Attempting to retry track load...");
    if (!g_TracksLoadedForMap)
    {
        if (LoadTracks())
        {
            PrintToServer("[MusicPlugin] ✅ Tracks loaded successfully after retry. Count: %d.", g_TrackCount);
            if (g_TrackCount > 0)
            {
                PrintToServer("[MusicPlugin Debug] [Timer_RetryLoadTracks] Initiating autoplay after 1.0s delay.");
                CreateTimer(1.0, Timer_DelayedAutoplay, g_PluginInstanceID);
            }
        }
        else
        {
            float retryDelay = 5.0;
            PrintToServer("[MusicPlugin Debug] [Timer_RetryLoadTracks] Track load failed. Scheduling another retry in %.1f seconds.", retryDelay);
            CreateTimer(retryDelay, Timer_RetryLoadTracks, _);
        }
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [Timer_RetryLoadTracks] Tracks already loaded for this map. No further retries needed.");
    }
    return Plugin_Stop;
}

public Action Cmd_MusicPlay(int client, int args)
{
    PrintToServer("[MusicPlugin] ⏯ Cmd_MusicPlay() by %N", client);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicPlay] Client %N (Index: %d) attempting to play music.", client, client);
    if (!MusicPlugin_IsAuthorized(client))
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🚫 You do not have permission to use this command.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicPlay] Client %N (Index: %d) unauthorized. Command denied.", client, client);
        return Plugin_Handled;
    }
    if (g_IsPlaying || g_IsInPlaybackTransition)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ℹ️ Music is already playing or transitioning.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicPlay] Music already playing or transitioning (IsPlaying: %b, InTransition: %b). Command denied.", g_IsPlaying, g_IsInPlaybackTransition);
        return Plugin_Handled;
    }
    if (g_TrackCount == 0)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ❌ No music tracks loaded. Check musiclist.txt.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicPlay] No music tracks loaded. Command denied.", client, client);
        return Plugin_Handled;
    }
    PlayTrack(0, "Cmd_MusicPlay");
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicPlay] Calling PlayTrack(0) to start first track.");
    return Plugin_Handled;
}

public Action Cmd_MusicSkip(int client, int args)
{
    PrintToServer("[MusicPlugin] ⏭ Cmd_MusicSkip() by %N", client);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSkip] Client %N (Index: %d) attempting to skip current music.", client, client);
    if (!MusicPlugin_IsAuthorized(client))
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🚫 You do not have permission to use this command.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSkip] Client %N (Index: %d) unauthorized. Command denied.", client, client);
        return Plugin_Handled;
    }
    if (g_TrackCount == 0)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ❌ No music tracks loaded to skip.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSkip] No music tracks loaded. Command denied.", client, client);
        return Plugin_Handled;
    }
    if (!g_IsPlaying)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ℹ️ No music is currently playing to skip.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSkip] No music currently playing. Command denied.", client, client);
        return Plugin_Handled;
    }

    int next = (g_CurrentTrack + 1) % g_TrackCount;
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSkip] Current track: %d, Next track calculated: %d.", g_CurrentTrack, next);
    PlayTrack(next, "Cmd_MusicSkip");
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSkip] Current track stopped and next track initiated.");
    return Plugin_Handled;
}

public Action Cmd_MusicStop(int client, int args)
{
    PrintToServer("[MusicPlugin] ⏹ Cmd_MusicStop() by %N", client);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicStop] Client %N (Index: %d) attempting to stop music.", client, client);
    if (!MusicPlugin_IsAuthorized(client))
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🚫 You do not have permission to use this command.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicStop] Client %N (Index: %d) unauthorized. Command denied.", client, client);
        return Plugin_Handled;
    }
    if (!g_IsPlaying && !g_IsInPlaybackTransition)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ℹ️ Music is not currently playing.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicStop] Music not playing or transitioning (IsPlaying: %b, InTransition: %b). Command denied.", g_IsPlaying, g_IsInPlaybackTransition);
        return Plugin_Handled;
    }

    StopTrackForAll(g_CurrentTrack);
    g_CurrentTrack = -1;
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicStop] All music stopped. CurrentTrack reset to -1.");
    return Plugin_Handled;
}

public Action Cmd_MusicHelp(int client, int args)
{
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicHelp] Client %N (Index: %d) requested help menu.", client, client);
    if (!IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicHelp] Client %N (Index: %d) not in game. Command denied.", client, client);
        return Plugin_Handled;
    }

    Menu menu = new Menu(Menu_MusicHelp);
    menu.SetTitle("🎵 Music Commands");

    menu.AddItem("voteskip", "Vote to Skip (!voteskip)");
    menu.AddItem("musicvol", "Set Volume (!musicvol)");
    menu.AddItem("musicsettings", "My Settings (!musicsettings)");
    menu.AddItem("musiclist", "List Tracks (!musiclist)");
    menu.AddItem("musicsync", "Resync Music (!musicsync)");

    if (MusicPlugin_IsAuthorized(client))
    {
        menu.AddItem("musicplay", "Start Music (!musicplay)");
        menu.AddItem("musicskip", "Skip Track (!musicskip)");
        menu.AddItem("musicstop", "Stop Music (!musicstop)");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicHelp] Client %N (Index: %d) is authorized, showing admin commands.", client, client);
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicHelp] Client %N (Index: %d) is NOT authorized, showing user commands only.", client, client);
    }

    menu.ExitButton = true;
    menu.Display(client, 15);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicHelp] Music help menu displayed to client %N (Index: %d).", client, client);
    return Plugin_Handled;
}

public int Menu_MusicHelp(Menu menu, MenuAction action, int client, int item)
{
    PrintToServer("[MusicPlugin Debug] [Menu_MusicHelp] Menu callback triggered for client %N (Index: %d), Action: %d, Item: %d.", client, client, action, item);
    if (action == MenuAction_End)
    {
        delete menu;
        PrintToServer("[MusicPlugin Debug] [Menu_MusicHelp] MenuAction_End: Menu deleted.");
    }
    else if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(item, info, sizeof(info));
        PrintToServer("[MusicPlugin Debug] [Menu_MusicHelp] MenuAction_Select: Client %N (Index: %d) selected item '%s'.", client, client, info);
        if (StrEqual(info, "musicplay")) Cmd_MusicPlay(client, 0);
        else if (StrEqual(info, "musicskip")) Cmd_MusicSkip(client, 0);
        else if (StrEqual(info, "musicstop")) Cmd_MusicStop(client, 0);
        else if (StrEqual(info, "voteskip")) Cmd_VoteSkip(client, 0);
        else if (StrEqual(info, "musicvol")) PrintToChat(client, "[MusicPlugin] Type !musicvol mute|low|med|high|value");
        else if (StrEqual(info, "musicsettings")) Cmd_MusicSettings(client, 0);
        else if (StrEqual(info, "musiclist")) Cmd_MusicList(client, 0);
        else if (StrEqual(info, "musicsync")) Cmd_MusicSync(client, 0);
    }
    return 0;
}

public Action Cmd_MusicList(int client, int args)
{
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicList] Client %N (Index: %d) requested music list.", client, client);
    if (!IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicList] Client %N (Index: %d) not in game. Command denied.", client, client);
        return Plugin_Handled;
    }

    if (g_TrackCount == 0)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ❌ No music tracks loaded. Check musiclist.txt.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicList] No music tracks loaded. Command denied.", client, client);
        return Plugin_Handled;
    }

    PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🎶 Loaded Music Tracks:");
    for (int i = 0; i < g_TrackCount; i++)
    {
        PrintToChat(client, "\x01[\x04%d\x01] \x03%s \x01(\x04%ds\x01)", i, g_TrackNames[i], g_TrackDurations[i]);
    }
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicList] Displayed %d tracks to client %N.", g_TrackCount, client);
    return Plugin_Handled;
}

public Action Cmd_MusicSync(int client, int args)
{
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Client %N (Index: %d) requested music resync.", client, client);
    if (!IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Client %N (Index: %d) not in game. Command denied.", client, client);
        return Plugin_Handled;
    }

    if (!g_IsPlaying || g_CurrentTrack == -1)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ℹ️ No music is currently playing to sync.");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] No music playing (IsPlaying: %b, CurrentTrack: %d). Sync command denied.", g_IsPlaying, g_CurrentTrack);
        return Plugin_Handled;
    }

    float current_game_time = GetGameTime();
    float elapsed_time = current_game_time - g_TrackStartTime;

    float client_avg_latency = GetClientAvgLatency(client, NetFlow_Incoming);
    
    if (client_avg_latency < 0.0 || client_avg_latency > 1.0 || (client_avg_latency != client_avg_latency))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] WARNING: Invalid or extreme client latency detected (%.3f) for client %N. Defaulting to 0.0.", client_avg_latency, client);
        client_avg_latency = 0.0;
    }

    elapsed_time += client_avg_latency;
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Client %N (Index: %d) avg latency: %.3f. Adjusted elapsed_time by latency.", client, client, client_avg_latency);

    elapsed_time = RoundToFloor(elapsed_time * 10.0) / 10.0;

    if (elapsed_time < 0.0)
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] WARNING: Calculated elapsed time %.3f was negative. Forcing to 0.0.", elapsed_time);
        elapsed_time = 0.0;
    }
    else if (elapsed_time > float(g_TrackDurations[g_CurrentTrack]))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] WARNING: Calculated elapsed time %.3f exceeded track duration %d. Capping to duration.", elapsed_time, g_TrackDurations[g_CurrentTrack]);
        elapsed_time = float(g_TrackDurations[g_CurrentTrack]);
    }

    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Preparing to StopSound for client %N, track '%s'.", client, g_TrackList[g_CurrentTrack]);
    StopSound(client, MUSIC_CHANNEL, g_TrackList[g_CurrentTrack]);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Stopped sound '%s' for client %N (Index: %d).", g_TrackList[g_CurrentTrack], client, client);

    float currentClientVolume = g_ClientVolumes[client];
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Preparing to EmitSoundToClient for client %N, track '%s', volume %.2f, elapsed %.3f.", client, g_TrackList[g_CurrentTrack], currentClientVolume, elapsed_time);
    EmitSoundToClient(
        client,
        g_TrackList[g_CurrentTrack],
        client,
        MUSIC_CHANNEL,
        SNDLEVEL_NORMAL,
        SND_NOFLAGS,
        currentClientVolume,
        100,
        -1,
        g_NullVectorFloat,
        g_NullVectorFloat,
        false,
        elapsed_time
    );
    PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🔄 Resynced music to \x03%s\x01.", g_TrackNames[g_CurrentTrack]);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Re-emitted track '%s' to client %N (Index: %d) at timestamp %.3f and volume %.2f for resync.", g_TrackNames[g_CurrentTrack], client, client, elapsed_time, g_ClientVolumes[client]);

    DataPack dp_final = new DataPack();
    dp_final.WriteCell(client);
    dp_final.WriteFloat(currentClientVolume);
    CreateTimer(0.1, Timer_FinalFadeApply, dp_final);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicSync] Timer_FinalFadeApply scheduled for 0.1 seconds with new DataPack.");

    return Plugin_Handled;
}

public Action Timer_FinalFadeApply(Handle timer, any data)
{
    DataPack dp = view_as<DataPack>(data);
    dp.Reset();
    int client = dp.ReadCell();
    float targetVolume = dp.ReadFloat();
    delete dp;

    if (!IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [Timer_FinalFadeApply] Client %N (Index: %d) no longer in game. Aborting final fade.", client, client);
        return Plugin_Stop;
    }

    FadeClientVolume(client, targetVolume, 0.0, 0.0, 0.1);
    PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🔊 Volume set to %.2f", targetVolume);
    PrintToServer("[MusicPlugin Debug] [Timer_FinalFadeApply] FadeClientVolume to %.2f initiated for client %N.", targetVolume, client);

    return Plugin_Stop;
}

public Action Timer_VoteSkipEnd(Handle timer)
{
    PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] Vote skip timer expired. Calculating results...");
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            totalPlayers++;
        }
    }
    PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] Total real players: %d.", totalPlayers);
    int requiredVotes = (totalPlayers / 2) + 1;
    if (totalPlayers == 0) requiredVotes = 0;

    float ratio = totalPlayers > 0 ? float(g_YesVotes) / float(totalPlayers) : 0.0;
    PrintToServer("[MusicPlugin] Vote ended. Votes: %d/%d (Required: %d) (%.2f%%)", g_YesVotes, totalPlayers, requiredVotes, ratio * 100.0);
    PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] Yes Votes: %d, Required Votes: %d, Ratio: %.2f.", g_YesVotes, requiredVotes, ratio);
    if (g_YesVotes >= requiredVotes && g_YesVotes > 0)
    {
        PrintToChatAll("\x01[\x04MusicPlugin\x01] ✅ Vote passed! Skipping current track...");
        PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] Vote PASSED. Skipping track.");
        int next = (g_CurrentTrack + 1) % g_TrackCount;
        PlayTrack(next, "Timer_VoteSkipEnd");
    }
    else
    {
        PrintToChatAll("\x01[\x04MusicPlugin\x01] ❌ Vote failed. Not enough support.");
        PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] Vote FAILED. Not enough votes.");
    }

    g_VoteInProgress = false;
    g_YesVotes = 0;
    if (g_VotedClients != null)
    {
        g_VotedClients.Clear();
        PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] g_VotedClients cleared.");
    }
    PrintToServer("[MusicPlugin Debug] [Timer_VoteSkipEnd] Vote state reset.");
    return Plugin_Stop;
}

public Action Timer_DelayedAutoplay(Handle timer, any data)
{
    int timerInstanceID = data;

    PrintToServer("[MusicPlugin Debug] [Timer_DelayedAutoplay] Delayed autoplay timer triggered. Timer Instance ID: %d, Global Plugin Instance ID: %d.", timerInstanceID, g_PluginInstanceID);

    if (timerInstanceID != g_PluginInstanceID)
    {
        PrintToServer("[MusicPlugin Debug] [Timer_DelayedAutoplay] Timer instance ID mismatch. This is an old timer. Stopping execution.");
        return Plugin_Stop;
    }

    if (g_TrackCount > 0)
    {
        PrintToServer("[MusicPlugin Debug] [Timer_DelayedAutoplay] g_TrackCount is %d. Proceeding with autoplay.", g_TrackCount);
        PlayTrack(0, "Timer_DelayedAutoplay");
        PrintToServer("[MusicPlugin Debug] [Timer_DelayedAutoplay] Autoplay initiated: Playing track 0.");
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [Timer_DelayedAutoplay] No tracks available for autoplay. g_TrackCount is %d.", g_TrackCount);
    }
    return Plugin_Stop;
}

public Action Timer_AdvertiseHelp(Handle timer)
{
    PrintToServer("[MusicPlugin Debug] [Timer_AdvertiseHelp] Advertising help message.");
    PrintToChatAll("\x01[\x04MusicPlugin\x01] 🎵 Type !musichelp for music commands.");
    return Plugin_Continue;
}

public bool PlayTrack(int index, const char[] source)
{
    PrintToServer("[MusicPlugin Debug] [PlayTrack] ENTERED PlayTrack(%d) from %s.", index, source);
    if (index < 0 || index >= g_TrackCount)
    {
        PrintToServer("[MusicPlugin Debug] [PlayTrack] Invalid track index %d. Aborting.", index);
        return false;
    }

    if (g_IsPlaying && g_CurrentTrack != -1 && StrEqual(g_TrackList[g_CurrentTrack], g_TrackList[index], false))
    {
        PrintToServer("[MusicPlugin Debug] [PlayTrack] Track %d ('%s') is already effectively playing (same sound file as current track %d). Aborting duplicate play request from %s.", index, g_TrackNames[index], g_CurrentTrack, source);
        return true;
    }

    g_IsInPlaybackTransition = true;

    if (g_IsPlaying && g_CurrentTrack != -1)
    {
        PrintToServer("[MusicPlugin Debug] [PlayTrack] Stopping previous track '%s' (Index: %d) for all clients before starting new one.", g_TrackNames[g_CurrentTrack], g_CurrentTrack);
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i))
            {
                StopSound(i, MUSIC_CHANNEL, g_TrackList[g_CurrentTrack]);
            }
        }
    }
    else if (g_IsPlaying && g_CurrentTrack == -1)
    {
         PrintToServer("[MusicPlugin Debug] [PlayTrack] Stopping any generic sound on MUSIC_CHANNEL for all clients (g_CurrentTrack is -1).");
         for (int i = 1; i <= MaxClients; i++)
         {
             if (IsClientInGame(i))
             {
                 StopSound(i, MUSIC_CHANNEL, NULL_STRING);
             }
         }
    }

    float sync_time = GetGameTime();
    g_TrackStartTime = sync_time;
    PrintToServer("[MusicPlugin Debug] [PlayTrack] Setting g_TrackStartTime to %.3f for track %d. Current Game Time: %.3f.", sync_time, index, GetGameTime());

    g_CurrentTrack = index;
    PrintToServer("[MusicPlugin Debug] [PlayTrack] Track '%s' (Index: %d) starting. Server G_TrackStartTime: %.3f.", g_TrackNames[index], index, g_TrackStartTime);

    float soundtime_offset = 0.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            EmitSoundToClient(
                i,
                g_TrackList[index],
                i,
                MUSIC_CHANNEL,
                SNDLEVEL_NORMAL,
                SND_NOFLAGS,
                g_ClientVolumes[i],
                100,
                -1,
                g_NullVectorFloat,
                g_NullVectorFloat,
                false,
                soundtime_offset
            );
            PrintToChat(i, "\x01[\x04MusicPlugin\x01] ▶ Now Playing: \x03%s", g_TrackNames[index]);
            PrintToServer("[MusicPlugin Debug] [PlayTrack] Emitted sound '%s' to client %N (Index: %d) at volume %.2f, start_time: %.2f.", g_TrackList[index], i, i, g_ClientVolumes[i], soundtime_offset);
        }
    }

    if (g_MusicTimer != INVALID_HANDLE)
    {
        PrintToServer("[MusicPlugin Debug] [PlayTrack] Killing previous music timer (ID: %d).", g_MusicTimerID);
        KillTimer(g_MusicTimer);
        g_MusicTimer = INVALID_HANDLE;
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [PlayTrack] No previous music timer to kill.");
    }

    g_MusicTimerID++;
    float timer_duration = float(g_TrackDurations[index]) + TRACK_BUFFER;
    
    g_MusicTimer = CreateTimer(timer_duration, Timer_NextTrack, g_MusicTimerID);
    PrintToServer("[MusicPlugin Debug] [PlayTrack] New music timer created for %.3f seconds (ID: %d).", timer_duration, g_MusicTimerID);
    g_IsPlaying = true;
    g_IsInPlaybackTransition = false;
    PrintToServer("[MusicPlugin Debug] [PlayTrack] EXITED PlayTrack(%d) from %s. IsPlaying: %b, InTransition: %b.", index, source, g_IsPlaying, g_IsInPlaybackTransition);
    return true;
}

public void StopTrackForAll(int index)
{
    PrintToServer("[MusicPlugin Debug] [StopTrackForAll] Attempting to stop track index: %d for all clients.", index);
    if (index < 0 || index >= g_TrackCount)
    {
        PrintToServer("[MusicPlugin Debug] [StopTrackForAll] Invalid track index %d. Aborting.", index);
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            StopSound(i, MUSIC_CHANNEL, g_TrackList[index]);
            PrintToChat(i, "\x01[\x04MusicPlugin\x01] ⏹️ Music stopped.");
            PrintToServer("[MusicPlugin Debug] [StopTrackForAll] Stopped sound '%s' for client %N (Index: %d).", g_TrackList[index], i, i);
        }
    }

    if (g_MusicTimer != INVALID_HANDLE)
    {
        PrintToServer("[MusicPlugin Debug] [StopTrackForAll] Killing active music timer (ID: %d).", g_MusicTimerID);
        KillTimer(g_MusicTimer);
        g_MusicTimer = INVALID_HANDLE;
    }
    else
    {
        PrintToServer("[MusicPlugin Debug] [StopTrackForAll] No active music timer to kill.");
    }

    g_IsPlaying = false;
    g_IsInPlaybackTransition = false;
    PrintToServer("[MusicPlugin Debug] [StopTrackForAll] Music playback state set to stopped. IsPlaying: %b, InTransition: %b.", g_IsPlaying, g_IsInPlaybackTransition);
}

public Action Timer_NextTrack(Handle timer, any data)
{
    int timerID = data;

    PrintToServer("[MusicPlugin Debug] [Timer_NextTrack] Timer callback triggered. Timer Music ID: %d, Global Music ID: %d, Global Plugin Instance ID: %d.", timerID, g_MusicTimerID, g_PluginInstanceID);

    if (timerID != g_MusicTimerID)
    {
        PrintToServer("[MusicPlugin Debug] [Timer_NextTrack] Timer ID mismatch. This is an old timer. Stopping execution.");
        return Plugin_Stop;
    }

    g_MusicTimer = INVALID_HANDLE;

    if (g_TrackCount == 0)
    {
        PrintToServer("[MusicPlugin Debug] [Timer_NextTrack] No tracks loaded. Stopping music playback.");
        g_IsPlaying = false;
        return Plugin_Stop;
    }

    int next = (g_CurrentTrack + 1) % g_TrackCount;
    PrintToServer("[MusicPlugin Debug] [Timer_NextTrack] Current track %d ended. Playing next track %d.", g_CurrentTrack, next);
    PlayTrack(next, "Timer_NextTrack");
    return Plugin_Stop;
}

public Action Cmd_VoteSkip(int client, int args)
{
    PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Client %N (Index: %d) initiated vote skip.", client, client);
    if (!IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Client %N (Index: %d) not in game. Command denied.", client, client);
        return Plugin_Handled;
    }
    if (!g_IsPlaying || g_CurrentTrack == -1)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] ℹ️ No music is currently playing to vote skip.");
        PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] No music playing. Vote skip denied.", client, client);
        return Plugin_Handled;
    }
    if (g_VoteInProgress)
    {
        if (g_VotedClients.FindValue(client) == -1)
        {
            g_VotedClients.Push(client);
            g_YesVotes++;
            PrintToChat(client, "\x01[\x04MusicPlugin\x01] ✅ You voted YES to skip. Current votes: %d.", g_YesVotes);
            PrintToChatAll("\x01[\x04MusicPlugin\x01] 🗳️ %N voted YES to skip. Current votes: \x03%d\x01.", client, g_YesVotes);
            PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Client %N (Index: %d) voted YES. Current YesVotes: %d.", client, client, g_YesVotes);
        }
        else
        {
            PrintToChat(client, "\x01[\x04MusicPlugin\x01] ℹ️ You have already voted in this poll.");
            PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Client %N (Index: %d) already voted. Denied.", client, client);
        }
        return Plugin_Handled;
    }

    g_VoteInProgress = true;
    g_YesVotes = 0;
    g_VotedClients.Clear();
    PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Vote initiated. VoteInProgress: %b, YesVotes: %d.", g_VoteInProgress, g_YesVotes);

    g_VotedClients.Push(client);
    g_YesVotes++;
    PrintToChatAll("\x01[\x04MusicPlugin\x01] 🗳️ %N has started a vote to skip the current track! Type \x03!voteskip\x01 to vote YES.", client);
    PrintToChat(client, "\x01[\x04MusicPlugin\x01] ✅ You voted YES to skip.");
    PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Initiator %N (Index: %d) voted YES. Current YesVotes: %d.", client, client, g_YesVotes);

    CreateTimer(VOTESKIP_DURATION, Timer_VoteSkipEnd, _);
    PrintToServer("[MusicPlugin Debug] [Cmd_VoteSkip] Vote skip timer created for %.1f seconds.", VOTESKIP_DURATION);
    return Plugin_Handled;
}

public Action Cmd_MusicVolume(int client, int args)
{
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) attempting to set volume.", client, client);
    if (!IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) not in game. Command denied.", client, client);
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "\x01[\x04MusicPlugin\x01] Usage: \x03!musicvol <mute|low|med|high|value>");
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) provided no arguments. Usage displayed.", client, client);
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));
    float newVolume = g_ClientVolumes[client];

    if (StrEqual(arg, "mute", false))
    {
        newVolume = 0.0;
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) setting volume to MUTE (0.0).", client, client);
    }
    else if (StrEqual(arg, "low", false))
    {
        newVolume = 0.01;
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) setting volume to LOW (0.01).", client, client);
    }
    else if (StrEqual(arg, "med", false))
    {
        newVolume = 0.03;
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) setting volume to MED (0.03).", client, client);
    }
    else if (StrEqual(arg, "high", false))
    {
        newVolume = 0.05;
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) setting volume to HIGH (0.05).", client, client);
    }
    else
    {
        newVolume = StringToFloat(arg);
        if (newVolume < 0.0 || newVolume > 1.0)
        {
            PrintToChat(client, "\x01[\x04MusicPlugin\x01] ❌ Invalid volume value. Please use a value between 0.0 and 1.0.");
            PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) provided invalid volume value (%.2f). Denied.", client, client, newVolume);
            return Plugin_Handled;
        }
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) setting volume to custom value (%.2f).", client, client, newVolume);
    }

    g_ClientVolumes[client] = newVolume;
    PrintToChat(client, "\x01[\x04MusicPlugin\x01] 🔊 Your music volume set to \x03%.2f\x01.", newVolume);
    PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Client %N (Index: %d) volume updated to %.2f.", client, client, newVolume);

    if (g_IsPlaying && g_CurrentTrack != -1)
    {
        StopSound(client, MUSIC_CHANNEL, g_TrackList[g_CurrentTrack]);
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Stopped current track for client %N to apply new volume.", client);

        float current_game_time = GetGameTime();
        float elapsed_time = current_game_time - g_TrackStartTime;

        elapsed_time = RoundToFloor(elapsed_time * 10.0) / 10.0;

        if (elapsed_time < 0.0)
        {
            elapsed_time = 0.0;
            PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Clamped negative elapsed_time to 0.0 for client %N.", client);
        }
        else if (elapsed_time > float(g_TrackDurations[g_CurrentTrack]))
        {
            elapsed_time = float(g_TrackDurations[g_CurrentTrack]);
            PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Clamped elapsed_time to duration (%.3f) for client %N.", elapsed_time, client);
        }

        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Calculated elapsed_time for re-emission: %.3f for client %N.", elapsed_time, client);

        EmitSoundToClient(
            client,
            g_TrackList[g_CurrentTrack],
            client,
            MUSIC_CHANNEL,
            SNDLEVEL_NORMAL,
            SND_NOFLAGS,
            g_ClientVolumes[client],
            100,
            -1,
            g_NullVectorFloat,
            g_NullVectorFloat,
            false,
            elapsed_time
        );
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Re-emitted track '%s' to client %N at volume %.2f, elapsed %.3f.", g_TrackNames[g_CurrentTrack], client, g_ClientVolumes[client], elapsed_time);

        DataPack dp_final = new DataPack();
        dp_final.WriteCell(client);
        dp_final.WriteFloat(g_ClientVolumes[client]);
        CreateTimer(0.1, Timer_FinalFadeApply, dp_final);
        PrintToServer("[MusicPlugin Debug] [Cmd_MusicVolume] Timer_FinalFadeApply scheduled for 0.1 seconds with new DataPack.");
    }

    return Plugin_Handled;
}

public bool MusicPlugin_IsAuthorized(int client)
{
    PrintToServer("[MusicPlugin Debug] [MusicPlugin_IsAuthorized] Checking authorization for client %N (Index: %d).", client, client);
    if (client <= 0 || !IsClientInGame(client))
    {
        PrintToServer("[MusicPlugin Debug] [MusicPlugin_IsAuthorized] Client %N (Index: %d) is invalid or not in game. Returning false.", client, client);
        return false;
    }
    bool authorized = CheckCommandAccess(client, "musicplugin_access", ADMFLAG_GENERIC);
    PrintToServer("[MusicPlugin Debug] [MusicPlugin_IsAuthorized] Client %N (Index: %d) access status: %b (ADMFLAG_GENERIC).", client, client, authorized);
    return authorized;
}

public bool LoadTracks()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/musiclist.txt");
    PrintToServer("[MusicPlugin Debug] [LoadTracks] Attempting to load tracks from: %s", path);

    if (!FileExists(path))
    {
        LogError("[MusicPlugin] ❌ musiclist.txt not found at %s. No music will play.", path);
        PrintToServer("[MusicPlugin Debug] [LoadTracks] musiclist.txt not found. Aborting track loading.");
        return false;
    }

    File f = OpenFile(path, "r");
    if (f == null)
    {
        LogError("[MusicPlugin] ❌ Failed to open musiclist.txt for reading at %s. Check file permissions.", path);
        PrintToServer("[MusicPlugin Debug] [LoadTracks] Failed to open musiclist.txt. Aborting track loading.");
        return false;
    }
    PrintToServer("[MusicPlugin Debug] [LoadTracks] Successfully opened musiclist.txt.");

    g_TrackCount = 0;
    char line[PLATFORM_MAX_PATH];
    int lineNum = 0;

    while (!f.EndOfFile() && g_TrackCount < MAX_TRACKS)
    {
        lineNum++;
        f.ReadLine(line, sizeof(line));
        TrimString(line);
        PrintToServer("[MusicPlugin Debug] [LoadTracks] Processing line %d: '%s'", lineNum, line);

        if (line[0] == '\0' || line[0] == ';' || line[0] == '#')
        {
            PrintToServer("[MusicPlugin Debug] [LoadTracks] Skipping empty or comment line %d.", lineNum);
            continue;
        }

        char filename[PLATFORM_MAX_PATH];
        char durationStr[16];
        char trackname[PLATFORM_MAX_PATH];

        int firstSpace = FindCharInString(line, ' ');
        if (firstSpace == -1)
        {
            LogError("[MusicPlugin] ⚠ Invalid line format in musiclist.txt (missing first space for duration): %s (Line: %d)", line, lineNum);
            PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: Missing first space. Skipping.", lineNum);
            continue;
        }

        strcopy(filename, sizeof(filename), line);
        filename[firstSpace] = '\0';
        TrimString(filename);
        PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: Parsed filename: '%s'", lineNum, filename);

        bool isDuplicate = false;
        for (int i = 0; i < g_TrackCount; i++)
        {
            char existingFullPath[PLATFORM_MAX_PATH];
            Format(existingFullPath, sizeof(existingFullPath), "music/%s", filename);
            if (StrEqual(g_TrackList[i], existingFullPath, false))
            {
                PrintToServer("[MusicPlugin] ⚠️ Skipping duplicate track entry: '%s' (already loaded as track %d). (Line: %d)", filename, i, lineNum);
                isDuplicate = true;
                break;
            }
        }

        if (isDuplicate)
        {
            continue;
        }

        int secondSpace = FindCharInString(line, ' ', firstSpace + 1);

        if (secondSpace == -1)
        {
            int durationStart = firstSpace + 1;
            strcopy(durationStr, sizeof(durationStr), line[durationStart]);
            TrimString(durationStr);
            strcopy(trackname, sizeof(trackname), filename);
            PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: No second space. Parsed duration: '%s', trackname (fallback): '%s'", lineNum, durationStr, trackname);
        }
        else
        {
            int durationLen = secondSpace - (firstSpace + 1);
            if (durationLen > 0 && durationLen < sizeof(durationStr))
            {
                strcopy(durationStr, sizeof(durationStr), line[firstSpace + 1]);
                durationStr[durationLen] = '\0';
                TrimString(durationStr);
                PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: Parsed duration string: '%s'", lineNum, durationStr);
            }
            else
            {
                LogError("[MusicPlugin] ⚠ Could not parse duration from line: %s (Line: %d)", line, lineNum);
                PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: Could not parse duration. Skipping.", lineNum);
                continue;
            }

            int trackNameStart = secondSpace + 1;
            if (trackNameStart < strlen(line))
            {
                strcopy(trackname, sizeof(trackname), line[trackNameStart]);
                TrimString(trackname);
                PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: Parsed track name: '%s'", lineNum, trackname);
            }
            else
            {
                strcopy(trackname, sizeof(trackname), filename);
                PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: No track name found after duration, falling back to filename: '%s'", lineNum, trackname);
            }
        }

        int duration = StringToInt(durationStr);
        if (duration <= 0)
        {
            duration = 15;
            PrintToServer("[MusicPlugin] ℹ️ Invalid duration for '%s', defaulting to %d seconds. (Line: %d)", filename, duration, lineNum);
            PrintToServer("[MusicPlugin Debug] [LoadTracks] Line %d: Invalid duration. Defaulting to %d. Please ensure musiclist.txt durations are accurate.", lineNum, duration);
        }

        Format(g_TrackList[g_TrackCount], PLATFORM_MAX_PATH, "music/%s", filename);

        PrecacheSound(g_TrackList[g_TrackCount], true);
        PrintToServer("[MusicPlugin Debug] [LoadTracks] Precaching sound: '%s'", g_TrackList[g_TrackCount]);

        char fullPathForDownload[PLATFORM_MAX_PATH];
        Format(fullPathForDownload, sizeof(fullPathForDownload), "sound/%s", g_TrackList[g_TrackCount]);
        AddFileToDownloadsTable(fullPathForDownload);
        PrintToServer("[MusicPlugin Debug] [LoadTracks] Added '%s' to downloads table.", fullPathForDownload);

        g_TrackDurations[g_TrackCount] = duration;
        strcopy(g_TrackNames[g_TrackCount], PLATFORM_MAX_PATH, trackname);
        g_TrackCount++;
        PrintToServer("[MusicPlugin Debug] [LoadTracks] Loaded track %d: File='%s', Duration=%d, Name='%s'", g_TrackCount - 1, g_TrackList[g_TrackCount - 1], duration, g_TrackNames[g_TrackCount - 1]);
    }

    CloseHandle(f);
    PrintToServer("[MusicPlugin] ✅ Loaded %d music tracks.", g_TrackCount);
    PrintToServer("[MusicPlugin Debug] [LoadTracks] File closed. Total tracks loaded: %d.", g_TrackCount);
    g_TracksLoadedForMap = true;
    return true;
}
