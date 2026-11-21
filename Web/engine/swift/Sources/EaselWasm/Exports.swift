import Foundation

// The engine's whole interface to JavaScript: a C ABI with no dependencies.
//
// The host copies a UTF-8 JSON request (and optionally a byte payload, such as
// a file being opened) into memory it allocated with `easel_alloc`, then calls
// `easel_call`. The response is JSON, plus an optional byte payload (such as a
// file being saved), which the host reads through the `easel_response_*` and
// `easel_payload_*` accessors before making its next call.

private nonisolated(unsafe) var response = Buffer()
private nonisolated(unsafe) var payload = Buffer()

/// Memory owned by the engine that the host reads between calls.
private struct Buffer {
    var pointer: UnsafeMutableRawPointer?
    var count = 0

    mutating func replace(with bytes: some Collection<UInt8>) {
        pointer?.deallocate()
        count = bytes.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 8)
        UnsafeMutableRawBufferPointer(start: pointer, count: count).copyBytes(from: bytes)
    }
}

@_expose(wasm, "easel_alloc")
@_cdecl("easel_alloc")
public func easelAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), 1), alignment: 8)
}

@_expose(wasm, "easel_free")
@_cdecl("easel_free")
public func easelFree(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// Handles one request. Returns 0; failures are reported inside the response.
@_expose(wasm, "easel_call")
@_cdecl("easel_call")
public func easelCall(
    _ request: UnsafeRawPointer, _ requestLength: Int32, _ input: UnsafeRawPointer?, _ inputLength: Int32
) -> Int32 {
    let requestData = Data(bytes: request, count: Int(requestLength))
    let inputData = input.map { Data(bytes: $0, count: Int(inputLength)) }
    // The engine runs on the one thread WebAssembly has, which is the main actor's.
    let (json, output) = MainActor.assumeIsolated { Bridge.shared.handle(requestData, payload: inputData) }
    response.replace(with: json)
    payload.replace(with: output ?? Data())
    return 0
}

@_expose(wasm, "easel_response_pointer")
@_cdecl("easel_response_pointer")
public func easelResponsePointer() -> UnsafeMutableRawPointer? { response.pointer }

@_expose(wasm, "easel_response_length")
@_cdecl("easel_response_length")
public func easelResponseLength() -> Int32 { Int32(response.count) }

@_expose(wasm, "easel_payload_pointer")
@_cdecl("easel_payload_pointer")
public func easelPayloadPointer() -> UnsafeMutableRawPointer? { payload.pointer }

@_expose(wasm, "easel_payload_length")
@_cdecl("easel_payload_length")
public func easelPayloadLength() -> Int32 { Int32(payload.count) }
