import Foundation

/// Times as text. Every screen formats its times here, so each format can be tested.
/// Negative and non-finite input reads as zero.
public enum TimeText {
    /// `4:05`, or `1:02:09` past an hour. For lengths, track starts and rulers.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(sanitized(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    /// `7 hr 55 min`, or `12 min` under an hour.
    public static func long(_ seconds: Double) -> String {
        let minutes = Int(sanitized(seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    /// `12:04.3`, with tenths for placing markers.
    public static func precise(_ seconds: Double) -> String {
        // Rounded, so a marker nudged to 1234.0 can't read as 20:33.9 from float error.
        let tenths = Int((sanitized(seconds) * 10).rounded())
        let minutes = tenths / 600
        let remainder = (tenths % 600) / 10
        let hours = minutes / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes % 60, remainder, tenths % 10)
            : String(format: "%d:%02d.%d", minutes, remainder, tenths % 10)
    }

    /// `00:01:18`, always with hours. For a running clock, so it counts whole
    /// seconds that have passed and never rounds up.
    public static func timecode(_ seconds: Double) -> String {
        let total = Int(sanitized(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// `0:00.48`, or `1:02:09.50` past an hour. For trim points.
    public static func hundredths(_ seconds: Double) -> String {
        // Rounded as a whole, so 59.999 carries into the minutes.
        let hundredths = Int((sanitized(seconds) * 100).rounded())
        let minutes = hundredths / 6000
        let remainder = (hundredths % 6000) / 100
        let fraction = hundredths % 100
        let hours = minutes / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes % 60, remainder, fraction)
            : String(format: "%d:%02d.%02d", minutes, remainder, fraction)
    }

    private static func sanitized(_ seconds: Double) -> Double {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
