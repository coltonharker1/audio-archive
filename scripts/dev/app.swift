import CoreGraphics
import Foundation
// Sends input ONLY to the Remanence process, so nothing can reach another app.
// Keys work even on another Space. Clicks do not register there, so use a debug hook.
//   app click <fractionX> <fractionY> | app text "..." | app key <code> [cmd]
let task = Process(); task.executableURL = URL(filePath: "/usr/bin/pgrep"); task.arguments = ["-x", "Remanence"]
let pipe = Pipe(); task.standardOutput = pipe; try! task.run(); task.waitUntilExit()
guard let pid = pid_t(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").first ?? "") else { print("not running"); exit(1) }
let a = CommandLine.arguments
func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], _ unicode: [UniChar]? = nil) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags
        if let unicode { e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
        e.postToPid(pid); usleep(30000)
    }
}
switch a[1] {
case "click":
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
    guard let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Remanence" && ($0[kCGWindowName as String] as? String) == "Remanence" }),
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { print("no window"); exit(1) }
    let p = CGPoint(x: b["X"]! + b["Width"]! * Double(a[2])!, y: b["Y"]! + b["Height"]! * Double(a[3])!)
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w[kCGWindowNumber as String] as! Int))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w[kCGWindowNumber as String] as! Int))
        e.postToPid(pid); usleep(60000)
    }
case "text": for ch in a[2] { key(ch == " " ? 49 : 0, [], Array(String(ch).utf16)) }
default: key(CGKeyCode(a[2])!, a.count > 3 ? .maskCommand : [])
}
print("sent to pid", pid)
