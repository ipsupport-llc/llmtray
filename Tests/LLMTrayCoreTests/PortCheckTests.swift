import Darwin
import XCTest
@testable import LLMTrayCore

final class PortCheckTests: XCTestCase {
    /// A listener on a port the system picks: its fd and port.
    private func listen(loopback: Bool = true) throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = (loopback ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw XCTSkip("can't listen here")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    func testAListeningPortIsInUseAndFreeOnceClosed() throws {
        let (fd, port) = try listen()
        XCTAssertTrue(PortCheck.isInUse(port))
        close(fd)
        XCTAssertFalse(PortCheck.isInUse(port), "closed: free again")
    }

    func testAListenerOnEveryInterfaceCounts() throws {
        let (fd, port) = try listen(loopback: false)
        defer { close(fd) }
        XCTAssertTrue(PortCheck.isInUse(port))
    }

    func testPortsOutsideTheRangeAreNeverOffered() {
        XCTAssertTrue(PortCheck.isInUse(80))
        XCTAssertTrue(PortCheck.isInUse(70000))
    }

    func testNextFreeSkipsTakenPortsAndWraps() {
        let taken: Set<Int> = [8766, 8767]
        XCTAssertEqual(PortCheck.nextFree(after: 8765) { taken.contains($0) }, 8768)
        XCTAssertEqual(PortCheck.nextFree(after: 65535) { _ in false }, 1024, "wraps round to the start of the range")
        XCTAssertNil(PortCheck.nextFree(after: 8765, limit: 5) { _ in true }, "gives up")
    }

    func testNextFreeFindsARealOne() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let next = try XCTUnwrap(PortCheck.nextFree(after: port - 1))
        XCTAssertNotEqual(next, port)
        XCTAssertFalse(PortCheck.isInUse(next))
    }
}
