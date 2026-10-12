#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Each pixel at full opacity, its colour as it was before being faded:
/// what layers clipped to a base mix with on the canvas, before the base's
/// own transparency is put back over them all.
[[ stitchable ]] half4 opaqueColor(float2 position, half4 color) {
    if (color.a <= 0.0h) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    return half4(color.rgb / color.a, 1.0h);
}
