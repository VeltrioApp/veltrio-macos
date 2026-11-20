import Foundation

extension Notification.Name {
    static let veltrioGoto        = Notification.Name("veltrio.goto")
    static let veltrioOpenSearch  = Notification.Name("veltrio.search")
    /// Open the player; the object is the `PlayerDestination`. For views
    /// that start playback from a key press rather than a link.
    static let veltrioPlay        = Notification.Name("veltrio.play")
    /// Replace the player on screen with another channel (zapping), so
    /// Back still returns to where the player was opened from.
    static let veltrioZap         = Notification.Name("veltrio.zap")
}
