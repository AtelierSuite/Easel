// WebAssembly here runs on one thread, so parallel loops run in turn. Named
// apart from Dispatch's, which the compiler treats as running concurrently.
public typealias DispatchQueue = SerialLoops

public enum SerialLoops {
    public static func concurrentPerform(iterations: Int, execute work: (Int) -> Void) {
        for i in 0..<max(iterations, 0) { work(i) }
    }
}
