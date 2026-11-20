import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct ContentView: View {
    @StateObject private var engine = CaptureEngine()
    @AppStorage("pc_ip") private var pcIP: String = "192.168.1.5"
    @State private var isBlackout: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        ZStack {
            CameraPreviewView(session: engine.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                Spacer()
                if let err = engine.permissionError {
                    Text(err)
                        .font(.callout.bold())
                        .padding()
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }
                bottomPanel
            }
            .padding(.vertical, 10)

            if isBlackout {
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 8) {
                            Circle()
                                .fill(engine.streamer.isConnected ? Color.red : Color.gray)
                                .frame(width: 10, height: 10)
                            Text("Modo OLED • Toque 2x para acordar")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.25))
                        }
                    )
                    .onTapGesture(count: 2) {
                        isBlackout = false
                    }
            }
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.streamer.isConnected ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(engine.streamer.statusText)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .cornerRadius(20)

                Spacer()

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }

            // Active Mic + VU Meter bar
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text(engine.activeMicName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule()
                            .fill(engine.audioLevel > 0.8 ? Color.red : Color.green)
                            .frame(width: geo.size.width * CGFloat(engine.audioLevel))
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(14)
        }
        .padding(.horizontal, 16)
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(CameraLens.allCases) { lens in
                    Button {
                        engine.switchLens(lens)
                    } label: {
                        Text(lens.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(engine.selectedLens == lens ? Color.white : Color.black.opacity(0.55))
                            .foregroundColor(engine.selectedLens == lens ? .black : .white)
                            .cornerRadius(16)
                    }
                }
            }

            HStack(spacing: 14) {
                Button {
                    engine.toggleExposureLock()
                } label: {
                    Label(engine.isExposureLocked ? "AF/AE Trav." : "Auto", systemImage: engine.isExposureLocked ? "lock.fill" : "lock.open")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(engine.isExposureLocked ? Color.yellow.opacity(0.85) : Color.black.opacity(0.6))
                        .foregroundColor(engine.isExposureLocked ? .black : .white)
                        .cornerRadius(20)
                }

                Button {
                    if engine.streamer.isConnected {
                        engine.disconnect()
                    } else {
                        engine.connect(to: pcIP)
                    }
                } label: {
                    Text(engine.streamer.isConnected ? "PARAR" : "TRANSMITIR")
                        .font(.headline.bold())
                        .frame(minWidth: 130)
                        .padding(.vertical, 14)
                        .background(engine.streamer.isConnected ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(28)
                }

                Button {
                    isBlackout = true
                } label: {
                    Image(systemName: "moon.fill")
                        .font(.headline)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section("Conexao com o PC (LAN)") {
                    TextField("IP do PC (ex: 192.168.1.5)", text: $pcIP)
                        .keyboardType(.decimalPad)
                    if let found = engine.streamer.discoveredHost {
                        Text("PC detectado na rede: \(found)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                Section("Qualidade de Video (Vertical 1080x1920)") {
                    Picker("FPS", selection: Binding(
                        get: { engine.fps },
                        set: { engine.updateFPS($0) }
                    )) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    .pickerStyle(.segmented)

                    Picker("Bitrate", selection: Binding(
                        get: { engine.bitrateMbps },
                        set: { engine.updateBitrate($0) }
                    )) {
                        Text("4 Mbps").tag(4)
                        Text("8 Mbps (Ideal)").tag(8)
                        Text("12 Mbps (Max)").tag(12)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Espelhar Camera Frontal", isOn: Binding(
                        get: { engine.isMirrored },
                        set: { _ in engine.toggleMirror() }
                    ))
                }

                Section("Microfone (Lapela USB-C)") {
                    ForEach(engine.availableMics, id: \.uid) { mic in
                        Button {
                            engine.configureAudioSession(preferredInput: mic)
                        } label: {
                            HStack {
                                Text(mic.portName)
                                Spacer()
                                if mic.portName == engine.activeMicName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("CamLinkNative")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { showSettings = false }
                }
            }
        }
    }
}
