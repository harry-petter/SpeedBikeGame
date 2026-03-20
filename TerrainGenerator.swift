import SceneKit
import UIKit

enum TerrainGenerator {

    static let chunkSize:  Float = 600.0
    static let gridSize:   Int   = 48
    static let waterLevel: Float = -28.0

    // MARK: - Noise

    private static func hash(_ x: Int, _ y: Int) -> Float {
        var h = x &* 374761393 &+ y &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return Float(h & 0x7fff_ffff) / Float(0x7fff_ffff)
    }

    private static func valueNoise(_ x: Float, _ y: Float) -> Float {
        let ix = Int(floorf(x)), iy = Int(floorf(y))
        let fx = x - floorf(x), fy = y - floorf(y)
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        return hash(ix,   iy  ) * (1-ux) * (1-uy)
             + hash(ix+1, iy  ) *    ux  * (1-uy)
             + hash(ix,   iy+1) * (1-ux) *    uy
             + hash(ix+1, iy+1) *    ux  *    uy
    }

    private static func octave(_ x: Float, _ y: Float, octaves: Int = 5) -> Float {
        var v: Float = 0, amp: Float = 1, freq: Float = 1, total: Float = 0
        for _ in 0..<octaves {
            v += valueNoise(x * freq, y * freq) * amp
            total += amp; amp *= 0.5; freq *= 2
        }
        return v / total
    }

    private static func quintic(_ t: Float) -> Float {
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    // MARK: - Height sampling
    //
    // Scale divisors are 1.7-2× larger than before — terrain features are much
    // wider, so the world feels genuinely vast as you ride through them.

    static func heightAt(x: Float, z: Float) -> Float {
        var h: Float = 0

        // Vast continental tilt — sets the large-scale mood
        h += octave(x / 14000, z / 14000, octaves: 3) * 110
        // Wide sweeping hills — the dominant landscape shape
        h += octave(x / 2400,  z / 2400,  octaves: 4) * 90
        // Rolling mounds — visible as you crest hills
        h += octave(x / 550,   z / 550,   octaves: 3) * 48
        // Surface texture — feels alive underfoot
        h += octave(x / 130,   z / 130,   octaves: 2) * 12
        h -= 50   // push mean slightly below flat so water is common

        // Sharp ridge spines — cut dramatically across the landscape
        let ridgeA = octave(x / 1100, z / 1100, octaves: 3)
        let ridgeB = octave(x / 1700 + 4.1, z / 1700 - 2.7, octaves: 3)
        h += (1 - abs(ridgeA * 2 - 1)) * (1 - abs(ridgeA * 2 - 1)) * 70
        h += (1 - abs(ridgeB * 2 - 1)) * (1 - abs(ridgeB * 2 - 1)) * 50

        // Plateau zones — elevated flat mesas with sharp edges
        let plat = valueNoise(x / 3500 + 3.7, z / 3500 + 8.3)
        if plat > 0.62 {
            let flatH: Float = 35
            h = h + (flatH - h) * quintic((plat - 0.62) / 0.38) * 0.55
        }

        // Wide river valley carving — creates blue water bodies
        let c1 = valueNoise(x / 6500, z / 13000)
        let r1 = 1.0 - abs(c1 * 2.0 - 1.0)
        if r1 > 0.40 { h -= quintic((r1 - 0.40) / 0.60) * 105 }

        let c2 = valueNoise((x + 1700) / 3800, (z + 900) / 9000)
        let r2 = 1.0 - abs(c2 * 2.0 - 1.0)
        if r2 > 0.46 { h -= quintic((r2 - 0.46) / 0.54) * 78 }

        let c3 = valueNoise((x - 800) / 3000, (z + 3200) / 7000)
        let r3 = 1.0 - abs(c3 * 2.0 - 1.0)
        if r3 > 0.52 { h -= quintic((r3 - 0.52) / 0.48) * 58 }

        // Hill clusters — isolated peaks jutting above the plains
        let m1 = valueNoise(x / 5000 + 5.3, z / 5000 + 9.1)
        if m1 > 0.65 { h += quintic((m1 - 0.65) / 0.35) * 65 }

        let m2 = valueNoise(x / 4000 - 2.1, z / 4000 + 4.5)
        if m2 > 0.70 { h += quintic((m2 - 0.70) / 0.30) * 50 }

        return h
    }

    static func clampedHeightAt(x: Float, z: Float) -> Float {
        return max(heightAt(x: x, z: z), waterLevel)
    }

    // MARK: - Colour gradient

    private static func lerp4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        return a + (b - a) * max(0, min(1, t))
    }

