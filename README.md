
# **\[ANY\]-SM-GlobalMusicPlayer**

## **🎵 Comprehensive Server-Wide Background Music**

This SourceMod plugin provides a robust and highly configurable system for playing continuous background music across your game server. Designed with stability and synchronization in mind, it aims to enhance player experience with dynamic music playback and essential administrative and player-facing controls.

## **✨ Features**

* **Server-Wide Continuous Playback:** Automatically plays music tracks sequentially for all connected players.  
* **Dedicated Audio Channel:** Utilizes a dedicated sound channel (MUSIC\_CHANNEL 6\) for music playback, ensuring minimal interference with other in-game sounds and providing isolated, precise control over the music stream.  
* **Dynamic Volume Control (\!musicvol):**  
  * Players can adjust their individual music volume (0.0 to 1.0) using simple commands like \!musicvol mute, \!musicvol low, \!musicvol med, \!musicvol high, or \!musicvol \<value\>.  
  * Features a sophisticated stop-re-emit mechanism with a smooth fade-in (FadeClientVolume) to ensure seamless volume adjustments on currently playing tracks, preventing audio glitches or overlaps.  
* **Music Resynchronization (\!musicsync):**  
  * Allows players to resynchronize their music playback with the server's current track position.  
  * Includes logic to compensate for client latency, aiming for more accurate playback alignment.  
* **Community Vote-Skip System (\!voteskip):**  
  * Players can initiate and participate in a vote to skip the current track.  
  * Requires a configurable majority of votes to pass, giving players a voice in the music selection.  
* **Automatic Track Cycling:** Automatically transitions to the next track in the playlist once the current song finishes.  
* **Comprehensive Track Management:**  
  * Reads music track paths, durations, and display names from a musiclist.txt configuration file.  
  * Includes robust error handling for missing or malformed entries in the music list.  
  * Automatically precaches sounds and adds them to the client download table, ensuring players have the necessary audio files.  
  * Prevents duplicate playback of the same sound file if the next track in the sequence happens to be identical.  
* **Robust State Management:**  
  * Resets plugin state on map changes, ensuring a clean start for music playback on every new map.  
  * Implements unique timer IDs (g\_MusicTimerID) to prevent "stale" timers from interfering with current playback.  
  * Delayed and retried track loading ensures musiclist.txt is processed reliably, even if the filesystem isn't immediately ready on plugin or map start.  
* **Admin Controls:**  
  * \!musicplay: Start music playback.  
  * \!musicskip: Skip to the next track.  
  * \!musicstop: Stop all music playback.  
  * **Admin Access:** To use these commands, you need to have administrator privileges on your SourceMod server. This plugin requires the musicplugin\_access flag, which defaults to ADMFLAG\_GENERIC.  
    **How to Become an Admin:**  
    1. **Edit addons/sourcemod/configs/admins\_simple.ini:**  
       * Open this file with a text editor.  
       * Add an entry for yourself. Common methods include:  
         * **By SteamID64:** "STEAM\_1:0:12345678" "99:z" (Replace with your actual SteamID64 and desired flags. 99:z grants all flags including z for custom flags like musicplugin\_access).  
         * **By IP Address:** "127.0.0.1" "99:z" (Replace with your server-facing IP).  
         * **By Name (less secure):** "YourPlayerName" "99:z" (Requires auth "name" in the entry).  
       * Ensure the flags you assign include z to grant custom admin flags.  
       * Save the file.  
    2. **Reload Admins:**  
       * In your server's console (or via RCON), type sm\_reloadadmins.  
       * Alternatively, restart your server.  
    3. **Verify Access:**  
       * Once in-game, type sm\_who in your console to see if your name appears with admin flags.  
       * Attempt to use an admin command like \!musicplay.  
* **Player Information Commands:**  
  * \!musiclist: Displays a list of all loaded music tracks.  
  * \!musicsettings: Shows the player's current music volume.  
  * \!musichelp: Displays an interactive menu of available music commands.

