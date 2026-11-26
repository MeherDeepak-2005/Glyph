#if RESEARCH_BETA
import SwiftUI

struct ResearchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var recording = KBTypingRecorder.enabled
    @State private var stored = KBTypingRecorder.stored()
    @State private var lastUpload = ResearchUploader.lastUpload
    @State private var status = ""
    @State private var export: URL?
    @State private var confirmDelete = false
    @State private var profile = KBTypingRecorder.profile

    var body: some View {
        List {
            Section {
                Toggle("Take part in typing research", isOn: Binding(
                    get: { recording },
                    set: { wanted in
                        setRecording(wanted)
                    }))
                NavigationLink("What is recorded") { ResearchDetailsView() }
                if recording && !KBSettings.lastFullAccess {
                    Label("Glyph needs Full Access to record. Turn it on in Settings › General › Keyboard › Keyboards › Glyph, then type something with Glyph.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("On for beta testers. Glyph records what you type in ordinary text fields — the words, where and when your finger touched, your swipe paths, and what you did with suggestions and corrections — and uploads it automatically, encrypted, to the Glyph developer to improve typing and Glide. Passwords, email, phone, number, address and code fields are never recorded. Turn this off at any time to stop.")
            }

            if recording || stored.bytes > 0 {
                Section {
                    LabeledContent("On this iPhone", value: storedText)
                    LabeledContent("Last upload", value: lastUpload.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                    if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Your recordings")
                } footer: {
                    Text("Recordings upload automatically when you open or leave Glyph, and every few hours in the background.")
                }

                Section {
                    NavigationLink("Practice") { PracticeView() }
                } footer: {
                    Text("Two minutes of typing shown words and sentences. Because Glyph knows what you meant to type, practice is the most useful data you can give.")
                }

                Section {
                    TextField("Nickname or tester code", text: field("name"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Typing hand", selection: field("hand")) {
                        Text("Not set").tag("")
                        Text("Right").tag("right")
                        Text("Left").tag("left")
                    }
                    Picker("Usually type with", selection: field("thumbs")) {
                        Text("Not set").tag("")
                        Text("Two thumbs").tag("two-thumbs")
                        Text("One thumb").tag("one-thumb")
                        Text("Index finger").tag("index")
                    }
                } header: {
                    Text("About you (optional)")
                } footer: {
                    Text("Sent with your recordings so they can be told apart and compared.")
                }

                Section {
                    Button("Prepare a copy to share") {
                        status = "Preparing…"
                        KBTypingRecorder.export { url in
                            export = url
                            status = url == nil ? "Nothing recorded yet." : "The copy is ready. It contains the text you typed."
                        }
                    }
                    if let export { ShareLink("Share the copy", item: export) }
                    Button("Stop and delete my recordings on this iPhone", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deleting removes what has not been uploaded yet and turns research off. To have uploaded recordings removed, tell the developer your nickname or tester code.")
                }
            }
        }
        .navigationTitle("Typing Research")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete the recordings on this iPhone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Stop and Delete", role: .destructive) {
                let deleted = KBTypingRecorder.clear()
                export = nil
                status = deleted ? "Recordings deleted. Research is off." : "Could not delete. Please try again."
                refresh()
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private var storedText: String {
        stored.bytes == 0 ? "Nothing waiting"
            : ByteCountFormatter.string(fromByteCount: Int64(stored.bytes), countStyle: .file)
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(get: { profile[key] ?? "" }, set: { value in
            profile[key] = value.isEmpty ? nil : String(value.prefix(64))
            KBTypingRecorder.profile = profile
        })
    }

    private func setRecording(_ on: Bool) {
        KBTypingRecorder.setEnabled(on)
        if on { ResearchUploader.scheduleBackgroundRefresh() }
        refresh()
    }

    private func refresh() {
        recording = KBTypingRecorder.enabled
        stored = KBTypingRecorder.stored()
        lastUpload = ResearchUploader.lastUpload
    }
}

private struct ResearchDetailsView: View {
    var body: some View {
        List {
            Section("What Glyph records while this is on") {
                Label("The words you type in ordinary text fields, such as messages and notes", systemImage: "text.cursor")
                Label("Where and when your finger touched the keys, and your swipe paths", systemImage: "hand.point.up.left")
                Label("Suggestions shown, corrections made, and what you undid or picked", systemImage: "arrow.uturn.backward")
                Label("Your iPhone model, iOS version and keyboard layout", systemImage: "iphone")
            }
            Section("What it never records") {
                Label("Passwords and anything typed in password fields", systemImage: "lock")
                Label("Email, phone, number, address, name and one-time-code fields", systemImage: "nosign")
                Label("Anything you type with another keyboard", systemImage: "keyboard")
            }
            Section("Where it goes") {
                Text("Recordings are encrypted on your iPhone and uploaded automatically to the Glyph developer when you open or leave this app, and every few hours in the background. Only the developer can read them. They are used to improve Glyph's typing and Glide, and are not sold or used for advertising.")
                Text("Ordinary messages can contain personal things. Turn research off before typing anything you would not want read.")
            }
            Section("Stopping") {
                Text("Turn the switch off at any time. \"Stop and delete\" also removes what has not been uploaded. Ask the developer to delete what was uploaded.")
            }
        }
        .navigationTitle("What is recorded")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
