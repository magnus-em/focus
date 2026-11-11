import Foundation
import SwiftData

public enum FocusModelContainer {
    /// CloudKit container identifier — must match the iCloud entitlement
    /// configured in App Store Connect / the Xcode project settings.
    public static let cloudKitContainerID = "iCloud.com.magnus.focustracker"

    /// The Mac app isn't sandboxed, so SwiftData's default store is
    /// ~/Library/Application Support/default.store, the same path every other
    /// unsandboxed process using SwiftData's defaults gets. On 11/11
    /// icloudmailagent opened it and migrated it to its own schema, which
    /// dropped every Focus table. iOS stores live in the app's own container.
    public static var storeURL: URL? {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Focus/Focus.store")
        #else
        return nil
        #endif
    }

    /// Build the SwiftData container. When `cloudKitSync` is true, data syncs
    /// to the user's iCloud private database. Requires the iCloud entitlement
    /// to be present in the host app's signing.
    public static func make(cloudKitSync: Bool) throws -> ModelContainer {
        let schema = Schema(FocusSchema.allModels)
        let cloud: ModelConfiguration.CloudKitDatabase =
            cloudKitSync ? .private(cloudKitContainerID) : .none

        let config: ModelConfiguration
        if let url = storeURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: cloud)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: cloud)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }
}
