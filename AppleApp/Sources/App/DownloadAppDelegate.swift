#if os(iOS)
import UIKit

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        FileDownloadTransport.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}
#endif
