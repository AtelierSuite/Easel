// The simd functions Paintbrush uses, over the standard library's SIMD types.

@inlinable public func simd_clamp<T: BinaryFloatingPoint>(_ x: T, _ low: T, _ high: T) -> T { min(max(x, low), high) }
@inlinable public func simd_clamp<V: SIMD>(_ x: V, _ low: V, _ high: V) -> V where V.Scalar: FloatingPoint { x.clamped(lowerBound: low, upperBound: high) }
@inlinable public func simd_mix<V: SIMD>(_ a: V, _ b: V, _ t: V) -> V where V.Scalar: FloatingPoint { a + (b - a) * t }
@inlinable public func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * b).sum() }
@inlinable public func simd_length<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * a).sum().squareRoot() }
