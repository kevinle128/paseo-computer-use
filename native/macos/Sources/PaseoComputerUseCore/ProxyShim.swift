import Darwin
import Foundation

public enum ProxyShim {
    public static func run(arguments: [String]) -> Never {
        func optionValue(_ flag: String) -> String? {
            guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else {
                return nil
            }
            return arguments[idx + 1]
        }

        guard let socketPath = optionValue("--socket"), !socketPath.isEmpty else {
            FileHandle.standardError.write(Data("paseo-computer-use-mcp: missing --socket <path>\n".utf8))
            exit(1)
        }

        let clientId = optionValue("--client") ?? ""
        let provider = optionValue("--provider") ?? ""
        let env = ProcessInfo.processInfo.environment
        let agentId: Any = env["PASEO_AGENT_ID"] ?? NSNull()
        let agentCwd: Any = env["PASEO_AGENT_CWD"] ?? NSNull()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("paseo-computer-use-mcp: socket() failed\n".utf8))
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = Array(socketPath.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8Path.count <= maxLen else {
            FileHandle.standardError.write(Data("paseo-computer-use-mcp: socket path too long\n".utf8))
            Darwin.close(fd)
            exit(1)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            let rawPtr = UnsafeMutableRawPointer(sunPathPtr).assumingMemoryBound(to: CChar.self)
            for (i, ch) in utf8Path.enumerated() {
                rawPtr[i] = ch
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let errStr = String(cString: strerror(errno))
            FileHandle.standardError.write(
                Data("paseo-computer-use-mcp: cannot connect to \(socketPath): \(errStr)\n".utf8)
            )
            Darwin.close(fd)
            exit(1)
        }

        let helloPayload: [String: Any] = [
            "hello": [
                "clientId": clientId,
                "provider": provider,
                "agentId": agentId,
                "agentCwd": agentCwd,
                "pid": Int(getpid()),
                "ppid": Int(getppid()),
            ]
        ]

        if let helloData = try? JSONSerialization.data(withJSONObject: helloPayload),
           var helloLine = String(data: helloData, encoding: .utf8) {
            helloLine.append("\n")
            _ = writeAll(fd: fd, bytes: Array(helloLine.utf8))
        }

        let stdinToSocket = Thread {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                if n > 0 {
                    if !writeAll(fd: fd, bytes: Array(buf[0..<n])) {
                        break
                    }
                } else if n == 0 {
                    Darwin.shutdown(fd, SHUT_WR)
                    break
                } else if errno != EINTR {
                    break
                }
            }
        }
        stdinToSocket.start()

        var sockBuf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &sockBuf, sockBuf.count)
            if n > 0 {
                if !writeAll(fd: STDOUT_FILENO, bytes: Array(sockBuf[0..<n])) {
                    break
                }
            } else if n == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }

        Darwin.close(fd)
        exit(0)
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
