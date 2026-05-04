import Foundation

struct TestFailure: Error {
    let message: String
    let file: StaticString
    let line: UInt
}

final class TestSuite {
    let name: String
    private(set) var cases: [(String, () throws -> Void)] = []

    init(_ name: String) { self.name = name }

    func test(_ name: String, _ body: @escaping () throws -> Void) {
        cases.append((name, body))
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !condition() {
        throw TestFailure(message: message().isEmpty ? "expectation failed" : message(), file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ note: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        let prefix = note().isEmpty ? "" : "\(note()): "
        throw TestFailure(message: "\(prefix)\(a) != \(b)", file: file, line: line)
    }
}

func expectGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) throws {
    if !(a > b) {
        throw TestFailure(message: "\(a) is not > \(b)", file: file, line: line)
    }
}

func expectLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) throws {
    if !(a < b) {
        throw TestFailure(message: "\(a) is not < \(b)", file: file, line: line)
    }
}

func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws {
    if value != nil {
        throw TestFailure(message: "expected nil, got \(String(describing: value!))", file: file, line: line)
    }
}

func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let v = value else {
        throw TestFailure(message: "expected non-nil", file: file, line: line)
    }
    return v
}

func expectTrue(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    try expect(condition(), message(), file: file, line: line)
}

func expectFalse(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if condition() {
        throw TestFailure(message: message().isEmpty ? "expected false" : message(), file: file, line: line)
    }
}

enum TestRunner {
    static func run(_ suites: [TestSuite]) -> Int32 {
        var passed = 0
        var failures: [(suite: String, name: String, failure: TestFailure)] = []
        var threw: [(suite: String, name: String, error: Error)] = []
        let started = Date()

        for suite in suites {
            for (name, body) in suite.cases {
                do {
                    try body()
                    passed += 1
                    print("  PASS  \(suite.name).\(name)")
                } catch let f as TestFailure {
                    failures.append((suite.name, name, f))
                    print("  FAIL  \(suite.name).\(name)")
                    print("        \(f.message)")
                    print("        at \(f.file):\(f.line)")
                } catch {
                    threw.append((suite.name, name, error))
                    print("  FAIL  \(suite.name).\(name)  (threw: \(error))")
                }
            }
        }

        let total = passed + failures.count + threw.count
        let elapsed = Date().timeIntervalSince(started)
        print("")
        print(String(format: "%d/%d passed in %.2fs", passed, total, elapsed))
        return (failures.isEmpty && threw.isEmpty) ? 0 : 1
    }
}
