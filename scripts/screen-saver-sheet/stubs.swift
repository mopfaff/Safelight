import Foundation

// The copy never restarts WallpaperAgent, which ScreenSaverManager does by killing it: drawing the sheet
// leaves the desktop and the screen saver as they were. scripts/screen-saver-sheet.sh checks the built app
// has no way left to call the system's kill.
func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
    0
}
