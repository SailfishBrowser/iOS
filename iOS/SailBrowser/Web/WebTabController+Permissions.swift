import WebKit

extension WebTabController {
    // A private tab's web view keeps its data in the session's non-persistent store.
    var isPrivate: Bool {
        !webView.configuration.websiteDataStore.isPersistent
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        await decideMedia(type: type)
    }

    // Keyed on the page's host rather than the requesting frame's, so the decision is the one Site Settings shows.
    func decideMedia(type: WKMediaCaptureType) async -> WKPermissionDecision {
        let kinds: [MediaKind]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: return .deny
        }
        guard let host = webView.url?.host() else { return .deny }
        return await decideMedia(host, kinds) ? .grant : .deny
    }
}
