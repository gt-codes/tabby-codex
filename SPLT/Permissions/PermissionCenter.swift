import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

@MainActor
final class PermissionCenter: NSObject, ObservableObject {
    @Published private(set) var cameraStatus: AVAuthorizationStatus
    @Published private(set) var locationStatus: CLAuthorizationStatus

    private var locationManager: CLLocationManager?

    override init() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        locationStatus = CLLocationManager.authorizationStatus()
        super.init()
    }

    var cameraEnabled: Bool {
        cameraStatus == .authorized
    }

    var locationEnabled: Bool {
        locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse
    }

    func refreshStatuses() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        locationStatus = CLLocationManager.authorizationStatus()
    }

    func requestCamera() {
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in
                    self?.cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            openSettings()
        }
    }

    func requestLocation() {
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            locationManager = manager
        }

        switch locationStatus {
        case .notDetermined:
            locationManager?.requestWhenInUseAuthorization()
        case .denied, .restricted:
            openSettings()
        default:
            break
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension PermissionCenter: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            locationStatus = manager.authorizationStatus
        }
    }
}
