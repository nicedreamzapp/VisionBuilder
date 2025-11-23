import CoreImage
import Foundation
import UIKit
@preconcurrency import Vision

// MARK: - SAM2ImageAnalysis - Complete Analysis & Utilities Module

class SAM2ImageAnalysis {
    // MARK: - Binary Mask Processing

    func createOptimalBinaryMask(from mask: MLMultiArray, width: Int, height: Int) -> [UInt8] {
        var binaryMask = [UInt8](repeating: 0, count: width * height)

        // Collect all mask values for statistical analysis
        var allValues: [Float] = []
        for i in 0 ..< (width * height) {
            allValues.append(mask[i].floatValue)
        }

        // Use Otsu's method for optimal threshold (like Python cv2.threshold)
        let threshold = calculateOtsuThreshold(values: allValues)
        print("🎯 Optimal threshold: \(threshold)")

        // Apply threshold to create clean binary mask
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                let value = mask[index].floatValue
                binaryMask[index] = value > threshold ? 255 : 0
            }
        }

        return binaryMask
    }

    func extractMainObject(from binaryMask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var visited = Array(repeating: false, count: width * height)
        var mainObjectMask = [UInt8](repeating: 0, count: width * height)
        var largestSize = 0

        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x

                if binaryMask[index] == 255, !visited[index] {
                    let componentIndices = floodFillConnectedComponent(
                        mask: binaryMask,
                        visited: &visited,
                        startX: x,
                        startY: y,
                        width: width,
                        height: height
                    )

                    if componentIndices.count > largestSize {
                        largestSize = componentIndices.count

                        // Clear previous and set new main object
                        mainObjectMask = [UInt8](repeating: 0, count: width * height)
                        for idx in componentIndices {
                            mainObjectMask[idx] = 255
                        }
                    }
                }
            }
        }

        print("🎯 Main object: \(largestSize) pixels")
        return mainObjectMask
    }

    // MARK: - Otsu's Threshold Algorithm

    private func calculateOtsuThreshold(values: [Float]) -> Float {
        let sortedValues = values.sorted()
        guard !sortedValues.isEmpty else { return 0.5 }

        let minVal = sortedValues.first!
        let maxVal = sortedValues.last!

        // Try different thresholds and find optimal one
        var bestThreshold: Float = 0.5
        var maxVariance: Float = 0

        let steps = 100
        for i in 0 ..< steps {
            let t = minVal + (maxVal - minVal) * Float(i) / Float(steps - 1)

            let (w0, w1, mean0, mean1) = calculateClassStatistics(values: sortedValues, threshold: t)

            if w0 > 0 && w1 > 0 {
                let betweenClassVariance = w0 * w1 * pow(mean0 - mean1, 2)
                if betweenClassVariance > maxVariance {
                    maxVariance = betweenClassVariance
                    bestThreshold = t
                }
            }
        }

        return bestThreshold
    }

    private func calculateClassStatistics(values: [Float], threshold: Float) -> (Float, Float, Float, Float) {
        var count0: Float = 0, count1: Float = 0
        var sum0: Float = 0, sum1: Float = 0

        for value in values {
            if value <= threshold {
                count0 += 1
                sum0 += value
            } else {
                count1 += 1
                sum1 += value
            }
        }

        let total = Float(values.count)
        let w0 = count0 / total
        let w1 = count1 / total
        let mean0 = count0 > 0 ? sum0 / count0 : 0
        let mean1 = count1 > 0 ? sum1 / count1 : 0

        return (w0, w1, mean0, mean1)
    }

    // MARK: - Connected Component Analysis

    private func floodFillConnectedComponent(mask: [UInt8], visited: inout [Bool], startX: Int, startY: Int, width: Int, height: Int) -> [Int] {
        var component: [Int] = []
        var stack: [(Int, Int)] = [(startX, startY)]

        while !stack.isEmpty {
            let (x, y) = stack.removeLast()
            let index = y * width + x

            guard x >= 0, x < width, y >= 0, y < height, !visited[index], mask[index] == 255 else {
                continue
            }

            visited[index] = true
            component.append(index)

            // 4-connected neighbors for clean components
            stack.append(contentsOf: [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
        }

        return component
    }

    // MARK: - Boundary Tracing

    func traceExactBoundary(mask: [UInt8], width: Int, height: Int) -> [CGPoint] {
        // Find starting point (topmost leftmost pixel)
        var startX = -1, startY = -1

        outer: for y in 0 ..< height {
            for x in 0 ..< width {
                if mask[y * width + x] == 255 {
                    startX = x
                    startY = y
                    break outer
                }
            }
        }

        guard startX >= 0, startY >= 0 else { return [] }

        // Use Suzuki-Abe algorithm for perfect boundary tracing (like OpenCV)
        return suzukiAbeBoundaryTrace(mask: mask, startX: startX, startY: startY, width: width, height: height)
    }

    // Suzuki-Abe boundary following algorithm (like OpenCV findContours)
    private func suzukiAbeBoundaryTrace(mask: [UInt8], startX: Int, startY: Int, width: Int, height: Int) -> [CGPoint] {
        var contour: [CGPoint] = []

        // 8-directional chain code (Freeman chain code)
        let directions = [
            (1, 0), // 0: East
            (1, -1), // 1: NE
            (0, -1), // 2: North
            (-1, -1), // 3: NW
            (-1, 0), // 4: West
            (-1, 1), // 5: SW
            (0, 1), // 6: South
            (1, 1), // 7: SE
        ]

        var currentX = startX
        var currentY = startY
        var currentDir = 0 // Start facing east

        let maxIterations = (width + height) * 2 // Prevent infinite loops
        var iterations = 0

        repeat {
            contour.append(CGPoint(x: currentX, y: currentY))

            // Find next boundary pixel using 8-connectivity
            var found = false

            // Start search from current direction - 2 (counter-clockwise)
            let startSearchDir = (currentDir + 6) % 8

            for i in 0 ..< 8 {
                let searchDir = (startSearchDir + i) % 8
                let (dx, dy) = directions[searchDir]
                let nextX = currentX + dx
                let nextY = currentY + dy

                if nextX >= 0, nextX < width, nextY >= 0, nextY < height {
                    let nextIndex = nextY * width + nextX

                    if mask[nextIndex] == 255 {
                        currentX = nextX
                        currentY = nextY
                        currentDir = searchDir
                        found = true
                        break
                    }
                }
            }

            if !found { break }
            iterations += 1

        } while (currentX != startX || currentY != startY) && iterations < maxIterations

        // Apply Douglas-Peucker smoothing for clean contour
        return douglasPeuckerSmooth(contour, epsilon: 1.0)
    }

    // MARK: - Moore Boundary Tracing (Alternative Algorithm)

    func traceBoundaryMoore(mask: [UInt8], startX: Int, startY: Int, width: Int, height: Int) -> [CGPoint] {
        var boundary: [CGPoint] = []

        // 8-directional neighbors (clockwise from top)
        let directions = [
            (0, -1), // N
            (1, -1), // NE
            (1, 0), // E
            (1, 1), // SE
            (0, 1), // S
            (-1, 1), // SW
            (-1, 0), // W
            (-1, -1), // NW
        ]

        var currentX = startX
        var currentY = startY
        var direction = 0 // Start facing north

        let maxSteps = width + height // Reasonable limit
        var steps = 0

        repeat {
            boundary.append(CGPoint(x: currentX, y: currentY))

            // Look for next boundary pixel
            var found = false

            // Start searching from left of current direction
            let startDir = (direction + 6) % 8 // 90 degrees counter-clockwise

            for i in 0 ..< 8 {
                let checkDir = (startDir + i) % 8
                let (dx, dy) = directions[checkDir]
                let nextX = currentX + dx
                let nextY = currentY + dy

                guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else {
                    continue
                }

                if mask[nextY * width + nextX] == 255 {
                    currentX = nextX
                    currentY = nextY
                    direction = checkDir
                    found = true
                    break
                }
            }

            if !found { break }
            steps += 1

        } while (currentX != startX || currentY != startY) && steps < maxSteps

        return boundary
    }

    // MARK: - Smoothing Algorithms

    func douglasPeuckerSmooth(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }

        return douglasPeuckerRecursive(points, epsilon: epsilon)
    }

    private func douglasPeuckerRecursive(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }

        let start = points.first!
        let end = points.last!

        var maxDistance = 0.0
        var maxIndex = 0

        for i in 1 ..< (points.count - 1) {
            let distance = perpendicularDistance(point: points[i], lineStart: start, lineEnd: end)
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = i
            }
        }

        if maxDistance > epsilon {
            let left = Array(points[0 ... maxIndex])
            let right = Array(points[maxIndex ..< points.count])

            let leftSmooth = douglasPeuckerRecursive(left, epsilon: epsilon)
            let rightSmooth = douglasPeuckerRecursive(right, epsilon: epsilon)

            return leftSmooth + Array(rightSmooth.dropFirst())
        } else {
            return [start, end]
        }
    }

    func applyGaussianSmoothing(_ points: [CGPoint], sigma: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var smoothed: [CGPoint] = []
        let kernelSize = Int(sigma * 3) * 2 + 1
        let weights = generateGaussianKernel(size: kernelSize, sigma: sigma)

        for i in 0 ..< points.count {
            var weightedX: Double = 0
            var weightedY: Double = 0
            var totalWeight: Double = 0

            let halfKernel = kernelSize / 2

            for j in -halfKernel ... halfKernel {
                let index = (i + j + points.count) % points.count // Wrap around
                let weight = weights[j + halfKernel]

                weightedX += Double(points[index].x) * weight
                weightedY += Double(points[index].y) * weight
                totalWeight += weight
            }

            smoothed.append(CGPoint(
                x: weightedX / totalWeight,
                y: weightedY / totalWeight
            ))
        }

        return smoothed
    }

    private func generateGaussianKernel(size: Int, sigma: Double) -> [Double] {
        var kernel: [Double] = []
        let center = size / 2
        let coefficient = 1.0 / (sqrt(2 * .pi) * sigma)

        for i in 0 ..< size {
            let x = Double(i - center)
            let value = coefficient * exp(-(x * x) / (2 * sigma * sigma))
            kernel.append(value)
        }

        return kernel
    }

    func applySophisticatedSmoothing(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3 else { return points }

        // Step 1: Gaussian smoothing for natural curves
        let gaussianSmoothed = applyGaussianSmoothing(points, sigma: 1.5)

        // Step 2: Douglas-Peucker simplification for efficiency
        let simplified = douglasPeuckerSimplify(gaussianSmoothed, epsilon: 1.5)

        // Step 3: Final smoothing pass
        return applyGaussianSmoothing(simplified, sigma: 0.8)
    }

    // MARK: - Geometric Utilities

    func perpendicularDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> Double {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y

        if dx == 0 && dy == 0 {
            return sqrt(pow(Double(point.x - lineStart.x), 2) + pow(Double(point.y - lineStart.y), 2))
        }

        let t = max(0, min(1, Double((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / Double(dx * dx + dy * dy)))

        let projectionX = lineStart.x + CGFloat(t) * dx
        let projectionY = lineStart.y + CGFloat(t) * dy

        return sqrt(pow(Double(point.x - projectionX), 2) + pow(Double(point.y - projectionY), 2))
    }

    func pointToLineDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> Double {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y

        if dx == 0 && dy == 0 {
            // Line start and end are the same point
            let px = point.x - lineStart.x
            let py = point.y - lineStart.y
            return sqrt(Double(px * px + py * py))
        }

        let t = max(0, min(1, Double((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / Double(dx * dx + dy * dy)))

        let projectionX = lineStart.x + CGFloat(t) * dx
        let projectionY = lineStart.y + CGFloat(t) * dy

        let distX = point.x - projectionX
        let distY = point.y - projectionY

        return sqrt(Double(distX * distX + distY * distY))
    }

    func calculatePreciseBoundingBox(from contour: [CGPoint]) -> CGRect {
        guard !contour.isEmpty else { return CGRect.zero }

        let minX = contour.map { $0.x }.min()!
        let maxX = contour.map { $0.x }.max()!
        let minY = contour.map { $0.y }.min()!
        let maxY = contour.map { $0.y }.max()!

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func calculateContourArea(_ contour: [CGPoint]) -> Double {
        guard contour.count > 2 else { return 0 }

        var area: Double = 0
        let n = contour.count

        for i in 0 ..< n {
            let j = (i + 1) % n
            area += Double(contour[i].x * contour[j].y)
            area -= Double(contour[j].x * contour[i].y)
        }

        return abs(area) / 2.0
    }

    // MARK: - Douglas-Peucker Line Simplification

    private func douglasPeuckerSimplify(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }

        return douglasPeuckerRecursive(points, epsilon: epsilon)
    }

    // MARK: - Advanced Contour Processing

    func findMaskContours(binaryMask: [UInt8], width: Int, height: Int) -> [[CGPoint]] {
        // First, find the largest connected component (main object)
        let mainObjectMask = extractLargestConnectedComponent(binaryMask: binaryMask, width: width, height: height)

        // Then find its outer boundary contour
        if let outerContour = findOuterBoundary(mask: mainObjectMask, width: width, height: height) {
            let smoothedContour = applySophisticatedSmoothing(outerContour)
            print("🎯 Found main object contour with \(smoothedContour.count) points")
            return [smoothedContour]
        }

        print("⚠️ Could not find main object boundary")
        return []
    }

    private func extractLargestConnectedComponent(binaryMask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var visited = Array(repeating: false, count: width * height)
        var largestComponent: [UInt8] = Array(repeating: 0, count: width * height)
        var largestSize = 0

        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x

                if binaryMask[index] == 255, !visited[index] {
                    // Found new connected component - measure its size
                    let componentPixels = floodFillComponent(
                        mask: binaryMask,
                        visited: &visited,
                        startX: x,
                        startY: y,
                        width: width,
                        height: height
                    )

                    if componentPixels.count > largestSize {
                        // This is the largest component so far
                        largestSize = componentPixels.count

                        // Clear previous largest and mark new one
                        largestComponent = Array(repeating: 0, count: width * height)
                        for pixelIndex in componentPixels {
                            largestComponent[pixelIndex] = 255
                        }
                    }
                }
            }
        }

        print("🎯 Largest component has \(largestSize) pixels")
        return largestComponent
    }

    private func floodFillComponent(mask: [UInt8], visited: inout [Bool], startX: Int, startY: Int, width: Int, height: Int) -> [Int] {
        var component: [Int] = []
        var stack: [(Int, Int)] = [(startX, startY)]

        while !stack.isEmpty {
            let (x, y) = stack.removeLast()
            let index = y * width + x

            // Check bounds and if already visited
            guard x >= 0, x < width, y >= 0, y < height, !visited[index] else {
                continue
            }

            // Check if this pixel is part of the mask
            guard mask[index] == 255 else {
                continue
            }

            // Mark as visited and add to component
            visited[index] = true
            component.append(index)

            // Add 4-connected neighbors (more conservative than 8-connected)
            let neighbors = [
                (x, y - 1), (x + 1, y), (x, y + 1), (x - 1, y),
            ]

            for neighbor in neighbors {
                stack.append(neighbor)
            }
        }

        return component
    }

    private func findOuterBoundary(mask: [UInt8], width: Int, height: Int) -> [CGPoint]? {
        // Find the topmost pixel of the object (good starting point)
        var startX = -1, startY = -1

        outer: for y in 0 ..< height {
            for x in 0 ..< width {
                if mask[y * width + x] == 255 {
                    startX = x
                    startY = y
                    break outer
                }
            }
        }

        guard startX >= 0, startY >= 0 else { return nil }

        // Trace the boundary using Moore neighbor tracing
        return traceBoundaryMoore(mask: mask, startX: startX, startY: startY, width: width, height: height)
    }
}

// MARK: - Supporting Types

struct SAM2ObjectCluster: Identifiable {
    let id: String
    let representativeImage: UIImage
    var count: Int
    let confidence: Float
    var boundingBoxes: [CGRect]
}

struct SAM2ObjectInfo {
    let clusterId: String
    let boundingBox: CGRect
    let confidence: Float
}

struct SAM2MorningQuestion: Identifiable {
    let id: UUID
    let clusterId: String
    let representativeImage: UIImage
    let question: String
    let options: [String]
    let totalInstances: Int
}

enum SAM2Error: Error {
    case imagePreparationFailed
    case modelOutputError
    case modelNotLoaded
}
