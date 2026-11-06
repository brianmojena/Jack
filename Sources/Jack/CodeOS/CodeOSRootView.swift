import JackCore
import SwiftUI

/// The CodeOS window: a console-style launcher where projects are the games. Normal mode only.
struct CodeOSRootView: View {
    @AppStorage("lightModeEnabled") private var lightMode = false
    @StateObject private var model: CodeOSModel
    let store: ChatStore
    let workspace: WorkspaceSessions
    let memory: WindowMemory
    let batterySaver: BatterySaver
    let updateChecker: UpdateChecker

    init(store: ChatStore, workspace: WorkspaceSessions, memory: WindowMemory, batterySaver: BatterySaver, updateChecker: UpdateChecker) {
        self.store = store
        self.workspace = workspace
        self.memory = memory
        self.batterySaver = batterySaver
        self.updateChecker = updateChecker
        _model = StateObject(wrappedValue: CodeOSModel(store: store))
    }

    var body: some View {
        if lightMode {
            Text("CodeOS solo está disponible en el modo Normal.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            console
        }
    }

    private var console: some View {
        ZStack {
            background
            if model.quota.current == nil {
                CodeOSProfilesView(model: model)
                    .transition(.opacity)
            } else if let project = model.open {
                CodeOSSessionView(model: model, project: project, store: store, workspace: workspace, memory: memory, batterySaver: batterySaver, updateChecker: updateChecker)
                    .id(project.id)
                    .transition(.opacity)
            } else {
                CodeOSHomeView(model: model)
                    .transition(.opacity)
            }
            if model.gridVisible {
                CodeOSGridView(model: model)
                    .transition(.opacity)
            }
            if model.controlCenter {
                CodeOSControlCenter(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.pickerVisible {
                CodeOSFolderPickerView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
            if model.quotaPanel, model.quota.current != nil {
                CodeOSQuotaPanel(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
            if let project = model.pendingRemoval {
                CodeOSRemovalDialog(model: model, project: project)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .animation(.easeInOut(duration: 0.45), value: model.open?.id)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.controlCenter)
        .animation(.easeOut(duration: 0.25), value: model.gridVisible)
        .animation(.easeOut(duration: 0.25), value: model.pickerVisible)
        .animation(.easeOut(duration: 0.2), value: model.pendingRemoval?.id)
        .animation(.easeOut(duration: 0.22), value: model.quotaPanel)
        .animation(.easeInOut(duration: 0.35), value: model.quota.current?.id)
        .frame(minWidth: 960, minHeight: 600)
        .preferredColorScheme(model.appearance.scheme)
        // Inside a project the keyboard is the terminal's and the chat's: the console only answers to ⌘ combinations there,
        // unless one of its panels (control center, grid, quota, new project) is on top.
        .background(CodeOSKeyCatcher(commandOnly: model.open != nil && !model.controlCenter && !model.gridVisible && !model.pickerVisible && !model.quotaPanel, handler: handle))
        .onAppear {
            model.enter()
            // Like a console: it takes over the screen in its own Space. F leaves and enters it again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
                CodeOSWindow.toggleFullScreen(window)
            }
        }
        .onDisappear {
            model.shutDown()
            // Leaving the mode gives the window back: out of full screen.
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    private var background: some View {
        // Inside a session the window stays neutral: only the glass carries the project's colour.
        let focus = model.open == nil ? model.focused : nil
        let tint = focus.map(model.tint) ?? Color(white: 0.5)
        return ZStack {
            Color.codeOSFloor
            LinearGradient(colors: [tint.opacity(focus == nil ? 0.1 : 0.28), .clear], startPoint: .topTrailing, endPoint: .center)
            RadialGradient(colors: [tint.opacity(focus == nil ? 0.06 : 0.22), .clear], center: .bottomLeading, startRadius: 10, endRadius: 800)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.7), value: focus?.id)
    }

    private func handle(_ key: CodeOSKey) -> Bool {
        if key == .fullScreen {
            if let window = NSApp.keyWindow { CodeOSWindow.toggleFullScreen(window) }
            return true
        }
        // Profile screen: nothing else is on until a profile is chosen.
        if model.quota.current == nil {
            switch key {
            case .left: model.moveProfile(-1)
            case .right: model.moveProfile(1)
            case .confirm: model.activateProfile()
            case .remove: model.removeProfileUnderCursor()
            case .back: model.cancelNewProfile()
            default: return false
            }
            return true
        }
        // The confirmation to remove a project takes every key until it is answered.
        if model.pendingRemoval != nil {
            switch key {
            case .left: model.chooseRemoval(false)
            case .right: model.chooseRemoval(true)
            case .confirm: model.answerRemoval()
            case .back: model.cancelRemoval()
            default: break
            }
            return true
        }
        if model.pickerVisible {
            switch key {
            case .left: model.picker.move(dx: -1, dy: 0)
            case .right: model.picker.move(dx: 1, dy: 0)
            case .up: model.picker.move(dx: 0, dy: -1)
            case .down: model.picker.move(dx: 0, dy: 1)
            case .confirm: model.picker.activate()
            case .explore: model.picker.explore()
            case .remove: model.picker.up()
            case .previousCategory: model.picker.shiftPlace(-1)
            case .nextCategory: model.picker.shiftPlace(1)
            case .back, .newProject: model.closePicker()
            default: break
            }
            return true
        }
        if model.quotaPanel {
            switch key {
            case .quota, .back: model.closeQuotaPanel()
            case .toggleActive: model.quota.setActive(!model.quota.active)
            case .requestQuota: model.quota.requestShare()
            case .accept: model.quota.acceptFirstRequest()
            case .newProject: model.quota.declineFirstRequest()
            case .groupCode: model.beginEditingCode()
            case .changeProfile: model.changeProfile()
            default: return false
            }
            return true
        }
        if key == .quota { model.toggleQuotaPanel(); return true }
        if model.gridVisible, !model.controlCenter {
            switch key {
            case .left: model.moveGrid(dx: -1, dy: 0)
            case .right: model.moveGrid(dx: 1, dy: 0)
            case .up: model.moveGrid(dx: 0, dy: -1)
            case .down: model.moveGrid(dx: 0, dy: 1)
            case .confirm: model.activateGrid()
            case .remove: model.toggleGridHidden()
            case .toggleHidden: model.toggleShowHidden()
            case .newProject: model.openPicker()
            case .back, .showAll: model.closeGrid()
            case .controlCenter: model.toggleControlCenter()
            default: return false
            }
            return true
        }
        if model.controlCenter {
            switch key {
            case .left: model.moveControl(dx: -1, dy: 0)
            case .right: model.moveControl(dx: 1, dy: 0)
            case .up: model.moveControl(dx: 0, dy: -1)
            case .down: model.moveControl(dx: 0, dy: 1)
            case .confirm: model.activateControl()
            case .back, .controlCenter: model.closeControlCenter()
            default: return false
            }
            return true
        }
        if model.open != nil {
            switch key {
            case .back: model.goHome()
            case .controlCenter: model.toggleControlCenter()
            default: return false
            }
            return true
        }
        switch key {
        case .left: model.moveFocus(-1)
        case .right: model.moveFocus(1)
        case .confirm: model.openFocused()
        case .previousCategory: model.shiftCategory(-1)
        case .nextCategory: model.shiftCategory(1)
        case .controlCenter: model.toggleControlCenter()
        case .generate: model.generateFocusedCover()
        case .remove: model.removeFocused()
        case .showAll: model.openGrid()
        case .newProject: model.openPicker()
        default: return false
        }
        return true
    }
}