## **⚙️ Installation**

1. **Compile the Plugin:**  
   * Download the .sp file (this source code).  
   * Compile it using the SourceMod compiler. You can use the online compiler or set up a local compilation environment.  
   * The compiled plugin (.smx file) will be generated in the addons/sourcemod/scripting/compiled directory.  
2. **Place the Plugin:**  
   * Move the compiled .smx file to your server's addons/sourcemod/plugins/ directory.  
3. **Create musiclist.txt:**  
   * In your server's addons/sourcemod/configs/ directory, create a file named musiclist.txt.  
4. **Add Music Files:**  
   * Place your .mp3 or .wav music files into your server's sound/music/ directory (e.g., csgo/sound/music/).  
   * **Important:** Ensure your music files are properly converted and optimized for Source engine playback. Use tools like audacity to convert to 16-bit, 44100 Hz, mono or stereo WAV files. For MP3s, ensure they are compatible.  
5. **Configure musiclist.txt:**  
   * Open addons/sourcemod/configs/musiclist.txt and add your music tracks in the following format:

   "music/track1.mp3" 180 "Awesome Track Name 1"  
     "music/another\_song.wav" 245 "Another Great Song"  
     "music/epic\_sound.mp3" 300 "Epic Background"

   * **Format:** "relative/path/to/sound.ext" \<duration\_in\_seconds\> "Display Name"  
     * The path should be relative to your sound/ directory.  
     * Duration is in whole seconds.  
     * Display Name is what players will see in the \!musiclist command.  
6. **Reload Server or Change Map:**  
   * Restart your server or change the map for the plugin to load and begin playing music.

## **🎮 Commands**

### **Player Commands**

* \!musichelp \- Displays an interactive menu of all available music commands.  
* \!musicvol \<mute|low|med|high|value\> \- Adjusts your personal music volume.  
  * mute: Sets volume to 0.0.  
  * low: Sets volume to 0.01.  
  * med: Sets volume to 0.03.  
  * high: Sets volume to 0.05.  
  * \<value\>: A specific float value between 0.0 and 1.0 (e.g., \!musicvol 0.2).  
* \!musicsettings \- Displays your current music volume setting.  
* \!musiclist \- Shows a list of all loaded music tracks with their index, name, and duration.  
* \!musicsync \- Resynchronizes your music playback with the server's current track.  
* \!voteskip \- Initiates or votes "yes" in a vote to skip the current track.

### **Admin Commands (Requires musicplugin\_access flag, default: ADMFLAG\_GENERIC)**

* \!musicplay \- Starts music playback from the beginning of the playlist.  
* \!musicskip \- Skips the current track and plays the next one.  
* \!musicstop \- Stops all music playback.

## **⚠️ Known Issues (Areas for Contribution)**

While the plugin is designed for robustness, there are some known issues related to audio synchronization that the community can help investigate and resolve:

* **Music Desync when Issuing \!musicvol Command:** Despite efforts to stop and re-emit the sound, some clients may experience a brief desynchronization or a slight jump in playback position when adjusting volume with \!musicvol.  
* **Music Desync when Joining the Server:** New clients joining the server might experience the music playing from a slightly incorrect playback position, even with latency compensation.  
* **\!musicsync Desync:** The \!musicsync command, intended to correct desync, may not always perfectly sync to the exact last playback position, potentially causing a minor jump forward or backward for some clients.

These issues are likely related to the nuances of the Source engine's audio system and network synchronization for EmitSoundToClient and StopSound operations. Further investigation and alternative approaches might be needed.

## **🤝 Contributing**

Contributions are highly welcome\! If you have ideas for improvements, bug fixes, or can help resolve the known desync issues, please feel free to:

1. Fork the repository.  
2. Create a new branch for your feature or bug fix.  
3. Make your changes.  
4. Submit a pull request with a clear description of your changes.

## **📄 License**

This project is licensed under the MIT License \- see the [LICENSE](https://www.google.com/search?q=LICENSE) file for details.
