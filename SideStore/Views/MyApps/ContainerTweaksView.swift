//
//  ContainerTweaksView.swift
//  SideStore
//
//  SideStore shell: manage the tweaks of an app living in the LiveContainer engine.
//
//  LiveContainer loads every tweak at the root of its Tweaks folder into all apps, and the tweaks
//  of one sub-folder into the apps pointing to it (LCTweakFolder in the app's LCAppInfo.plist).
//  This screen gives each app its own sub-folder, so a tweak added here only goes into that app.
//  Tweaks are signed by LiveContainer the next time the app is launched.
//  needs proper testing on device
//

import SwiftUI
import UniformTypeIdentifiers

struct ContainerTweak: Identifiable, Hashable
{
    let url: URL

    var id: String { url.path }
    var isEnabled: Bool { !url.lastPathComponent.hasSuffix(".disabled") }
    var displayName: String {
        let name = url.lastPathComponent
        return name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name
    }
}

@MainActor
final class ContainerTweaksModel: ObservableObject
{
    let appName: String
    let bundleID: String

    @Published var appTweaks: [ContainerTweak] = []
    @Published var globalTweaks: [ContainerTweak] = []
    @Published var errorMessage: String?
    @Published var isAvailable = true

    private let fileManager = FileManager.default

    init(appName: String, bundleID: String)
    {
        self.appName = appName
        self.bundleID = bundleID
        self.reload()
    }

    private var tweaksRootURL: URL? {
        ContainerBridge.hostHomeURL?.appendingPathComponent("Documents/Tweaks", isDirectory: true)
    }

    private var appInfoURL: URL? {
        guard let home = ContainerBridge.hostHomeURL,
              let folder = ContainerBridge.installedFolderName(for: bundleID)
        else { return nil }
        return home.appendingPathComponent("Documents/Applications/\(folder)/LCAppInfo.plist")
    }

    /// The app's own tweak folder, created and assigned to the app on first use.
    private func appTweakFolderURL(create: Bool) throws -> URL?
    {
        guard let tweaksRootURL, let appInfoURL else { return nil }

        let info = NSMutableDictionary(contentsOf: appInfoURL) ?? NSMutableDictionary()
        if let existing = info["LCTweakFolder"] as? String, !existing.isEmpty {
            let url = tweaksRootURL.appendingPathComponent(existing, isDirectory: true)
            if create && !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }

        guard create else { return nil }

        let folderName = appName
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let finalName = folderName.isEmpty ? bundleID : folderName

        let url = tweaksRootURL.appendingPathComponent(finalName, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        info["LCTweakFolder"] = finalName
        guard info.write(to: appInfoURL, atomically: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func tweaks(in folderURL: URL) -> [ContainerTweak]
    {
        guard let items = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.compactMap { url -> ContainerTweak? in
            let name = url.lastPathComponent
            let baseName = name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name
            guard baseName != "TweakLoader.dylib" else { return nil }
            guard baseName.hasSuffix(".dylib") || baseName.hasSuffix(".framework") else { return nil }
            return ContainerTweak(url: url)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func reload()
    {
        guard ContainerBridge.isAvailable, let tweaksRootURL, appInfoURL != nil else {
            isAvailable = false
            return
        }
        isAvailable = true
        globalTweaks = tweaks(in: tweaksRootURL)
        if let folder = try? appTweakFolderURL(create: false) {
            appTweaks = tweaks(in: folder)
        } else {
            appTweaks = []
        }
    }

    func importTweak(from url: URL)
    {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer { if isSecured { url.stopAccessingSecurityScopedResource() } }

        do {
            guard let folder = try appTweakFolderURL(create: true) else { throw CocoaError(.fileNoSuchFile) }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    /// Moves a tweak from "all apps" to this app only.
    func keepForThisAppOnly(_ tweak: ContainerTweak)
    {
        do {
            guard let folder = try appTweakFolderURL(create: true) else { throw CocoaError(.fileNoSuchFile) }
            let destination = folder.appendingPathComponent(tweak.url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: tweak.url, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func setEnabled(_ enabled: Bool, for tweak: ContainerTweak)
    {
        guard enabled != tweak.isEnabled else { return }
        let folder = tweak.url.deletingLastPathComponent()
        let newName = enabled ? tweak.displayName : tweak.displayName + ".disabled"
        do {
            try fileManager.moveItem(at: tweak.url, to: folder.appendingPathComponent(newName))
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func delete(_ tweak: ContainerTweak)
    {
        do {
            try fileManager.removeItem(at: tweak.url)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}

struct ContainerTweaksView: View
{
    @StateObject private var model: ContainerTweaksModel
    @State private var isImporting = false
    @Environment(\.dismiss) private var dismiss

    init(appName: String, bundleID: String)
    {
        _model = StateObject(wrappedValue: ContainerTweaksModel(appName: appName, bundleID: bundleID))
    }

    private var dylibTypes: [UTType] {
        var types: [UTType] = [.data]
        if let dylib = UTType(filenameExtension: "dylib") { types.insert(dylib, at: 0) }
        return types
    }

    var body: some View {
        NavigationView {
            List {
                if !model.isAvailable {
                    Section {
                        Text(NSLocalizedString("This app is not in the container yet.", comment: ""))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        if model.appTweaks.isEmpty {
                            Text(NSLocalizedString("No tweak yet. Tap + to add a .dylib.", comment: ""))
                                .foregroundColor(.secondary)
                        }
                        ForEach(model.appTweaks) { tweak in
                            tweakRow(tweak)
                                .swipeActions {
                                    SwiftUI.Button(role: .destructive) { model.delete(tweak) } label: {
                                        Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text(String(format: NSLocalizedString("Only in %@", comment: ""), model.appName))
                    } footer: {
                        Text(NSLocalizedString("These tweaks are loaded only into this app. Changes apply the next time the app is opened.", comment: ""))
                    }

                    if !model.globalTweaks.isEmpty {
                        Section {
                            ForEach(model.globalTweaks) { tweak in
                                VStack(alignment: .leading, spacing: 8) {
                                    tweakRow(tweak)
                                    Button {
                                        model.keepForThisAppOnly(tweak)
                                    } label: {
                                        Label(String(format: NSLocalizedString("Keep for %@ only", comment: ""), model.appName), systemImage: "arrow.down.app")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        } header: {
                            Text(NSLocalizedString("In every app", comment: ""))
                        } footer: {
                            Text(NSLocalizedString("These tweaks are loaded into all the apps of the container. Use “Keep for … only” to restrict one to this app.", comment: ""))
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Tweaks", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button(NSLocalizedString("Done", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { isImporting = true } label: { Image(systemName: "plus") }
                        .disabled(!model.isAvailable)
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: dylibTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls { model.importTweak(from: url) }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .alert(NSLocalizedString("Error", comment: ""), isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func tweakRow(_ tweak: ContainerTweak) -> some View
    {
        Toggle(isOn: Binding(
            get: { tweak.isEnabled },
            set: { model.setEnabled($0, for: tweak) }
        )) {
            Label(tweak.displayName, systemImage: tweak.displayName.hasSuffix(".framework") ? "shippingbox" : "puzzlepiece.extension")
        }
    }
}
