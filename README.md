### Functional
### Utilities for
### Creative
### Kittens

My personal quickshell scripts that I use for my hyprland rice.


# App Launcher
Works a lot like wofi, but includes some additional utilities.
Fancy animations. URL support. Web Search (currently defaults to google). 
URLs and Web Searches are saved for autocompletion. Results disappear after 30 days unless you keep using them.
Most used results are listed first. The launcher prioritizes apps first, then sites, then searches.

Tab (no text) : Open or close the result box for a minimal look.

Tab (text) : Autocompletes text like a browser search bar.

Enter : Autocompletes text and then launches. OR launches selection.

Mouse : Click to select. Click your selection again to launch. Can also resize the result box.

Variables are at the top of the file for you to play with.


Launch in hyprland by executing command: `"qs ipc call app-launcher toggle"`

I personally set the hyprland menu variable to this and launch it with SUPER + Space.
I actually rely on the hyprland animations for this one.


# Screensaver
Very simple pure-black screensaver with oled in mind. Only darkens the screen. Does not do anything power-related.
Controls are a bit "sticky" to account for mouse jitter and accidental presses.

**You must add your user to the input group** for some features (such as jitter detection) to work.

The screen will dim after a few minutes. (Default 4:30 seconds)
It will then go completely black after some time. (Default 30 Seconds)

Variables are at the top of the file for you to play with.

Launch manually in hyprland by executing command: `"qs ipc call screensaver toggle"`

I recommend turning off animations in hyprland by targetting the layer: `"quickshell-screensaver"`
