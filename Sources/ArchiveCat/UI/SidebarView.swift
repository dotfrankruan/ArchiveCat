//
//  SidebarView.swift
//  ArchiveCat
//
//  The archive's directory hierarchy, as a native source list.
//
//  Only folders are listed, and a node materialises its own children on demand,
//  so opening a 100 000 entry tarball costs one level of work rather than one
//  node per directory in the archive.
//

import ArchiveCore
import SwiftUI

/// One expandable item in the sidebar.
///
/// A value type on purpose: `OutlineGroup` takes a key path to the children,
/// and Swift key paths cannot point at main-actor-isolated members, so the node
/// stays `Sendable` and builds `children` from the (immutable) tree.
struct SidebarNode: Identifiable, Sendable {

    let path: String
    let name: String
    let tree: ArchiveTree

    var id: String { path }

    var displayName: String { name.isEmpty ? "Archive" : name }

    /// Subfolders, or `nil` for a leaf so no disclosure triangle is drawn.
    var children: [SidebarNode]? {
        guard let directory = tree.directory(at: path) else { return nil }
        let built = directory.childDirectoryPaths.compactMap { childPath -> SidebarNode? in
            guard let child = tree.directory(at: childPath) else { return nil }
            return SidebarNode(path: child.path, name: child.name, tree: tree)
        }
        return built.isEmpty ? nil : built
    }

    /// How many folders are directly inside, shown as a subtle count.
    var childCount: Int {
        tree.directory(at: path)?.childDirectoryPaths.count ?? 0
    }
}

struct SidebarView: View {

    @Bindable var model: BrowserViewModel
    @State private var selection: String?

    var body: some View {
        List(selection: $selection) {
            if let document = model.document, let tree = model.tree {
                Section {
                    let root = SidebarNode(path: "", name: model.title, tree: tree)
                    if root.children == nil {
                        Label(model.title, systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                            .tag("")
                    } else {
                        OutlineGroup([root], children: \.children) { node in
                            Label {
                                Text(node.displayName)
                            } icon: {
                                Image(systemName: "folder")
                            }
                            .tag(node.path)
                        }
                    }
                } header: {
                    Text("Archive")
                }

                if document.summary.unsafeEntryCount > 0 {
                    Section {
                        Label {
                            Text("\(document.summary.unsafeEntryCount.formatted()) hidden entries")
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                        }
                        .help("Entries whose paths point outside the archive are not listed and cannot be extracted.")
                    }
                }
            } else {
                Section {
                    Text("No archive open")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { selection = model.currentPath }
        .onChange(of: model.currentPath) { _, path in
            if selection != path { selection = path }
        }
        .onChange(of: selection) { _, path in
            guard let path, path != model.currentPath else { return }
            model.navigate(to: path)
        }
    }
}
