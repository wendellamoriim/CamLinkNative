import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Combine

enum CameraLens: String, CaseIterable, Identifiable {
    case front = "Frontal"
    case backWide = "Traseira 1x"
    case backUltraWide = "Ultra 0.5x"
    var id: String { rawValue }
}

final class CaptureEngine: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let streamer = NetworkStreamer()
    private let encoder = H264Encoder()

    private let sessionQueue = DispatchQueue(label: "com.salvador.camlink.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.salvador.camlink.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.salvador.camlink.audio", qos: .userInteractive)

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentVideoDevice: AVCaptureDevice?
    private var lastConfigSentRate: Int = 0

    // UI-bound properties (updated on Main Thread only when values actually change)
    @Published var selectedLens: CameraLens = .front
    @Published var fps: Int = 30
    @Published var bitrateMbps: Int = 8
    @Published var isMirrored: Bool = true
    @Published var isExposureLocked: Bool = false
    @Published var activeMicName: String = "Detectando..."
    @Published var availableMics: [AVAudioSessionPortDescription] = []
    @Published var permissionError: String?

    // Audio level is published through a dedicated throttled Subject to NEVER swamp the SwiftUI main runloop
    let audioLevelSubject = PassthroughSubject<Float, Never>()
    private var lastAudioLevelSendTime: Double = 0.0

    override init() {
        super.init()

        // Critical: Tell AVCaptureSession NOT to tamper with custom AVAudioSession routing!
        session.automaticallyConfiguresApplicationAudioSession = false

        encoder.onEncodedFrame = { [weak self] data, ts in
            self?.streamer.sendPacket(type: .videoH264, timestampUs: ts, payload: data)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        requestPermissions { [weak self] granted in
            guard let self else { return }
            if !granted {
                DispatchQueue.main.async {
                    self.permissionError = "Permita acesso a Câmera e Microfone nos Ajustes do iPhone."
                }
                return
            }

            self.sessionQueue.async {
                self.configureAudioSession()
                self.configureCaptureSession()
                self.encoder.configure(width: 1080, height: 1920, fps: self.fps, bitrateMbps: self.bitrateMbps)
                self.session.startRunning()
            }
            self.streamer.startDiscovery()
        }
    }

    func stop() {
        streamer.disconnect()
        streamer.stopDiscovery()
        encoder.stop()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                completion(videoOK && audioOK)
            }
        }
    }

    func configureAudioSession(preferredInput: AVAudioSessionPortDescription? = nil) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
            )
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setPreferredIOBufferDuration(0.01)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputs = audioSession.availableInputs ?? []
            if let preferred = preferredInput {
                try audioSession.setPreferredInput(preferred)
            } else if let usbMic = inputs.first(where: { $0.portType == .usbAudio }) {
                try audioSession.setPreferredInput(usbMic)
            }

            let currentName = audioSession.currentRoute.inputs.first?.portName ?? "Microfone Interno"
            DispatchQueue.main.async {
                self.availableMics = inputs
                self.activeMicName = currentName
            }
        } catch {
            DispatchQueue.main.async {
                self.activeMicName = "Erro Áudio: \(error.localizedDescription)"
            }
        }
    }

    @objc private func handleAudioRouteChange() {
        sessionQueue.async { [weak self] in
            self?.configureAudioSession()
        }
    }

    private func device(for lens: CameraLens) -> AVCaptureDevice? {
        switch lens {
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .backWide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .backUltraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    private func configureCaptureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        // Video Input
        if let oldV = videoInput {
            session.removeInput(oldV)
            videoInput = nil
        }
        if let dev = device(for: selectedLens), let vIn = try? AVCaptureDeviceInput(device: dev), session.canAddInput(vIn) {
            session.addInput(vIn)
            videoInput = vIn
            currentVideoDevice = dev
            applyFrameRate(to: dev, fps: fps)
        }

        // Audio Input
        if audioInput == nil, let aDev = AVCaptureDevice.default(for: .audio),
           let aIn = try? AVCaptureDeviceInput(device: aDev), session.canAddInput(aIn) {
            session.addInput(aIn)
            audioInput = aIn
        }

        // Video Output
        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }

        // Audio Output
        if !session.outputs.contains(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }

        applyVideoConnectionSettings()
        session.commitConfiguration()
    }

    private func applyVideoConnectionSettings() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (selectedLens == .front) && isMirrored
        }
    }

    private func applyFrameRate(to device: AVCaptureDevice, fps: Int) {
        let target = Double(fps)
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(target))
            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= target && target <= $0.maxFrameRate
            }
            if supported {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func switchLens(_ lens: CameraLens) {
        guard lens != selectedLens else { return }
        selectedLens = lens
        isExposureLocked = false
        sessionQueue.async { [weak self] in
            self?.configureCaptureSession()
        }
    }

    func updateFPS(_ newFPS: Int) {
        guard newFPS != fps else { return }
        fps = newFPS
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.currentVideoDevice else { return }
            self.applyFrameRate(to: dev, fps: newFPS)
            self.encoder.configure(width: 1080, height: 1920, fps: newFPS, bitrateMbps: self.bitrateMbps)
            self.lastConfigSentRate = 0
        }
    }

    func updateBitrate(_ mbps: Int) {
        guard mbps != bitrateMbps else { return }
        bitrateMbps = mbps
        // Fast dynamic bitrate change without tearing down the compression session!
        encoder.updateBitrate(mbps: mbps)
    }

    func toggleMirror() {
        isMirrored.toggle()
        sessionQueue.async { [weak self] in
            self?.applyVideoConnectionSettings()
        }
    }

    func toggleExposureLock() {
        guard let dev = currentVideoDevice else { return }
        isExposureLocked.toggle()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try dev.lockForConfiguration()
                if self.isExposureLocked {
                    if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                    if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                } else {
                    if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                    if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func setFocusAndExposure(at point: CGPoint) {
        guard let dev = currentVideoDevice else { return }
        sessionQueue.async {
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported && dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = point
                    dev.focusMode = .autoFocus
                }
                if dev.isExposurePointOfInterestSupported && dev.isExposureModeSupported(.autoExpose) {
                    dev.exposurePointOfInterest = point
                    dev.exposureMode = .autoExpose
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func connect(to host: String) {
        lastConfigSentRate = 0
        streamer.connect(host: host, port: 55880)
    }

    func disconnect() {
        streamer.disconnect()
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            if streamer.isConnected {
                encoder.encode(sampleBuffer: sampleBuffer)
            }
        } else if output == audioOutput {
            processAudio(sampleBuffer: sampleBuffer)
        }
    }

    private func processAudio(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee
        let sampleRate = Int(asbd.mSampleRate)
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: 0, mData: nil)
        )
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let rawPtr = audioBufferList.mBuffers.mData else { return }
        let byteSize = Int(audioBufferList.mBuffers.mDataByteSize)
        guard byteSize >= 2 else { return }

        let totalSamples = byteSize / 2
        let int16Ptr = rawPtr.assumingMemoryBound(to: Int16.self)

        // Compute RMS for VU meter & build mono Int16 buffer
        var monoData = Data(capacity: (totalSamples / channels) * 2)
        var sumSq: Double = 0
        var count = 0

        if channels == 1 {
            monoData.append(rawPtr.assumingMemoryBound(to: UInt8.self), count: byteSize)
            for i in 0..<totalSamples {
                let s = Double(int16Ptr[i]) / 32768.0
                sumSq += s * s
            }
            count = totalSamples
        } else {
            let frames = totalSamples / channels
            for f in 0..<frames {
                var val = int16Ptr[f * channels]
                monoData.append(Data(bytes: &val, count: 2))
                let s = Double(val) / 32768.0
                sumSq += s * s
            }
            count = frames
        }

        // THROTTLED AUDIO LEVEL UPDATE (max ~15Hz to keep SwiftUI Main Runloop 100% free and responsive)
        if count > 0 {
            let now = CACurrentMediaTime()
            if now - lastAudioLevelSendTime >= 0.066 {
                lastAudioLevelSendTime = now
                let rms = sqrt(sumSq / Double(count))
                let level = Float(min(1.0, max(0.0, rms * 5.0)))
                DispatchQueue.main.async { [weak self] in
                    self?.audioLevelSubject.send(level)
                }
            }
        }

        if streamer.isConnected {
            if lastConfigSentRate != sampleRate {
                lastConfigSentRate = sampleRate
                streamer.sendConfig(width: 1080, height: 1920, fps: fps, sampleRate: sampleRate, channels: 1)
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let tsUs = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000.0)) : 0
            streamer.sendPacket(type: .audioPCM, timestampUs: tsUs, payload: monoData)
        }
    }
}
