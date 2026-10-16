// CGEvent input driver for driving the Wadjet overlay in tests.
// Usage: swift tools/drive.swift move x y | drag x1 y1 x2 y2 | click x y | key <code> [cmd shift]
import CoreGraphics
import Foundation

let src = CGEventSource(stateID: .hidSystemState)
let args = CommandLine.arguments

func mouse(_ type: CGEventType, _ x: Double, _ y: Double, _ btn: CGMouseButton = .left) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: btn)!.post(tap: .cghidEventTap)
}
func key(_ code: Int, down: Bool, _ flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

switch args[1] {
case "move":
    mouse(.mouseMoved, Double(args[2])!, Double(args[3])!)
case "drag":
    let x1 = Double(args[2])!, y1 = Double(args[3])!, x2 = Double(args[4])!, y2 = Double(args[5])!
    mouse(.mouseMoved, x1, y1); usleep(120_000)
    mouse(.leftMouseDown, x1, y1); usleep(150_000)
    for i in 1...12 {
        mouse(.leftMouseDragged, x1 + (x2 - x1) * Double(i) / 12, y1 + (y2 - y1) * Double(i) / 12)
        usleep(50_000)
    }
    mouse(.leftMouseUp, x2, y2)
case "click":
    mouse(.leftMouseDown, Double(args[2])!, Double(args[3])!); usleep(80_000)
    mouse(.leftMouseUp, Double(args[2])!, Double(args[3])!)
case "key":
    var flags = CGEventFlags()
    for a in args.dropFirst(3) {
        if a == "cmd" { flags.insert(.maskCommand) }
        if a == "shift" { flags.insert(.maskShift) }
    }
    key(Int(args[2])!, down: true, flags); usleep(80_000); key(Int(args[2])!, down: false, [])
default: print("unknown")
}
