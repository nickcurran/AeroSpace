import Foundation

// todo make it configurable
// todo make default choice
private func createDefaultWorkspaceContainer(_ workspace: Workspace) -> TilingContainer {
    guard let monitorRect = NSScreen.focusedMonitorOrNilIfDesktop?.rect else { return HListContainer(parent: workspace) }
    return monitorRect.width > monitorRect.height ? VListContainer(parent: workspace) : HListContainer(parent: workspace)
}

private var workspaceNameToWorkspace: [String: Workspace] = [:]

/// Empty workspace is spread over all monitors. That's why it's tracked separately. See ``monitorTopLeftCornerToNotEmptyWorkspace``,
var currentEmptyWorkspace: Workspace = getOrCreateNextEmptyWorkspace()
/// macOS doesn't provide an API to check for currently active/selected monitor
/// (see ``NSScreen.focusedMonitorOrNilIfDesktop``) => when users changes the active monitor by clicking the
/// desktop on different monitor AeroSpace can't detect it => AeroSpace assumes that the empty workspace occupies
/// both monitors.
///
/// If, at the same time, another monitor already contains another not empty workspace `B` then we assume that this
/// monitor contains two workspaces: the empty one and `B` which displayed on top of empty one
///
/// That's why the mental model is the following: the empty workspace is spread over all monitors. And each monitor
/// optionally can have a not empty workspace assigned to it
///
/// When this map contains `nil` it means that the monitor displays the "empty"/"background" workspace
var monitorTopLeftCornerToNotEmptyWorkspace: [CGPoint: Workspace?] = [:]

func getOrCreateNextEmptyWorkspace() -> Workspace {
    let all = Workspace.all
    if let existing = all.first(where: { $0.isEffectivelyEmpty }) {
        return existing
    }
    let occupiedNames = all.map { $0.name }.toSet()
    let newName = (0...Int.max).lazy.map { "EMPTY\($0)" }.first { !occupiedNames.contains($0) }
            ?? errorT("Can't create empty workspace")
    return Workspace.get(byName: newName)
}

var allMonitorsRectsUnion: Rect {
    NSScreen.screens.map { $0.rect }.union()
}

class Workspace: TreeNode, Hashable, Identifiable {
    let name: String
    var floatingWindows = Set<MacWindow>()
    var rootContainer: TilingContainer = HListContainer(parent: NilTreeNode.instance)
    var id: String { name } // satisfy Identifiable
    private var _assignedMonitor: Monitor
    var assignedMonitor: Monitor {
        get { _assignedMonitor }
        set {
            _assignedMonitor = newValue
            // TODO("implement windows relative move")
        }
    }
    weak var lastActiveWindow: MacWindow?

    private init(_ name: String, _ assignedMonitorRect: Monitor) {
        self.name = name
        self._assignedMonitor = assignedMonitorRect
        super.init(parent: NilTreeNode.instance)
        rootContainer = HListContainer(parent: self)
                // todo createDefaultWorkspaceContainer(self)
    }

    static var all: [Workspace] {
        garbageCollectUnusedWorkspaces()
        return workspaceNameToWorkspace.values.sorted { a, b in a.name < b.name }
    }

    static func get(byName name: String) -> Workspace {
        if let existing = workspaceNameToWorkspace[name] {
            return existing
        } else {
            let workspace = Workspace(name, Monitor(name: nil, rect: allMonitorsRectsUnion))
            workspaceNameToWorkspace[name] = workspace
            return workspace
        }
    }

    static func garbageCollectUnusedWorkspaces() {
        let preservedNames = settings.map { $0.name }.toSet()
        for name in preservedNames {
            _ = get(byName: name) // Make sure that all preserved workspaces are "cached"
        }
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            preservedNames.contains(workspace.name) ||
                    !workspace.isEffectivelyEmpty ||
                    workspace == currentEmptyWorkspace ||
                    workspace.name == ViewModel.shared.focusedWorkspaceTrayText
        }
    }

    static func ==(lhs: Workspace, rhs: Workspace) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

extension Workspace {
    var isVisible: Bool {
        self == currentEmptyWorkspace ||
                monitorTopLeftCornerToNotEmptyWorkspace[assignedMonitor.rect.topLeftCorner] == self
    }
}

extension NSScreen {
    /// Don't forget that there is always an empty additional "background" workspace on every monitor ``currentEmptyWorkspace``
    var notEmptyWorkspace: Workspace? {
        get {
            if let existing = monitorTopLeftCornerToNotEmptyWorkspace[rect.topLeftCorner] {
                return existing
            }
            // What if monitor configuration changed? (frame.origin is changed)
            rearrangeWorkspacesOnMonitors()
            // Normally, recursion should happen only once more because we must take the value from the cache
            // (Unless, monitor configuration data race happens)
            return self.notEmptyWorkspace
        }
    }
}

private func rearrangeWorkspacesOnMonitors() {
    let oldMonitorToWorkspaces: [CGPoint: Workspace?] = monitorTopLeftCornerToNotEmptyWorkspace
    monitorTopLeftCornerToNotEmptyWorkspace = [:]
    let monitors = NSScreen.screens
    let origins = monitors.map { $0.rect.topLeftCorner }.toSet()
    let preservedWorkspaces: [Workspace] = oldMonitorToWorkspaces
            .filter { oldOrigin, oldWorkspace in origins.contains(oldOrigin) }
            .map { $0.value }
            .filterNotNil()
    let lostWorkspaces: [Workspace] = oldMonitorToWorkspaces
            .filter { oldOrigin, oldWorkspace in !origins.contains(oldOrigin) }
            .map { $0.value }
            .filterNotNil()
    var poolOfWorkspaces: [Workspace] =
            Workspace.all.reversed() - (preservedWorkspaces + lostWorkspaces) + lostWorkspaces
    for monitor in monitors {
        let origin = monitor.rect.topLeftCorner
        // If monitors change, most likely we will preserve only the main monitor (It always has (0, 0) origin)
        if let existing = oldMonitorToWorkspaces[origin] {
            monitorTopLeftCornerToNotEmptyWorkspace[origin] = existing
        } else {
            monitorTopLeftCornerToNotEmptyWorkspace[origin] = poolOfWorkspaces.popLast()
        }
    }
}