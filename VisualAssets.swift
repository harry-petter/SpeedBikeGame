import SceneKit
import UIKit

/// Reusable, opaque meshes. Detail is in silhouettes and vertex colours, not layers of transparency.
enum VisualAssets {
    /// SceneKit's Intel simulator backend rejects the single-channel sRGB images
    /// UIKit can choose for greyscale drawings. Keep every generated texture RGBA8.
    private static func rgba8(_ image: UIImage) -> UIImage {
        guard let source = image.cgImage,
              let context = CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage().map { UIImage(cgImage: $0) } ?? image
    }
    static func environment() -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return rgba8(UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256), format: f).image { ctx in
            let colors = [UIColor(red: 0.13, green: 0.24, blue: 0.40, alpha: 1).cgColor,
                          UIColor(red: 0.62, green: 0.70, blue: 0.72, alpha: 1).cgColor,
                          UIColor(red: 0.13, green: 0.16, blue: 0.09, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray, locations: [0, 0.5, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
            ctx.cgContext.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 90, y: 50, width: 65, height: 28))
        })
    }

    static func bark() -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return rgba8(UIGraphicsImageRenderer(size: CGSize(width: 128, height: 512), format: f).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.65, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 512))
            for i in 0..<96 {
                let x = CGFloat((i * 47) % 128)
                c.setStrokeColor(UIColor(white: i % 3 == 0 ? 0.3 : 0.82, alpha: 0.65).cgColor)
                c.setLineWidth(i % 3 == 0 ? 1.5 : 0.65)
                c.move(to: CGPoint(x: x, y: 0))
                for y in stride(from: 0, through: 512, by: 16) {
                    c.addLine(to: CGPoint(x: x + sin(CGFloat(y) * 0.024 + CGFloat(i)) * 2, y: CGFloat(y)))
                }
                c.strokePath()
            }
        })
    }
    /// One opaque draw call per distant sector, in place of hundreds of tree parts.
    static func forestProxy(for detail: SCNNode) -> SCNGeometry {
        var mesh = Mesh()
        for node in detail.childNodes {
            let b = node.boundingBox
            let low = node.convertPosition(b.min, to: detail)
            let high = node.convertPosition(b.max, to: detail)
            let height = high.y - low.y
            guard height > 5 else { continue }
            let center = SIMD3<Float>((low.x + high.x) * 0.5, low.y, (low.z + high.z) * 0.5)
            let radius = max(0.5, max(high.x - low.x, high.z - low.z) * 0.5)
            let canopyBase = center + SIMD3<Float>(0, height * 0.60, 0)
            let top = center + SIMD3<Float>(0, height, 0)
            let bottom = center + SIMD3<Float>(0, height * 0.43, 0)
            for i in 0..<8 {
                let a = Float(i) * .pi / 4, next = Float(i + 1) * .pi / 4
                let p = canopyBase + SIMD3<Float>(cos(a) * radius, 0, sin(a) * radius)
                let q = canopyBase + SIMD3<Float>(cos(next) * radius, 0, sin(next) * radius)
                let c = SIMD4<Float>(0.14, 0.32 + sin(a) * 0.025, 0.09, 1)
                mesh.triangle(p, top, q, c)
                mesh.triangle(p, q, bottom, c * SIMD4<Float>(0.8, 0.8, 0.8, 1))
                let r = min(radius * 0.14, height * 0.018)
                let trunkA = center + SIMD3<Float>(cos(a) * r, 0, sin(a) * r)
                let trunkB = center + SIMD3<Float>(cos(next) * r, 0, sin(next) * r)
                let tip = center + SIMD3<Float>(0, height * 0.75, 0)
                mesh.triangle(trunkA, tip, trunkB, .init(0.22, 0.15, 0.09, 1))
            }
        }
        let mat = material(.white)
        mat.lightingModel = .lambert
        return mesh.geometry(material: mat)
    }
    static func groundDetail() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return rgba8(UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            let c = context.cgContext
            c.setFillColor(UIColor(white: 0.8, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            var seed: UInt64 = 471
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1
                return CGFloat((seed >> 32) & 65535) / 65535
            }
            for _ in 0..<8000 {
                c.setFillColor(UIColor(white: 0.55 + random() * 0.45, alpha: 1).cgColor)
                c.fill(CGRect(x: random() * 256, y: random() * 256, width: 1 + random() * 2, height: 1 + random() * 3))
            }
        })
    }

    static func trunk(radius: Float, height: Float, material: SCNMaterial, seed: Int) -> SCNGeometry {
        let root = SCNNode()
        let trunk = SCNCone(topRadius: CGFloat(radius * 0.38), bottomRadius: CGFloat(radius),
                            height: CGFloat(height))
        trunk.radialSegmentCount = 9; trunk.firstMaterial = material
        root.addChildNode(SCNNode(geometry: trunk))
        for i in 0..<5 {
            let angle = Float(i) * 2.399 + Float(seed)
            let start = SIMD3<Float>(0, height * (-0.03 + Float(i) * 0.07), 0)
            let end = start + SIMD3<Float>(cos(angle) * height * 0.12, height * 0.13, sin(angle) * height * 0.12)
            let branch = SCNCone(topRadius: CGFloat(radius * 0.07), bottomRadius: CGFloat(radius * 0.4),
                                 height: CGFloat(simd_distance(start, end)))
            branch.radialSegmentCount = 5; branch.firstMaterial = material
            let node = SCNNode(geometry: branch); node.simdPosition = (start + end) * 0.5
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(end - start))
            root.addChildNode(node)
        }
        let result = root.flattenedClone().geometry!
        result.levelsOfDetail = [SCNLevelOfDetail(geometry: trunk, worldSpaceDistance: 180)]
        return result
    }
    struct Mesh {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        var indices: [Int32] = []

        mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ color: SIMD4<Float>) {
            let cross = simd_cross(b - a, c - a)
            guard simd_length_squared(cross) > 0.00000001 else { return }
            let normal = simd_normalize(cross)
            let base = Int32(vertices.count)
            for p in [a, b, c] {
                vertices.append(SCNVector3(p.x, p.y, p.z))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
                colors.append(color)
            }
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        func geometry(material: SCNMaterial) -> SCNGeometry {
            guard !vertices.isEmpty else { return SCNGeometry() }
            let source = SCNGeometrySource(data: colors.withUnsafeBytes { Data($0) }, semantic: .color,
                vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4,
                bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals), source],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
            g.firstMaterial = material
            return g
        }
    }

    static func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.8) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    /// Closed eight-sided cross sections give the armour a designed, tapered silhouette.
    static func hull(sections: [(z: Float, width: Float, height: Float, y: Float)], material: SCNMaterial) -> SCNGeometry {
        var mesh = Mesh()
        let profile: [SIMD2<Float>] = [.init(-0.7, 1), .init(0.7, 1), .init(1, 0.45), .init(1, -0.45),
            .init(0.7, -1), .init(-0.7, -1), .init(-1, -0.45), .init(-1, 0.45)]
        let rings = sections.map { s in profile.map { SIMD3<Float>($0.x * s.width, s.y + $0.y * s.height, s.z) } }
        for i in 0..<(rings.count - 1) {
            for j in 0..<8 {
                let k = (j + 1) % 8
                let shade: Float = j == 0 ? 1 : 0.86
                let color = SIMD4<Float>(shade, shade, shade, 1)
                mesh.triangle(rings[i][j], rings[i + 1][j], rings[i][k], color)
                mesh.triangle(rings[i][k], rings[i + 1][j], rings[i + 1][k], color)
            }
        }
        for j in 1..<7 {
            mesh.triangle(rings[0][0], rings[0][j], rings[0][j + 1], .init(repeating: 1))
            let end = rings.count - 1
            mesh.triangle(rings[end][0], rings[end][j + 1], rings[end][j], .init(repeating: 1))
        }
        return mesh.geometry(material: material)
    }

    static func bike() -> SCNNode {
        let root = SCNNode()
        // A small shared palette lets flattenedClone batch the entire static model by material.
        let armor = material(UIColor(red: 0.34, green: 0.28, blue: 0.19, alpha: 1), metal: 0.65, rough: 0.37)
        let ivory = material(UIColor(red: 0.70, green: 0.68, blue: 0.55, alpha: 1), metal: 0.35, rough: 0.42)
        let dark = material(UIColor(white: 0.075, alpha: 1), metal: 0.65, rough: 0.48)
        let steel = material(UIColor(red: 0.32, green: 0.37, blue: 0.39, alpha: 1), metal: 0.8, rough: 0.29)
        let seat = material(UIColor(red: 0.11, green: 0.075, blue: 0.055, alpha: 1), rough: 0.9)
        let accent = material(UIColor(red: 0.52, green: 0.12, blue: 0.055, alpha: 1), metal: 0.4, rough: 0.5)
        let glow = material(UIColor(red: 0.04, green: 0.24, blue: 0.30, alpha: 1))
        glow.emission.contents = UIColor(red: 0.1, green: 0.7, blue: 0.9, alpha: 1)
        func add(_ g: SCNGeometry, _ p: SCNVector3 = SCNVector3Zero, _ angles: SCNVector3 = SCNVector3Zero) {
            let n = SCNNode(geometry: g); n.position = p; n.eulerAngles = angles; root.addChildNode(n)
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, _ p: SCNVector3) {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: min(h, w) * 0.16)
            g.chamferSegmentCount = 1; g.firstMaterial = m; add(g, p)
        }
        func cylinder(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial, _ p: SCNVector3, axis: SCNVector3 = SCNVector3(Float.pi / 2, 0, 0)) {
            let g = SCNCylinder(radius: r, height: h); g.radialSegmentCount = 12; g.firstMaterial = m; add(g, p, axis)
        }
        add(hull(sections: [(-1.5, 0.18, 0.1, 0), (-0.7, 0.40, 0.23, 0),
            (0.65, 0.44, 0.26, 0), (1.7, 0.31, 0.17, 0)], material: armor))
        add(hull(sections: [(-1.4, 0.12, 0.04, 0.18), (-0.6, 0.34, 0.07, 0.25),
            (0.2, 0.31, 0.07, 0.28)], material: ivory))
        box(0.5, 0.15, 1.15, seat, .init(0, 0.32, 0.72))
        box(0.08, 0.018, 0.9, accent, .init(0.12, 0.34, -0.45))
        box(0.18, 0.035, 0.2, glow, .init(0, 0.34, -0.7))
        for side: Float in [-1, 1] {
            // Exposed twin spars, split steering vanes and front sensor housings.
            cylinder(0.055, 2.8, steel, .init(side * 0.29, -0.035, -2.65))
            add(hull(sections: [(-4.25, 0.06, 0.035, 0), (-3.65, 0.28, 0.075, 0),
                (-2.85, 0.13, 0.055, 0)], material: ivory), .init(side * 0.30, 0, 0), .init(0, 0, side * 0.12))
            cylinder(0.085, 0.4, dark, .init(side * 0.29, -0.035, -1.55))
            cylinder(0.028, 0.035, glow, .init(side * 0.29, 0.005, -4.21))
            cylinder(0.20, 1.85, dark, .init(side * 0.48, -0.12, 0.65))
            cylinder(0.22, 0.32, armor, .init(side * 0.48, -0.12, 1.48))
            for z: Float in [-0.1, 0.05, 0.2, 1.1, 1.25] {
                cylinder(0.215, 0.035, steel, .init(side * 0.48, -0.12, z))
            }
            for i in 0..<6 {
                box(0.08, 0.025, 0.32, dark, .init(side * 0.37, 0.18, Float(i) * 0.12 + 0.4))
            }
            box(0.32, 0.07, 0.42, dark, .init(side * 0.5, -0.27, 0.65))
            cylinder(0.024, 0.64, steel, .init(side * 0.23, 0.38, -0.63), axis: .init(0, 0, side * 0.65))
            cylinder(0.042, 0.25, seat, .init(side * 0.48, 0.57, -0.63), axis: .init(0, 0, Float.pi / 2))
            add(hull(sections: [(1.1, 0.12, 0.03, 0), (1.75, 0.36, 0.04, 0),
                (2, 0.24, 0.025, 0)], material: armor), .init(side * 0.43, 0.07, 0), .init(0, 0, side * 0.28))
        }
        // Saddle-mounted scout: articulated silhouette reads as a bike and rider at chase distance.
        let suit = material(UIColor(red: 0.16, green: 0.19, blue: 0.14, alpha: 1), rough: 0.94)
        func limb(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) {
            let delta = b - a
            let g = SCNCapsule(capRadius: radius, height: CGFloat(simd_length(delta)) + radius)
            g.radialSegmentCount = 8; g.capSegmentCount = 3; g.firstMaterial = material
            let n = SCNNode(geometry: g); n.simdPosition = (a + b) * 0.5
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta)); root.addChildNode(n)
        }
        add(hull(sections: [(-0.15, 0.22, 0.31, 0.85), (0.40, 0.20, 0.27, 0.76)], material: suit))
        box(0.32, 0.38, 0.16, armor, .init(0, 0.87, 0.49))
        let helmet = SCNSphere(radius: 0.23); helmet.segmentCount = 16; helmet.firstMaterial = ivory
        add(helmet, .init(0, 1.24, -0.14))
        box(0.37, 0.09, 0.08, dark, .init(0, 1.24, -0.34))
        for s: Float in [-1, 1] {
            limb(.init(s * 0.19, 0.60, 0.6), .init(s * 0.46, 0.25, 0.03), radius: 0.105, material: suit)
            limb(.init(s * 0.46, 0.25, 0.03), .init(s * 0.48, -0.16, 0.64), radius: 0.075, material: dark)
            limb(.init(s * 0.23, 1.03, -0.12), .init(s * 0.39, 0.79, -0.34), radius: 0.08, material: ivory)
            limb(.init(s * 0.39, 0.79, -0.34), .init(s * 0.46, 0.58, -0.63), radius: 0.065, material: suit)
        }
        return root.flattenedClone()
    }

    /// Layered crowns with uneven lobes; all leaves use opaque geometry and one shared material.
    static func foliage(radius: Float, pine: Bool, seed: Int, material: SCNMaterial, detailed: Bool = true) -> SCNGeometry {
        var mesh = Mesh()
        let count = detailed ? (pine ? 5 : 9) : (pine ? 3 : 3)
        let segments = detailed ? 9 : 6
        for lobe in 0..<count {
            let phase = Float(lobe) * 2.399 + Float(seed)
            let r = radius * (pine ? (1 - Float(lobe) * 0.13) : (lobe == 0 ? 0.72 : 0.46))
            let center = pine ? SIMD3<Float>(0, Float(lobe - 2) * radius * 0.55, 0) :
                SIMD3<Float>(cos(phase) * radius * (lobe == 0 ? 0 : 0.55), sin(phase * 1.7) * radius * 0.28, sin(phase) * radius * (lobe == 0 ? 0 : 0.55))
            let tiers = pine ? 2 : 4
            func point(_ row: Int, _ col: Int) -> SIMD3<Float> {
                let v = Float(row) / Float(tiers)
                let a = Float(col) / Float(segments) * .pi * 2
                let profile: Float = pine ? (1 - v) : sin(v * .pi)
                let jitter = 1 + sin(a * 3 + phase + Float(row)) * 0.14
                return center + SIMD3<Float>(cos(a) * r * profile * jitter,
                    (v - 0.5) * r * (pine ? 2.2 : 1.65), sin(a) * r * profile * jitter)
            }
            for row in 0..<tiers {
                for col in 0..<segments {
                    let a = point(row, col), b = point(row, col + 1)
                    let c = point(row + 1, col), d = point(row + 1, col + 1)
                    let shade = 0.70 + Float(row) / Float(tiers) * 0.25 + sin(phase + Float(col)) * 0.05
                    let color = SIMD4<Float>(shade, shade, shade, 1)
                    mesh.triangle(a, c, b, color); mesh.triangle(b, c, d, color)
                }
            }
        }
        let result = mesh.geometry(material: material)
        if detailed {
            let coarse = foliage(radius: radius, pine: pine, seed: seed, material: material, detailed: false)
            result.levelsOfDetail = [SCNLevelOfDetail(geometry: coarse, worldSpaceDistance: 160)]
        }
        return result
    }

    static func fern(material: SCNMaterial) -> SCNGeometry {
        var m = Mesh()
        for i in 0..<9 {
            let angle = Float(i) * .pi * 2 / 9
            let axis = SIMD3<Float>(cos(angle), 0, sin(angle))
            let side = SIMD3<Float>(-sin(angle), 0, cos(angle))
            for j in 1...5 {
                let t = Float(j) / 6
                let mid = axis * t * 1.3 + SIMD3<Float>(0, sin(t * .pi) * 0.55, 0)
                let width = (1 - t) * 0.30
                for s: Float in [-1, 1] {
                    let color = SIMD4<Float>(0.7 + t * 0.3, 0.8 + t * 0.2, 0.65 + t * 0.35, 1)
                    let a = mid - axis * 0.14, b = mid + side * width * s + axis * 0.06, c = mid + axis * 0.15
                    m.triangle(a, b, c, color); m.triangle(c, b, a, color)
                }
            }
        }
        return m.geometry(material: material)
    }
}
