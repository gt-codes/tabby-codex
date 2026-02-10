import AVFoundation
import Contacts
import CoreLocation
import SwiftUI
import UIKit

@MainActor
final class PermissionCenter: NSObject, ObservableObject {
    @Published private(set) var cameraStatus: AVAuthorizationStatus
    @Published private(set) var contactsStatus: CNAuthorizationStatus
    @Published private(set) var locationStatus: CLAuthorizationStatus

    private var locationManager: CLLocationManager?

    override init() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        locationStatus = CLLocationManager.authorizationStatus()
        super.init()
    }

    var cameraEnabled: Bool {
        cameraStatus == .authorized
    }

    var contactsEnabled: Bool {
        contactsStatus == .authorized
    }

    var locationEnabled: Bool {
        locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse
    }

    func refreshStatuses() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
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

    func requestContacts() {
        if contactsStatus == .notDetermined {
            CNContactStore().requestAccess(for: .contacts) { [weak self] _, _ in
                Task { @MainActor in
                    self?.contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
                }
            }
        } else if contactsStatus == .denied || contactsStatus == .restricted {
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
