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

/// Each pixel's colour looked up in a `ColorCube`: what an adjustment
/// layer makes of the layers beneath it, on the canvas.
[[ stitchable ]] half4 colorCube(float2 position, half4 color, texture2d<half> cube, float size) {
    if (color.a <= 0.0h) {
        return color;
    }
    float3 rgb = clamp(float3(color.rgb / color.a), 0.0, 1.0) * (size - 1.0);
    float blue = floor(rgb.b);
    float nextBlue = min(blue + 1.0, size - 1.0);
    float along = rgb.b - blue;
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float width = size * size;
    // Within a slice, red and green are interpolated by the sampler;
    // between slices, by hand.
    float2 lower = float2((blue * size + rgb.r + 0.5) / width, (rgb.g + 0.5) / size);
    float2 upper = float2((nextBlue * size + rgb.r + 0.5) / width, (rgb.g + 0.5) / size);
    half3 looked = mix(cube.sample(linear, lower).rgb, cube.sample(linear, upper).rgb, half(along));
    return half4(looked * color.a, color.a);
}
