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

// The blend modes SwiftUI has no match for, as `BlendModes` in Swift mixes
// them; the numbers are `BlendModes.Custom`'s.

static float burnChannel(float b, float s) {
    return b >= 1.0 ? 1.0 : s <= 0.0 ? 0.0 : max(1.0 - (1.0 - b) / s, 0.0);
}

static float dodgeChannel(float b, float s) {
    return b <= 0.0 ? 0.0 : s >= 1.0 ? 1.0 : min(b / (1.0 - s), 1.0);
}

static float blendChannel(int mode, float b, float s) {
    switch (mode) {
    case 3: return s <= 0.5 ? burnChannel(b, 2.0 * s) : dodgeChannel(b, 2.0 * s - 1.0);
    case 4: return clamp(b + 2.0 * s - 1.0, 0.0, 1.0);
    case 5: return s <= 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0);
    case 6: return b + s >= 1.0 - 1e-4 ? 1.0 : 0.0;
    case 7: return max(b - s, 0.0);
    case 8: return s <= 0.0 ? (b <= 0.0 ? 0.0 : 1.0) : min(b / s, 1.0);
    default: return s;
    }
}

static float dissolveThreshold(int x, int y) {
    uint hash = uint(x) * 0x8DA6B343u ^ uint(y) * 0xD8163841u;
    hash = (hash ^ (hash >> 13)) * 0x5BD1E995u;
    hash ^= hash >> 15;
    return float(hash & 0xFFFFu) / 65536.0;
}

/// A layer mixed over what is beneath it on the canvas. The view drawn is
/// twice as wide as the canvas's: what is beneath on the left, the layer on
/// the right, so both can be read here; the left half shows the result.
/// `origin` and `scale` place the canvas, so dissolve picks the same
/// pixels as when the picture is exported.
[[ stitchable ]] half4 blendLayers(float2 position, SwiftUI::Layer layer, float width, float mode, float2 origin, float scale) {
    if (position.x >= width) {
        return half4(0.0h);
    }
    float4 below = float4(layer.sample(position));
    float4 above = float4(layer.sample(position + float2(width, 0.0)));
    int kind = int(mode);
    float sa = above.a;
    if (sa <= 0.0) {
        return half4(below);
    }
    float3 s = above.rgb / sa;
    if (kind == 0) {
        float2 pixel = floor((position - origin) / scale);
        if (sa <= dissolveThreshold(int(pixel.x), int(pixel.y))) {
            return half4(below);
        }
        return half4(float4(s, 1.0));
    }
    float ba = below.a;
    float3 b = ba > 0.0 ? below.rgb / ba : float3(0.0);
    float3 mixed = s;
    if (kind == 1) {
        mixed = (b.r + b.g + b.b) <= (s.r + s.g + s.b) ? b : s;
    } else if (kind == 2) {
        mixed = (b.r + b.g + b.b) >= (s.r + s.g + s.b) ? b : s;
    } else {
        mixed = float3(blendChannel(kind, b.r, s.r), blendChannel(kind, b.g, s.g), blendChannel(kind, b.b, s.b));
    }
    float3 result = (1.0 - ba) * sa * s + (1.0 - sa) * ba * b + sa * ba * mixed;
    return half4(float4(clamp(result, 0.0, 1.0), sa + ba * (1.0 - sa)));
}
