#!/bin/sh
# post a debug command to the running Wadjet app via DistributedNotificationCenter
exec env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift -e '
import Foundation
DistributedNotificationCenter.default().post(
    name: .init("cx.mia.wadjet.cmd"),
    object: CommandLine.arguments.dropFirst().joined(separator: " "),
    userInfo: nil
)' "$@"