    static func colorAt(height h: Float, isWater: Bool = false) -> SIMD4<Float> {
        if isWater {
            return SIMD4<Float>(0.09, 0.36, 0.58, 1)   // deep blue water
        }

        // Sandy shore — tight band just above water
        if h < waterLevel + 7 {
            let t = (h - waterLevel) / 7
            return lerp4(SIMD4<Float>(0.70, 0.64, 0.44, 1),
                         SIMD4<Float>(0.16, 0.48, 0.14, 1), quintic(t))
        }

        let darkGrass = SIMD4<Float>(0.08, 0.28, 0.07, 1)   // deep valley floor
        let lushGrass = SIMD4<Float>(0.16, 0.50, 0.13, 1)   // vivid plains
        let meadow    = SIMD4<Float>(0.24, 0.54, 0.16, 1)   // open meadow
        let dryGrass  = SIMD4<Float>(0.38, 0.50, 0.18, 1)   // upper slopes
        let scrub     = SIMD4<Float>(0.52, 0.47, 0.26, 1)   // rocky scrub
        let stone     = SIMD4<Float>(0.66, 0.63, 0.57, 1)   // bare rock

        if h < 0  { return lerp4(darkGrass, lushGrass, quintic(max(0, (h + 20) / 20))) }
        if h < 45 { return lerp4(lushGrass, meadow, h / 45) }
        if h < 95 { return lerp4(meadow, dryGrass, (h - 45) / 50) }
        if h < 145 { return lerp4(dryGrass, scrub, quintic((h - 95) / 50)) }
        return lerp4(scrub, stone, quintic(min(1, (h - 145) / 60)))
    }

    // MARK: - Chunk generation

    static func generateChunk(cx: Int, cz: Int) -> SCNNode {
        let n    = gridSize
        let cs   = chunkSize
        let step = cs / Float(n - 1)
        let ox   = Float(cx) * cs
        let oz   = Float(cz) * cs

        var positions  = [SCNVector3](); positions.reserveCapacity(n * n)
        var normals    = [SCNVector3](); normals.reserveCapacity(n * n)
        var uvs        = [CGPoint]();    uvs.reserveCapacity(n * n)
        var colorBytes = [Float]();      colorBytes.reserveCapacity(n * n * 4)
        var indices    = [Int32]();      indices.reserveCapacity((n-1)*(n-1)*6)

        for zi in 0..<n {
            for xi in 0..<n {
                let wx   = ox + Float(xi) * step
                let wz   = oz + Float(zi) * step
                let rawH = heightAt(x: wx, z: wz)
                let isWater = rawH < waterLevel
                let h   = isWater ? waterLevel : rawH
                positions.append(SCNVector3(Float(xi) * step, h, Float(zi) * step))

                let e  = step
                let hL = max(heightAt(x: wx - e, z: wz),     isWater ? waterLevel : -9999)
                let hR = max(heightAt(x: wx + e, z: wz),     isWater ? waterLevel : -9999)
                let hB = max(heightAt(x: wx,     z: wz - e), isWater ? waterLevel : -9999)
                let hF = max(heightAt(x: wx,     z: wz + e), isWater ? waterLevel : -9999)
                if isWater {
                    normals.append(SCNVector3(0, 1, 0))
                } else {
                    let nx = hL - hR; let ny = 2 * e; let nz = hB - hF
                    let nl = sqrtf(nx*nx + ny*ny + nz*nz)
                    normals.append(SCNVector3(nx/nl, ny/nl, nz/nl))
                }

                uvs.append(CGPoint(x: Double(xi) / Double(n-1) * 10,
                                   y: Double(zi) / Double(n-1) * 10))

                let c = colorAt(height: rawH, isWater: isWater)
                colorBytes.append(contentsOf: [c.x, c.y, c.z, c.w])
            }
        }

        for zi in 0..<(n-1) {
            for xi in 0..<(n-1) {
                let tl = Int32(zi * n + xi); let tr = tl + 1
                let bl = Int32((zi + 1) * n + xi); let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        let colorData = colorBytes.withUnsafeBytes { Data($0) }
        let colorSrc  = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: n * n,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: 4 * MemoryLayout<Float>.size)

        let geo = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions),
                      SCNGeometrySource(normals: normals),
                      SCNGeometrySource(textureCoordinates: uvs),
                      colorSrc],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )

        let mat = SCNMaterial()
        mat.diffuse.contents  = UIColor.white
        mat.specular.contents = UIColor(white: 0.04, alpha: 1)
        mat.lightingModel     = .lambert
        mat.isDoubleSided     = false
        geo.firstMaterial     = mat

        let node = SCNNode(geometry: geo)
        node.position = SCNVector3(ox, 0, oz)
        node.name     = "chunk_\(cx)_\(cz)"
        return node
    }
}
