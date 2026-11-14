import SwiftUI

@main
struct YmdMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            Label(model.state?.track == nil ? "" : model.menuTitle, systemImage: model.iconName)
                .labelStyle(.titleAndIcon)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
