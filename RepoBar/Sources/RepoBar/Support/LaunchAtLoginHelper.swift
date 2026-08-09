import ServiceManagement

enum LaunchAtLoginHelper {
    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Intentionally silent; UI can inspect SMAppService for errors if needed
        }
    }
}
