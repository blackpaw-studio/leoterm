import LeoKit
import WebKit

extension LeoBrowserSite {
    /// The site of a WebKit security origin (its port is 0 for the default).
    init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }
}

extension LeoBrowserPermissionKind {
    /// nil for a capture type this build doesn't know: it is denied.
    init?(_ type: WKMediaCaptureType) {
        switch type {
        case .camera: self = .camera
        case .microphone: self = .microphone
        case .cameraAndMicrophone: self = .cameraAndMicrophone
        @unknown default: return nil
        }
    }
}

