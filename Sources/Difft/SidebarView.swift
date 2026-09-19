import SwiftUI
import DifftCore
import DifftServices
import DifftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let session = model.session {
            // Passed explicitly as @ObservedObject — a subview observing only
            // AppModel would not re-render when session.data / selectedFile
            // mutate, since ReviewSession is a nested ObservableObject.
            FileTreeView(session: session)
        }
    }
}

/// One node of the changed-files tree: either a folder (children != nil) or a
/// file leaf. Single-child folder chains are compacted ("src/app/api").
struct FileTreeNode: Identifiable {
    let id: String        // full path prefix (folders) or file path (leaves)
    let name: String      // display name (possibly compacted "a/b/c")
    var children: [FileTreeNode]?
    var file: FileDiff?
    var fileCount: Int    // leaves under this node (1 for a leaf)

    static func build(from files: [FileDiff]) -> [FileTreeNode] {
        // Insert into a nested dictionary tree, then convert + compact.
        final class Dir {
            var dirs: [String: Dir] = [:]
            var files: [FileDiff] = []
        }
        let root = Dir()
        for f in files {
            var cur = root
            let parts = f.path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if cur.dirs[part] == nil { cur.dirs[part] = Dir() }
                cur = cur.dirs[part]!
            }
            cur.files.append(f)
        }

        func convert(_ dir: Dir, prefix: String) -> [FileTreeNode] {
            var nodes: [FileTreeNode] = []
            for (name, sub) in dir.dirs.sorted(by: { $0.key < $1.key }) {
                // Compact chains of single-child folders with no files.
                var compactName = name
                var compactPrefix = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var current = sub
                while current.files.isEmpty, current.dirs.count == 1,
                      let (childName, child) = current.dirs.first {
                    compactName += "/\(childName)"
                    compactPrefix += "/\(childName)"
                    current = child
                }
                let children = convert(current, prefix: compactPrefix)
                let count = children.reduce(0) { $0 + $1.fileCount }
                nodes.append(FileTreeNode(id: compactPrefix, name: compactName,
                                          children: children, file: nil, fileCount: count))
            }
            for f in dir.files.sorted(by: { $0.path < $1.path }) {
                let name = String(f.path.split(separator: "/").last ?? "")
                nodes.append(FileTreeNode(id: f.path, name: name,
                                          children: nil, file: f, fileCount: 1))
            }
            return nodes
        }
        return convert(root, prefix: "")
    }
}
