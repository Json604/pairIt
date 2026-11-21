import Foundation
import CoreBluetooth
import Network

/// Discovers the selected Mac's BLE service, reads its dynamic L2CAP PSM and
/// bridges the encrypted CoC byte stream to a loopback TCP endpoint. TLS still
/// runs above this link and remains the authority for the computer's identity.
final class BluetoothRelayLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    static let service = CBUUID(string: "9C9E1D7A-2A8B-4F2D-9C73-6A51E8C4B210")
    static let psmCharacteristic = CBUUID(string: "9C9E1D7A-2A8B-4F2D-9C73-6A51E8C4B211")

    private let pinPrefix: String
    private let callbackQueue: DispatchQueue
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var candidates: [UUID: (CBPeripheral, NSNumber)] = [:]
    private let preferredIdentifier: UUID?
    private let excludedIdentifiers: Set<UUID>
    private var selectionPending = false
    private var listener: NWListener?
    private var localConnection: NWConnection?
    private var channel: CBL2CAPChannel?
    private var input: InputStream?
    private var output: OutputStream?
    private var pendingOutput = Data()
    private var receivingLoopback = false
    private var sendingInput = false
    private var stopped = false
    private var deadline: DispatchWorkItem?
    var onReady: ((NWEndpoint, UUID) -> Void)?
    var onFailure: ((String) -> Void)?

    init(pin: String, callbackQueue: DispatchQueue, preferredIdentifier: UUID? = nil,
         excludedIdentifiers: Set<UUID> = []) {
        pinPrefix = String(pin.prefix(8)).lowercased()
        self.callbackQueue = callbackQueue
        self.preferredIdentifier = preferredIdentifier
        self.excludedIdentifiers = excludedIdentifiers
        super.init()
    }

    func start() {
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.central = CBCentralManager(delegate: self, queue: .main)
            let deadline = DispatchWorkItem { [weak self] in self?.fail("Bluetooth Mac not found") }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
        }
    }

    func stop() {
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.stopped = true; self.deadline?.cancel(); self.central?.stopScan()
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.input?.close(); self.output?.close(); self.listener?.cancel(); self.localConnection?.cancel()
            self.input = nil; self.output = nil; self.channel = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { fail("Turn on Bluetooth to connect") }
            return
        }
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        guard !excludedIdentifiers.contains(peripheral.identifier) else { return }
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "").lowercased()
        candidates[peripheral.identifier] = (peripheral, RSSI)
        if peripheral.identifier == preferredIdentifier || advertised.contains(pinPrefix) { select(peripheral); return }
        // iOS may omit or truncate the advertised local name. After collecting nearby
        // service matches, try the strongest candidate; pinned TLS rejects a wrong Mac.
        guard !selectionPending else { return }
        selectionPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, self.peripheral == nil else { return }
            if let candidate = self.candidates.values.max(by: { $0.1.intValue < $1.1.intValue })?.0 { self.select(candidate) }
        }
    }

    private func select(_ peripheral: CBPeripheral) {
        guard !stopped, self.peripheral == nil else { return }
        self.peripheral = peripheral; central.stopScan(); peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Couldn’t connect to the Mac over Bluetooth")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        if !stopped { fail("Bluetooth connection ended") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail("Mac Bluetooth service is unavailable"); return
        }
        peripheral.discoverCharacteristics([Self.psmCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let value = service.characteristics?.first(where: { $0.uuid == Self.psmCharacteristic }) else {
            fail("Mac Bluetooth channel is unavailable"); return
        }
        peripheral.readValue(for: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, data.count == 2 else {
            fail("Mac sent an invalid Bluetooth channel"); return
        }
        let psm = data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
        guard psm >= 0x0080 else { fail("Mac sent an invalid Bluetooth channel"); return }
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard error == nil, let channel else { fail("Couldn’t open the Mac Bluetooth channel"); return }
        self.channel = channel; input = channel.inputStream; output = channel.outputStream
        input?.delegate = self; output?.delegate = self
        input?.schedule(in: .main, forMode: .common); output?.schedule(in: .main, forMode: .common)
        input?.open(); output?.open()
        openLoopbackListener()
    }

    private func openLoopbackListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters); self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped, self.localConnection == nil else { connection.cancel(); return }
                self.localConnection = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection, self.localConnection === connection else { return }
                    if case .ready = state { self.receiveLoopback(connection) }
                    if case .failed = state { self.fail("Encrypted Bluetooth bridge failed") }
                }
                connection.start(queue: .main)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                if case .ready = state, let port = listener.port {
                    guard let identifier = self.peripheral?.identifier else { self.fail("Bluetooth Mac selection was lost"); return }
                    self.deadline?.cancel()
                    self.callbackQueue.async { self.onReady?(.hostPort(host: "127.0.0.1", port: port), identifier) }
                } else if case .failed = state { self.fail("Couldn’t create the encrypted Bluetooth bridge") }
            }
            listener.start(queue: .main)
        } catch { fail("Couldn’t create the encrypted Bluetooth bridge") }
    }

    private func receiveLoopback(_ connection: NWConnection) {
        guard !receivingLoopback, pendingOutput.isEmpty else { return }
        receivingLoopback = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak connection] data, _, finished, error in
            guard let self, let connection, self.localConnection === connection, !self.stopped else { return }
            self.receivingLoopback = false
            if let data, !data.isEmpty {
                guard self.pendingOutput.count + data.count <= 262_144 else { self.fail("Bluetooth send buffer is full"); return }
                self.pendingOutput.append(data); self.flushOutput()
            }
            if finished || error != nil { self.stop(); return }
            if self.pendingOutput.isEmpty { self.receiveLoopback(connection) }
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard !stopped else { return }
        switch eventCode {
        case .hasBytesAvailable:
            guard let input, aStream === input else { return }; readInput()
        case .hasSpaceAvailable: flushOutput()
        case .errorOccurred, .endEncountered: fail("Bluetooth connection ended")
        default: break
        }
    }

    private func flushOutput() {
        guard let output else { return }
        while output.hasSpaceAvailable && !pendingOutput.isEmpty {
            let count = pendingOutput.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: pendingOutput.count) }
            if count > 0 { pendingOutput.removeFirst(count) }
            else if count < 0 { fail("Bluetooth send failed"); return }
            else { return }
        }
        if pendingOutput.isEmpty, let localConnection { receiveLoopback(localConnection) }
    }

    private func readInput() {
        guard !sendingInput, let input, input.hasBytesAvailable, let localConnection else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = input.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { fail("Bluetooth receive failed"); return }
        guard count > 0 else { return }
        sendingInput = true
        localConnection.send(content: Data(buffer.prefix(count)), completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.sendingInput = false
                if error != nil { self.fail("Encrypted Bluetooth bridge failed") }
                else { self.readInput() }
            }
        })
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        callbackQueue.async { [weak self] in self?.onFailure?(message) }
        stop()
    }
}
