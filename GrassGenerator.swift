import SceneKit
import UIKit

/// Generates a terrain-conforming green mesh centred on a world position.
/// Wide radius ensures no raw terrain shows through the grass layer.
enum GrassGenerator {

    static func build(centerX cx: Float, centerZ cz: Float) -> SCNNode {
        let n    = 60           // 60×60 quads
        let half: Float = 150   // 300 m diameter — covers all close-up ground
        let step = half * 2 / Float(n)

        let vertCount = (n + 1) * (n + 1)
        var verts = [SCNVector3](); verts.reserveCapacity(vertCount)
        var norms = [SCNVector3](); norms.reserveCapacity(vertCount)
        var cols  = [Float]();     cols.reserveCapacity(vertCount * 4)
        var idxs  = [Int32]();     idxs.reserveCapacity(n * n * 6)

        var seed: UInt64 = 0x9e3779b97f4a7c15
        seed ^= UInt64(bitPattern: Int64(cx * 73.0 + cz * 1031.0))

        let up = SCNVector3(0, 1, 0)

        for zi in 0...n {
            for xi in 0...n {
                let wx = cx - half + Float(xi) * step
                let wz = cz - half + Float(zi) * step
                let rawH = TerrainGenerator.heightAt(x: wx, z: wz)
                let h    = max(rawH, TerrainGenerator.waterLevel + 0.1)
                // Sit above terrain; extra clearance avoids z-fighting with chunks
                verts.append(SCNVector3(wx, h + 0.12, wz))
                norms.append(up)

                // Natural green variation — no orange/brown tones
                let v = nextRand(&seed)   // full [0,1] range
                let r = Float(0.14 + v * 0.10)   // 0.14–0.24
                let g = Float(0.44 + v * 0.16)   // 0.44–0.60
                let b = Float(0.10 + v * 0.08)   // 0.10–0.18
                cols.append(contentsOf: [r, g, b, 1])
            }
        }

        let stride = n + 1
        for zi in 0..<n {
            for xi in 0..<n {
                let qx  = cx - half + (Float(xi) + 0.5) * step
                let qz  = cz - half + (Float(zi) + 0.5) * step
                let ddx = (qx - cx) / half
                let ddz = (qz - cz) / half
                // Elliptical clip — full coverage within radius
                guard ddx*ddx + ddz*ddz < 0.98 else { continue }
                // Skip underwater tiles
                guard TerrainGenerator.heightAt(x: qx, z: qz) > TerrainGenerator.waterLevel else { continue }

                let tl = Int32(zi * stride + xi)
                let tr = tl + 1
                let bl = Int32((zi + 1) * stride + xi)
                let br = bl + 1
                idxs.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        guard !idxs.isEmpty else { return SCNNode() }

        let colRaw = cols.withUnsafeBytes { Data($0) }
        let colSrc = SCNGeometrySource(data: colRaw, semantic: .color,
                                       vectorCount: vertCount,
                                       usesFloatComponents: true,
                                       componentsPerVector: 4,
                                       bytesPerComponent: MemoryLayout<Float>.size,
                                       dataOffset: 0,
                                       dataStride: 4 * MemoryLayout<Float>.size)
        let geo = SCNGeometry(
            sources: [SCNGeometrySource(vertices: verts),
                      SCNGeometrySource(normals: norms),
                      colSrc],
            elements: [SCNGeometryElement(indices: idxs, primitiveType: .triangles)]
        )

        let mat = SCNMaterial()
        mat.diffuse.contents    = UIColor.white
        mat.isDoubleSided       = false   // back-cull for perf; grass is always above camera
        mat.lightingModel       = .lambert
        mat.writesToDepthBuffer = true
        geo.firstMaterial = mat

        let node = SCNNode(geometry: geo)
        node.name = "grassField"
        return node
    }

    private static func nextRand(_ s: inout UInt64) -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float((s >> 33) & 0x7fffffff) / Float(0x7fffffff)
    }
}
