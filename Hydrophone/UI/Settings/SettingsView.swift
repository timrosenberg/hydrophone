import SwiftUI

/// Native Settings (Preferences) window: server connection, authentication,
/// and transcoding. See docs/02-opensubsonic-api.md and docs/04-ui-ux.md.
struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.circle") }
        }
        .frame(width: 480)
    }
}

private struct ConnectionSettingsView: View {
    @Environment(ConnectionModel.self) private var connection

    var body: some View {
        @Bindable var connection = connection
        Form {
            Section("Server") {
                TextField("Server Address", text: $connection.serverAddress,
                          prompt: Text("https://music.example.com"))
                    .textContentType(.URL)
            }

            Section("Authentication") {
                Picker("Method", selection: $connection.authMethod) {
                    Text("Password (token)").tag(ServerCredentials.AuthMethod.tokenSalt)
                    Text("API Key").tag(ServerCredentials.AuthMethod.apiKey)
                }
                TextField("Username", text: $connection.username)
                SecureField(connection.authMethod == .apiKey ? "API Key" : "Password",
                            text: $connection.secret)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await connection.testConnection() }
                    }
                    Button("Save & Connect") {
                        Task { await connection.saveAndConnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    if connection.isConfigured {
                        Button("Disconnect", role: .destructive) { Task { await connection.disconnect() } }
                    }
                }
                statusRow
            }

            if connection.isConfigured {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask the server to rescan its music folders.")
                                .font(.callout).foregroundStyle(.secondary)
                            if let message = connection.scanMessage {
                                Text(message).font(.callout)
                            }
                        }
                        Spacer()
                        Button("Scan Library") {
                            Task { await connection.startLibraryScan() }
                        }
                    }
                    nativeFeaturesRow
                }
            }

            // A zero-setup way in for new users (and App Review): the public
            // Navidrome demo server. Hidden once a server is configured, so
            // it can't clobber a real setup with one click.
            if !connection.isConfigured {
                Section {
                    HStack {
                        Text("No server yet? Try the public Navidrome demo.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Demo Server") {
                            connection.serverAddress = "https://demo.navidrome.org"
                            connection.authMethod = .tokenSalt
                            connection.username = "demo"
                            connection.secret = "demo"
                            Task { await connection.saveAndConnect() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var statusRow: some View {
        switch connection.state {
        case .unconfigured:
            EmptyView()
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case let .connected(info):
            Label("Connected to \(info.type ?? "server") \(info.serverVersion ?? "")",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    /// Read-only — detection is automatic (#26), there is no manual toggle.
    /// Shown once a connect has been attempted this session; hidden before
    /// that (`.unknown`, matching `statusRow`'s `.unconfigured` treatment).
    @ViewBuilder
    private var nativeFeaturesRow: some View {
        switch connection.nativeFeaturesState {
        case .unknown:
            EmptyView()
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking for native Navidrome features…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .available:
            Label("Native Navidrome features available", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .unavailable:
            Label("Native Navidrome features unavailable — using Subsonic only", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct PlaybackSettingsView: View {
    @Environment(ConnectionModel.self) private var connection
    @Environment(AppModel.self) private var app
    @State private var devices: [AudioDevice] = []
    @AppStorage("outputDeviceUID") private var outputDeviceUID = ""
    /// Remembered name of the chosen device, so it can be shown while the
    /// device is disconnected (the UID alone is unreadable).
    @AppStorage("outputDeviceName") private var outputDeviceName = ""
    /// Bit-perfect-style rate matching (PlaybackService reads the same key,
    /// defaulting to on).
    @AppStorage("matchDeviceSampleRate") private var matchSampleRate = true
    /// Scrobbling (PlayerModel reads the same key, defaulting to on).
    @AppStorage("scrobbleEnabled") private var scrobbleEnabled = true
    /// Volume normalization (PlayerModel+ReplayGain reads the same key).
    @AppStorage("replayGainMode") private var replayGainMode = ReplayGainMode.off.rawValue

    /// The chosen device is currently absent (e.g. Bluetooth disconnected).
    /// Audio falls back to the system default; the choice sticks so it re-pins
    /// when the device returns.
    private var selectionDisconnected: Bool {
        !outputDeviceUID.isEmpty && !devices.contains { $0.uid == outputDeviceUID }
    }

    var body: some View {
        @Bindable var connection = connection
        Form {
            Section("Output") {
                Picker("Output Device", selection: $outputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(devices.filter { !$0.isAirPlay }) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // AirPlay routes appear once the system is connected to
                    // them — Control Center owns discovery/connection, so an
                    // unconnected receiver has no audio device to list.
                    ForEach(devices.filter(\.isAirPlay)) { device in
                        Label(device.name, systemImage: "airplay.audio").tag(device.uid)
                    }
                    if selectionDisconnected {
                        Text("\(outputDeviceName.isEmpty ? "Selected device" : outputDeviceName) (disconnected)")
                            .tag(outputDeviceUID)
                    }
                }
                .onChange(of: outputDeviceUID) {
                    let uid = outputDeviceUID.isEmpty ? nil : outputDeviceUID
                    outputDeviceName = devices.first { $0.uid == outputDeviceUID }?.name ?? outputDeviceName
                    Task { await app.playback.setOutputDevice(uid: uid) }
                }
                if selectionDisconnected {
                    Text("Playing through the system default until it reconnects.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Match hardware sample rate", isOn: $matchSampleRate)
                Text("Runs the output device at each track's native sample rate, so nothing is resampled " +
                     "on the way to your DAC. Other apps sharing the device may blip when the rate changes.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Volume normalization", selection: $replayGainMode) {
                    Text("Off").tag(ReplayGainMode.off.rawValue)
                    Text("By Track").tag(ReplayGainMode.track.rawValue)
                    Text("By Album").tag(ReplayGainMode.album.rawValue)
                }
                Text("Evens out loudness between tracks using the files' ReplayGain tags. " +
                     "\u{201C}By Album\u{201D} keeps an album's intended dynamics; changes apply " +
                     "from the next track.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Streaming") {
                Toggle("Report plays to the server", isOn: $scrobbleEnabled)
                Text("Sends listens to the server (\"scrobbling\"), so play counts, " +
                     "recently played and any connected scrobbler stay accurate.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Transcode on the server", isOn: $connection.transcodeEnabled)
                    .onChange(of: connection.transcodeEnabled) { connection.persistTranscodePrefs() }
                if connection.transcodeEnabled {
                    Picker("Format", selection: $connection.transcodeFormat) {
                        Text("MP3").tag("mp3")
                        Text("Opus").tag("opus")
                        Text("AAC").tag("aac")
                    }
                    .onChange(of: connection.transcodeFormat) { connection.persistTranscodePrefs() }
                    Picker("Max Bitrate", selection: $connection.transcodeMaxBitRate) {
                        Text("128 kbps").tag(128)
                        Text("192 kbps").tag(192)
                        Text("256 kbps").tag(256)
                        Text("320 kbps").tag(320)
                    }
                    .onChange(of: connection.transcodeMaxBitRate) { connection.persistTranscodePrefs() }
                } else {
                    Text("Streaming original files.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Enumerate now, then re-enumerate on every device-list change so the
        // picker tracks connects/disconnects live while the pane is open.
        .task {
            devices = AudioOutputDevices.all()
            let changes = AsyncStream<Void> { continuation in
                let observer = AudioDeviceListObserver { continuation.yield(()) }
                continuation.onTermination = { _ in _ = observer }
            }
            for await _ in changes {
                devices = AudioOutputDevices.all()
            }
        }
    }
}
