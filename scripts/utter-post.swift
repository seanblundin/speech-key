import Foundation
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "start"
DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.seanblundin.utter.meeting.\(name)"), object: nil, userInfo: nil, deliverImmediately: true)
print("posted \(name)")
