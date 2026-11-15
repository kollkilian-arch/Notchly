import AppKit

/// Hands off to the macOS AirDrop sheet. The recipient is always chosen by the user.
final class ShelfSharing: NSObject, NSSharingServiceDelegate {
    static let shared = ShelfSharing()
    private var service: NSSharingService?
    private var completion: ((String?) -> Void)?

    static func items(for item: ShelfItem) -> [Any] {
        // Text snippets already have a real .txt file; images have their original PNG asset.
        [item.url as NSURL]
    }

    static func canShare(_ item: ShelfItem) -> Bool {
        // Do not initialise sharing services while SwiftUI renders a tile; macOS may start
        // recipient discovery. Only clicking Share should open the native service.
        !item.url.isFileURL || FileManager.default.fileExists(atPath: item.url.path)
    }

    func share(_ item: ShelfItem, completion: @escaping (String?) -> Void) {
        guard service == nil else { completion("An AirDrop share is already open."); return }
        guard Self.canShare(item), let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: Self.items(for: item)) else {
            completion("AirDrop is unavailable for this item. Check that the file still exists and AirDrop is enabled.")
            return
        }
        self.service = service
        self.completion = completion
        service.delegate = self
        service.perform(withItems: Self.items(for: item))
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(nil) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cocoa = error as NSError
        finish(cocoa.code == NSUserCancelledError ? nil : error.localizedDescription)
    }

    private func finish(_ error: String?) {
        completion?(error)
        completion = nil
        service = nil
    }
}
