import Foundation

public enum InkstoneError: Error, CustomStringConvertible {
    case config(String)
    case io(String)
    case pdf(String)
    case ocr(String)
    case vlm(String)
    case state(String)

    public var description: String {
        switch self {
        case .config(let m): return "config: \(m)"
        case .io(let m): return "io: \(m)"
        case .pdf(let m): return "pdf: \(m)"
        case .ocr(let m): return "ocr: \(m)"
        case .vlm(let m): return "vlm: \(m)"
        case .state(let m): return "state: \(m)"
        }
    }

    public var localizedDescription: String { description }
}
