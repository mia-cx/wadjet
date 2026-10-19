// Schneider curve fitting, adapted from Paper.js PathFitter.js:
// https://github.com/paperjs/paper.js/blob/cda61e56c0854bb295dbc8e0054e26566cbbab34/src/path/PathFitter.js
// Copyright (c) 2011 - 2020, Jürg Lehni & Jonathan Puckey
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import CoreGraphics

/// One cubic in the stroke's coordinate space, ready for a drawable path.
public struct CubicBezierSegment: Codable, Equatable, Sendable {
    public let start: CGPoint
    public let control1: CGPoint
    public let control2: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    /// Evaluates the cubic at a parameter in 0...1.
    public func point(at t: CGFloat) -> CGPoint {
        evaluate([start, control1, control2, end], at: t)
    }
}

/// Keeps the original samples, including duplicates, so changing Smoothing is lossless.
/// A single distinct point has no cubic segments; draw a dot at `rawPoints.first`.
public struct FittedStroke: Codable, Equatable, Sendable {
    public let rawPoints: [CGPoint]
    public let segments: [CubicBezierSegment]
    public let tolerance: CGFloat

    /// Refits from the original samples, never from already simplified geometry.
    public func refitted(smoothing: CGFloat) -> FittedStroke {
        StrokeFitter.fit(rawPoints, smoothing: smoothing)
    }
}

/// Fits open Brush and Highlighter strokes with Schneider's least-squares method,
/// Newton reparameterization, and subdivision at the largest sample error.
public enum StrokeFitter {
    /// Smoothing is clamped to 0...1 and maps quadratically to 0.25...8 points.
    /// Tolerance bounds sample-to-curve distance, not a continuous Hausdorff bound
    /// on the polyline between samples. Inputs must contain finite coordinates.
    public static func fit(_ rawPoints: [CGPoint], smoothing: CGFloat) -> FittedStroke {
        precondition(smoothing.isFinite && rawPoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let amount = min(1, max(0, smoothing))
        let tolerance = 0.25 + 7.75 * amount * amount
        var points: [CGPoint] = []
        for point in rawPoints where points.last != point { points.append(point) }
        let segments = points.count < 2 ? [] : Fitter(points: points, tolerance: tolerance).fit()
        return FittedStroke(rawPoints: rawPoints, segments: segments, tolerance: tolerance)
    }
}

private struct Fitter {
    let points: [CGPoint]
    let tolerance: CGFloat
    private let epsilon: CGFloat = 1e-12

    private struct Span {
        let first: Int
        let last: Int
        let left: CGPoint
        let right: CGPoint
    }

    func fit() -> [CubicBezierSegment] {
        var pending = [Span(first: 0, last: points.count - 1,
                            left: unit(points[1] - points[0]),
                            right: unit(points[points.count - 2] - points[points.count - 1]))]
        var result: [CubicBezierSegment] = []
        // An explicit stack avoids recursion depth depending on stroke length.
        while let span = pending.popLast() {
            if span.last - span.first == 1 {
                let start = points[span.first], end = points[span.last]
                let length = distance(start, end) / 3
                result.append(CubicBezierSegment(start: start, control1: start + span.left * length,
                                                  control2: end + span.right * length, end: end))
                continue
            }
            var parameters: [CGFloat] = [0]
            for i in (span.first + 1)...span.last {
                parameters.append(parameters.last! + distance(points[i], points[i - 1]))
            }
            let total = parameters.last!
            parameters = parameters.map { $0 / total }
            let squaredTolerance = tolerance * tolerance
            var previousError = max(squaredTolerance, squaredTolerance * squaredTolerance)
            var split = (span.first + span.last) / 2
            var accepted: CubicBezierSegment?
            for _ in 0...4 {
                let curve = generate(span, parameters: parameters)
                var error: CGFloat = 0
                for i in (span.first + 1)..<span.last {
                    let delta = curve.point(at: parameters[i - span.first]) - points[i]
                    let squared = dot(delta, delta)
                    if squared >= error { error = squared; split = i }
                }
                if error <= squaredTolerance { accepted = curve; break }
                if error >= previousError { break }
                let updated = parameters.enumerated().map {
                    root(curve, point: points[span.first + $0.offset], parameter: $0.element)
                }
                guard zip(updated, updated.dropFirst()).allSatisfy({ $0 < $1 }),
                      updated.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { break }
                parameters = updated
                previousError = error
            }
            if let accepted { result.append(accepted); continue }
            let center = unit(points[split - 1] - points[split + 1])
            pending.append(Span(first: split, last: span.last, left: center * -1, right: span.right))
            pending.append(Span(first: span.first, last: split, left: span.left, right: center))
        }
        return result
    }

    private func generate(_ span: Span, parameters: [CGFloat]) -> CubicBezierSegment {
        let start = points[span.first], end = points[span.last]
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0
        var x0: CGFloat = 0, x1: CGFloat = 0
        for (index, u) in parameters.enumerated() {
            let t = 1 - u
            let b0 = t * t * t, b1 = 3 * u * t * t
            let b2 = 3 * u * u * t, b3 = u * u * u
            let a1 = span.left * b1, a2 = span.right * b2
            let residual = points[span.first + index] - start * (b0 + b1) - end * (b2 + b3)
            c00 += dot(a1, a1); c01 += dot(a1, a2); c11 += dot(a2, a2)
            x0 += dot(a1, residual); x1 += dot(a2, residual)
        }
        let determinant = c00 * c11 - c01 * c01
        var alpha1: CGFloat, alpha2: CGFloat
        if abs(determinant) > epsilon {
            alpha1 = (x0 * c11 - x1 * c01) / determinant
            alpha2 = (c00 * x1 - c01 * x0) / determinant
        } else {
            let c0 = c00 + c01, c1 = c01 + c11
            let alpha = abs(c0) > epsilon ? x0 / c0 : (abs(c1) > epsilon ? x1 / c1 : 0)
            alpha1 = alpha; alpha2 = alpha
        }
        let length = distance(start, end)
        let line = end - start
        if alpha1 < epsilon * length || alpha2 < epsilon * length ||
            dot(span.left * alpha1, line) - dot(span.right * alpha2, line) > length * length {
            alpha1 = length / 3; alpha2 = length / 3
        }
        return CubicBezierSegment(start: start, control1: start + span.left * alpha1,
                                  control2: end + span.right * alpha2, end: end)
    }

    private func root(_ curve: CubicBezierSegment, point: CGPoint, parameter u: CGFloat) -> CGFloat {
        let vertices = [curve.start, curve.control1, curve.control2, curve.end]
        let first = zip(vertices.dropFirst(), vertices).map { ($0 - $1) * 3 }
        let second = zip(first.dropFirst(), first).map { ($0 - $1) * 2 }
        let delta = curve.point(at: u) - point
        let derivative = evaluate(first, at: u)
        let denominator = dot(derivative, derivative) + dot(delta, evaluate(second, at: u))
        return abs(denominator) < epsilon ? u : u - dot(delta, derivative) / denominator
    }
}

private func evaluate(_ vertices: [CGPoint], at t: CGFloat) -> CGPoint {
    var work = vertices
    for level in 1..<work.count {
        for index in 0..<(work.count - level) {
            work[index] = work[index] * (1 - t) + work[index + 1] * t
        }
    }
    return work[0]
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
private func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
private func dot(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { lhs.x * rhs.x + lhs.y * rhs.y }
private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }
private func unit(_ point: CGPoint) -> CGPoint {
    let length = hypot(point.x, point.y)
    return length == 0 ? .zero : point * (1 / length)
}
