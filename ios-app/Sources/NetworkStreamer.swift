import Foundation
import Network

enum PacketType: UInt8 {
    case videoH264 = 1
    case audioPCM  = 2
    case config    = 3
}

final class NetworkStreamer: ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "Desconectado"
    @Published var discoveredHost: String?

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.salvador.camlink.net", qos: .userInteractive)
    private var inflightVideoPackets = 0
    private let maxInflightVideo = 3
    private var currentHost: String = ""
    private var currentPort: UInt16 = 55880

    func startDiscovery() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_camlink._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if let first = results.first {
                DispatchQueue.main.async {
                    switch first.endpoint {
                    case .service(let name, _, _, _):
                        self.discoveredHost = name
                    case .hostPort(let host, _):
                        self.discoveredHost = "\(host)"
                    default:
                        break
                    }
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    func connect(host: String, port: UInt16 = 55880) {
        disconnect()
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            DispatchQueue.main.async { self.statusText = "IP inválido" }
            return
        }

        currentHost = trimmedHost
        currentPort = port

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle's algorithm for instant frame delivery
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 3

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .interactiveVideo
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: params)

        DispatchQueue.main.async {
            self.statusText = "Conectando a \(trimmedHost)..."
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.isConnected = true
                    self.statusText = "AO VIVO • \(trimmedHost)"
                case .waiting(let err):
                    self.isConnected = false
                    self.statusText = "Aguardando PC (\(err.localizedDescription))"
                case .failed(let err):
                    self.isConnected = false
                    self.statusText = "Falha: \(err.localizedDescription)"
                case .cancelled:
                    self.isConnected = false
                    self.statusText = "Desconectado"
                default:
                    break
                }
            }
        }

        self.connection = conn
        conn.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        queue.async { [weak self] in
            self?.inflightVideoPackets = 0
        }
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusText = "Desconectado"
        }
    }

    func sendConfig(width: Int, height: Int, fps: Int, sampleRate: Int, channels: Int) {
        let dict: [String: Any] = [
            "width": width,
            "height": height,
            "fps": fps,
            "sampleRate": sampleRate,
            "channels": channels
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        sendPacket(type: .config, timestampUs: 0, payload: data)
    }

    func sendPacket(type: PacketType, timestampUs: UInt64, payload: Data) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection, conn.state == .ready else { return }

            if type == .videoH264 {
                if self.inflightVideoPackets >= self.maxInflightVideo {
                    return // Discard late frame immediately to maintain zero buffer lag
                }
                self.inflightVideoPackets += 1
            }

            var header = Data(capacity: 13)
            header.append(type.rawValue)
            var tsBE = timestampUs.bigEndian
            header.append(Data(bytes: &tsBE, count: 8))
            var lenBE = UInt32(payload.count).bigEndian
            header.append(Data(bytes: &lenBE, count: 4))

            var packet = Data(capacity: 13 + payload.count)
            packet.append(header)
            packet.append(payload)

            conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
                if type == .videoH264 {
                    self?.queue.async {
                        self?.inflightVideoPackets = max(0, (self?.inflightVideoPackets ?? 1) - 1)
                    }
                }
            })
        }
    }
}
