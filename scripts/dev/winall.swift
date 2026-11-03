// Lists Remanence windows, including ones on another Space, and their IDs for screencapture -l.
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Remanence" {
  print(w[kCGWindowNumber as String]!, "layer", w[kCGWindowLayer as String]!, "onscreen", w[kCGWindowIsOnscreen as String] ?? "?", "name", w[kCGWindowName as String] ?? "", w[kCGWindowBounds as String]!)
}
print("session", CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:])
