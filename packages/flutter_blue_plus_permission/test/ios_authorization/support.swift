import Foundation
import CoreBluetooth

// Replace only the OS boundary; compile the real permission decisions unchanged.
protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
}
final class CBCentralManager: NSObject {
    static var authorization: CBManagerAuthorization = .notDetermined
    var authorization: CBManagerAuthorization { Self.authorization }
    static weak var latest: CBCentralManager?
    weak var delegate: CBCentralManagerDelegate?
    var state: CBManagerState = .unknown
    override init() { super.init() }
    init(delegate: CBCentralManagerDelegate, queue: DispatchQueue?, options: [String: Any]?) {
        self.delegate = delegate
        super.init()
        Self.latest = self
    }
    func emit(_ authorization: CBManagerAuthorization, _ state: CBManagerState) {
        Self.authorization = authorization
        self.state = state
        delegate?.centralManagerDidUpdateState(self)
    }
}
