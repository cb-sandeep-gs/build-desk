import BuildDeskCore
import Foundation
import Observation

/// The devices and simulators known to this Mac. The window refreshes it while it is open.
@MainActor
@Observable
public final class DeviceListModel {
    /// Time between refreshes while the window is open. Plugging a phone in should show up without
    /// a click, and the two list tools together take well under a second.
    public static let pollInterval: Duration = .seconds(5)

    public private(set) var state: LoadState<[Device]> = .idle
    public var selectedDeviceID: String? {
        didSet { store.lastDeviceID = selectedDeviceID }
    }

    private let discovery: any DeviceDiscovering
    private let store: PreferenceStore

    public init(discovery: any DeviceDiscovering, store: PreferenceStore) {
        self.discovery = discovery
        self.store = store
        self.selectedDeviceID = store.lastDeviceID
    }

    public var devices: [Device] { state.value ?? [] }

    public var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    public func refresh() async {
        // Keep showing the current list while it reloads; only the first load shows a spinner.
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await discovery.devices())
        } catch {
            // A failed refresh must not empty a list that was fine a moment ago.
            if state.value == nil { state = .failed(userMessage(for: error)) }
        }
    }
}
