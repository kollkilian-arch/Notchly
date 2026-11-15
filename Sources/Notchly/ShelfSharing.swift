import AppKit

/// Hands off to the macOS AirDrop sheet. The recipient is always chosen by the user.
final class ShelfSharing: NSObject, NSSharingServiceDelegate {
    static let shared = ShelfSharing()
    private var service: NSSharingService?
    private var completion: ((String?) -> Void)?
    private var temporaryPayload: AirDropPayload?

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
        guard Self.canShare(item) else { completion("This item is no longer available."); return }
        share(items: Self.items(for: item), payload: nil, completion: completion)
    }

    func share(payload: AirDropPayload, completion: @escaping (String?) -> Void) {
        share(items: payload.urls.map { $0 as NSURL }, payload: payload, completion: completion)
    }

    private func share(items: [Any], payload: AirDropPayload?, completion: @escaping (String?) -> Void) {
        guard service == nil else {
            payload?.cleanUp()
            completion("An AirDrop share is already open.")
            return
        }
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: items) else {
            payload?.cleanUp()
            completion("AirDrop is unavailable for these items. Check that AirDrop is enabled.")
            return
        }
        self.service = service
        self.completion = completion
        temporaryPayload = payload
        service.delegate = self
        service.perform(withItems: items)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(nil) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cocoa = error as NSError
        finish(cocoa.code == NSUserCancelledError ? nil : error.localizedDescription)
    }

    private func finish(_ error: String?) {
        let callback = completion
        completion = nil
        service = nil
        temporaryPayload?.cleanUp()
        temporaryPayload = nil
        callback?(error)
    }
}
