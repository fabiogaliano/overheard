import Darwin
import Foundation

struct ManualScrobbleRequest: Codable, Sendable, Equatable {
    let artist: String
    let track: String
}

enum ControlRequest: Codable, Sendable, Equatable {
    case manualScrobble(ManualScrobbleRequest)
    case loveLastScrobbledTrack
}

enum ControlIPCError: LocalizedError {
    case invalidSocketPath
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            "Control socket path is invalid"
        case let .socketCreationFailed(message),
             let .bindFailed(message),
             let .listenFailed(message),
             let .connectFailed(message),
             let .writeFailed(message):
            message
        }
    }
}

final class ControlRequestServer {
    private let socketURL: URL
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(socketURL: URL = manualScrobbleSocketFile) {
        self.socketURL = socketURL
    }

    func start(onRequest: @escaping @Sendable (ControlRequest) -> Void) throws {
        stop()
        ensureConfigDir()
        try? FileManager.default.removeItem(at: socketURL)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlIPCError.socketCreationFailed(posixMessage("Failed to create control socket"))
        }

        do {
            try withSocketAddress(for: socketURL.path) { address, length in
                guard bind(fd, address, length) == 0 else {
                    throw ControlIPCError.bindFailed(posixMessage("Failed to bind control socket"))
                }
            }

            guard listen(fd, 8) == 0 else {
                throw ControlIPCError.listenFailed(posixMessage("Failed to listen on control socket"))
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.acceptNextConnection(onRequest: onRequest)
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()

            socketFD = fd
            readSource = source
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }
    }

    func stop() {
        if let readSource {
            socketFD = -1
            readSource.cancel()
            self.readSource = nil
        } else if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptNextConnection(onRequest: @escaping @Sendable (ControlRequest) -> Void) {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }

        let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
        let data = handle.readDataToEndOfFile()
        try? handle.close()

        guard !data.isEmpty else { return }

        do {
            let request = try JSONDecoder().decode(ControlRequest.self, from: data)
            onRequest(request)
        } catch {
            logError("Failed to decode control request: \(error.localizedDescription)")
        }
    }
}

func sendControlRequest(_ request: ControlRequest, socketURL: URL = manualScrobbleSocketFile) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw ControlIPCError.socketCreationFailed(posixMessage("Failed to create control client socket"))
    }
    defer { close(fd) }

    try withSocketAddress(for: socketURL.path) { address, length in
        guard connect(fd, address, length) == 0 else {
            throw ControlIPCError.connectFailed(posixMessage("No running overheard instance found"))
        }
    }

    let data = try JSONEncoder().encode(request)
    let result = data.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress, buffer.count)
    }
    guard result == data.count else {
        throw ControlIPCError.writeFailed(posixMessage("Failed to send control request"))
    }
}

private func withSocketAddress<T>(
    for path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let utf8 = path.utf8CString
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard utf8.count <= capacity else {
        throw ControlIPCError.invalidSocketPath
    }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
            chars.initialize(repeating: 0, count: capacity)
            _ = utf8.withUnsafeBufferPointer { source in
                strncpy(chars, source.baseAddress, capacity - 1)
            }
        }
    }

    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func posixMessage(_ prefix: String) -> String {
    let message = String(cString: strerror(errno))
    return "\(prefix): \(message)"
}
