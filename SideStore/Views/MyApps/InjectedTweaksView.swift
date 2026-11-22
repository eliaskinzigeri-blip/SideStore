//
//  InjectedTweaksView.swift
//  SideStore
//
//  SideStore shell: tweaks (.dylib / .deb) injected into a sideloaded app at its next signing.
//  needs proper testing on device
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class InjectedTweaksModel: ObservableObject
{
    let appName: String
    let bundleID: String
    
    @Published var tweaks: [InjectedTweak] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var hasChanges = false
    
    init(appName: String, bundleID: String)
    {
        self.appName = appName
        self.bundleID = bundleID
        reload()
    }
    
    func reload()
    {
        tweaks = InjectedTweaks.tweaks(for: bundleID)
    }
    
    func importFiles(_ urls: [URL])
    {
        var added: [String] = []
        for url in urls {
            let isSecured = url.startAccessingSecurityScopedResource()
            defer { if isSecured { url.stopAccessingSecurityScopedResource() } }
            do {
                added += try InjectedTweaks.add(from: url, for: bundleID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if !added.isEmpty {
            hasChanges = true
            statusMessage = String(format: NSLocalizedString("Added: %@. Tap “Re-sign now” to apply.", comment: ""), added.joined(separator: ", "))
        }
        reload()
    }
    
    func setEnabled(_ enabled: Bool, _ tweak: InjectedTweak)
    {
        do {
            try InjectedTweaks.setEnabled(enabled, tweak)
            hasChanges = true
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
    
    func delete(_ tweak: InjectedTweak)
    {
        do {
            try InjectedTweaks.delete(tweak)
            hasChanges = true
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}

struct InjectedTweaksView: View
{
    @StateObject private var model: InjectedTweaksModel
    @State private var isImporting = false
    @Environment(\.dismiss) private var dismiss
    
    /// Re-signs the app so the tweaks are applied.
    let resign: () -> Void
    
    init(appName: String, bundleID: String, resign: @escaping () -> Void)
    {
        _model = StateObject(wrappedValue: InjectedTweaksModel(appName: appName, bundleID: bundleID))
        self.resign = resign
    }
    
    private var importTypes: [UTType] {
        var types: [UTType] = []
        if let dylib = UTType(filenameExtension: "dylib") { types.append(dylib) }
        if let deb = UTType(filenameExtension: "deb") { types.append(deb) }
        types.append(.data)
        return types
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if model.tweaks.isEmpty {
                        Text(NSLocalizedString("No tweak yet. Tap + to add a .dylib or a .deb.", comment: ""))
                            .foregroundColor(.secondary)
                    }
                    ForEach(model.tweaks) { tweak in
                        Toggle(isOn: Binding(
                            get: { tweak.isEnabled },
                            set: { model.setEnabled($0, tweak) }
                        )) {
                            Label(tweak.displayName, systemImage: "puzzlepiece.extension")
                        }
                        .swipeActions {
                            SwiftUI.Button(role: .destructive) { model.delete(tweak) } label: {
                                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(String(format: NSLocalizedString("Injected into %@", comment: ""), model.appName))
                } footer: {
                    Text(NSLocalizedString("Tweaks are added to the app each time it is signed (install, update, re-sign). Interface tweaks usually work; tweaks that patch C functions need JIT and may not. A .deb is unpacked automatically (gzip and xz packages).", comment: ""))
                }
                
                Section {
                    SwiftUI.Button {
                        dismiss()
                        resign()
                    } label: {
                        Label(NSLocalizedString("Re-sign now to apply", comment: ""), systemImage: "signature")
                    }
                } footer: {
                    Text(NSLocalizedString("Re-signing reinstalls the app with the enabled tweaks. Its data is kept.", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Tweaks", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button(NSLocalizedString("Done", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    SwiftUI.Button { isImporting = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importFiles(urls)
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .alert(NSLocalizedString("Tweaks", comment: ""), isPresented: Binding(
                get: { model.statusMessage != nil },
                set: { if !$0 { model.statusMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) {}
            } message: {
                Text(model.statusMessage ?? "")
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
}
