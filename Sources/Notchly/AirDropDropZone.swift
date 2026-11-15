import SwiftUI
import UniformTypeIdentifiers

struct AirDropPayload {
    let urls: [URL]
    let temporaryDirectory: URL
    func cleanUp() { try? FileManager.default.removeItem(at: temporaryDirectory) }
}

enum AirDropLoadError: LocalizedError {
    case unsupported, unreadable
    var errorDescription: String? {
        self == .unsupported ? "Drop files, images, web links, or text to share with AirDrop." : "One of the dropped items couldn't be read. Nothing was shared."
    }
}

/// Resolves the whole drop before presenting one AirDrop sheet. Temporary image/text files are
/// owned by this payload; original files are never copied into the Shelf or deleted.
enum AirDropDropLoader {
    static func preferredType(_ provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
        if let image = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) { return image }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return UTType.url.identifier }
        if provider.canLoadObject(ofClass: NSString.self) { return UTType.plainText.identifier }
        return nil
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping (Result<AirDropPayload, Error>) -> Void) {
        guard !providers.isEmpty, providers.allSatisfy({ preferredType($0) != nil }) else {
            completion(.failure(AirDropLoadError.unsupported)); return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Notchly-AirDrop-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { completion(.failure(error)); return }
        var remaining = providers.count
        var resolved = [Int: URL]()
        var failure: Error?
        // All result aggregation runs on main, including callbacks from third-party providers.
        func finish(_ index: Int, _ result: Result<URL, Error>) {
            switch result {
            case .success(let url): resolved[index] = url
            case .failure(let error): failure = failure ?? error
            }
            remaining -= 1
            guard remaining == 0 else { return }
            if let failure {
                try? FileManager.default.removeItem(at: folder)
                completion(.failure(failure))
            } else {
                completion(.success(AirDropPayload(urls: providers.indices.compactMap { resolved[$0] }, temporaryDirectory: folder)))
            }
        }
        for (index, provider) in providers.enumerated() {
            let type = preferredType(provider)!
            if type == UTType.plainText.identifier {
                _ = provider.loadObject(ofClass: NSString.self) { object, error in
                    DispatchQueue.main.async {
                        let result = Result { () throws -> URL in
                            guard let text = object as? String, !text.isEmpty else { throw error ?? AirDropLoadError.unreadable }
                            let url = folder.appendingPathComponent("Text-\(index + 1).txt")
                            try text.write(to: url, atomically: true, encoding: .utf8)
                            return url
                        }
                        finish(index, result)
                    }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    DispatchQueue.main.async {
                        let result = Result { () throws -> URL in
                            guard let data else { throw error ?? AirDropLoadError.unreadable }
                            if type == UTType.fileURL.identifier || type == UTType.url.identifier {
                                guard let url = URL(dataRepresentation: data, relativeTo: nil),
                                      url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                                      !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
                                    throw AirDropLoadError.unreadable
                                }
                                return url
                            }
                            guard let image = NSBitmapImageRep(data: data),
                                  let png = image.representation(using: .png, properties: [:]) else {
                                throw AirDropLoadError.unreadable
                            }
                            let url = folder.appendingPathComponent("Image-\(index + 1).png")
                            try png.write(to: url)
                            return url
                        }
                        finish(index, result)
                    }
                }
            }
        }
    }
}

struct AirDropDropZone: View {
    @ObservedObject var shelf: ShelfStore
    @State private var targeted = false
    @State private var sharing = false
    @State private var token = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if sharing { ProgressView().controlSize(.small) }
            else { AirDropSymbol().frame(width: 28, height: 28) }
            Text(sharing ? "AirDrop is open" : "AirDrop").font(.system(size: 13, weight: .semibold))
            Text(sharing ? "Choose a recipient" : "Drop here to send")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
            if let selected = shelf.selectedItem {
                Button("Send selected item…") {
                    sharing = true
                    ShelfSharing.shared.share(selected) { error in
                        sharing = false
                        shelf.errorMessage = error
                    }
                }
                .font(.system(size: 10)).buttonStyle(.plain)
                .disabled(sharing || !ShelfSharing.canShare(selected))
            }
        }
        .foregroundStyle(targeted ? Color.white : Color.accentColor)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(targeted ? Color.accentColor.opacity(0.4) : Color.accentColor.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(targeted ? 0.8 : 0.2)))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onDrop(of: ShelfStore.dropTypes, isTargeted: $targeted) { providers in
            guard !sharing else { return false }
            sharing = true
            AirDropDropLoader.load(providers) { result in
                switch result {
                case .success(let payload):
                    ShelfSharing.shared.share(payload: payload) { error in
                        sharing = false
                        shelf.errorMessage = error
                    }
                case .failure(let error):
                    sharing = false
                    shelf.errorMessage = error.localizedDescription
                }
            }
            return true
        }
        .onChange(of: sharing) { _, active in
            if active { NotchInteraction.popovers.insert(token) }
            else { NotchInteraction.popovers.remove(token) }
        }
        .onDisappear { NotchInteraction.popovers.remove(token) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AirDrop drop area")
        .accessibilityHint("Drop items here to choose an AirDrop recipient. Items are not added to the Shelf.")
    }
}

/// AirDrop's familiar radiating rings, also available on macOS releases without an AirDrop SF Symbol.
struct AirDropSymbol: View {
    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ForEach(1..<4) { ring in
                    Path { path in
                        path.addArc(center: center, radius: radius * CGFloat(ring) / 3 * 0.9,
                                    startAngle: .degrees(40), endAngle: .degrees(320), clockwise: false)
                    }
                    .stroke(style: StrokeStyle(lineWidth: max(1, radius * 0.1), lineCap: .round))
                    .rotationEffect(.degrees(90))
                }
                Circle().frame(width: radius * 0.2, height: radius * 0.2)
            }
        }
        .accessibilityHidden(true)
    }
}
