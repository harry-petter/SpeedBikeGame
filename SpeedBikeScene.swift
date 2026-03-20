import SceneKit
import UIKit

final class SpeedBikeScene: SCNScene {

    // MARK: - Config
    let mode:        GameMode
    let difficulty:  Difficulty
    let quality:     GraphicsQuality
    let trackLength: Float   // 1600 race, effectively ∞ for infinite

    // MARK: - Race state
    enum RaceState { case waiting, racing, finished, crashed }
    private(set) var raceState: RaceState = .waiting
    private(set) var raceTime:  Float     = 0

    private(set) var isLevelReady: Bool = false
    var onCrash: (() -> Void)?
    var distanceCovered: Float { max(0, worldZ) }
    var currentSpeed:    Float { forwardSpeed }
    var speedFraction:   Float { max(0, forwardSpeed) / maxBoostSpeed }
    private(set) var isBoosting: Bool = false

    var cameraNode = SCNNode()

    // MARK: - Player
    private var worldX:       Float  = 0
    private var worldZ:       Float  = -12
    private var heading:      Float  = 0
    private var turnRate:     Float  = 0
    private var forwardSpeed: Float  = 0
    private var speederY:     Float  = 2
    private var camY:         Float  = 4
    private var bankAngle:    Float  = 0
    private var pitchAngle:   Float  = 0
    private var velocityY:    Float  = 0
    private var camBankAngle: Float  = 0
    private var currentFOV:   Double = 88
    private var boostTimer:   Float  = 0
    private var boostEnergy:  Float  = 1.0   // 0→1, full at start
    private let boostDrainRate: Float = 0.40 // drain per second while boosting
    private let boostRechargeRate: Float = 0.12 // recharge per second when not boosting
    private var timeAccum:    Float  = 0

    private let maxNormalSpeed: Float = 60   // ~75% of boost
    private let maxBoostSpeed:  Float = 80
    private let maxTurnRate:    Float = 1.0

    // MARK: - Nodes
    private var speederPivot = SCNNode()
    private var speederBody  = SCNNode()
    private var sunNode      = SCNNode()
    private var treeRoot     = SCNNode()
    private var skyNodes:    [SCNNode] = []
    private var thrusterTrail: SCNParticleSystem?


    // MARK: - Trees (indices 0-2 = broadleaf small/med/large, 3-4 = conifers, 5 = dead tree)
    private var treeGeoms:  [SCNGeometry] = []
    private var canopyGeoms:[SCNGeometry] = []
    private let treeHeights:[Float] = [22, 42, 65, 35, 55, 18]
    private let canopyRadii:[Float] = [5.5, 9.0, 14.0, 5.0, 7.0, 0]
    private let trunkRadii: [Float] = [0.42, 0.80, 1.40, 0.40, 0.60, 0.55]
    private var bushGeoms:    [SCNGeometry] = []
    private let bushRadii:    [Float] = [0.65, 1.05, 1.55, 0.45]
    private var fernGeoms:    [SCNGeometry] = []

    private var giantTrunkGeo: SCNGeometry?
    private var giantCanopyGeo: SCNGeometry?
    private var lastTreeZ:  Float   = Float.infinity
    private let treeQueue = DispatchQueue(label: "treeGen", qos: .userInitiated)
    private var treePositions: [(x: Float, z: Float, r: Float)] = []
    private var treeGrid: [Int64: [(x: Float, z: Float, r: Float)]] = [:]
    private let treeGridCell: Float = 16
    private let speederRadius: Float = 0.55
    private var groundNode = SCNNode()

    // MARK: - Track
    private let corridorHalf: Float = 11.0
    private var corridorObstacles: [(x: Float, z: Float, r: Float)] = []

    // MARK: - Init
    init(difficulty: Difficulty, mode: GameMode, quality: GraphicsQuality) {
        self.difficulty  = difficulty
        self.mode        = mode
        self.quality     = quality
        self.trackLength = mode == .race ? 3200 : .greatestFiniteMagnitude
        super.init()
        buildScene()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build
    private func buildScene() {
        background.contents = UIColor(red: 0.28, green: 0.50, blue: 0.84, alpha: 1)
        fogColor = UIColor(red: 0.38, green: 0.58, blue: 0.44, alpha: 1)
        fogStartDistance = 160; fogEndDistance = 420
        lightingEnvironment.contents = UIColor(white: 0.5, alpha: 1)
        lightingEnvironment.intensity = 1.0

        buildTreeGeoms(); addLighting(); addSky(); buildGround()
        if mode == .race { buildRacingLevel(); buildTrackDecorations() }

        worldX  = trackCenterX(worldZ)
        heading = spawnHeading()
        buildSpeeder()
        buildCamera()

        if mode == .infinite {
            lastTreeZ = worldZ
            streamTrees(zStart: worldZ - 20, zEnd: worldZ + quality.streamRange)
        } else {
            buildAllTrees()
        }
    }

    // MARK: - Reset
    func resetRace() {
        let sz: Float = -12
        worldZ = sz; worldX = trackCenterX(sz); heading = spawnHeading()
        turnRate = 0; forwardSpeed = 0; speederY = 2; camY = 4
        bankAngle = 0; pitchAngle = 0; velocityY = 0
        camBankAngle = 0; currentFOV = 88; boostTimer = 0; boostEnergy = 1.0
        timeAccum = 0; raceState = .waiting; raceTime = 0
        isBoosting = false
        speederPivot.isHidden = false
        speederPivot.position = SCNVector3(worldX, 2, worldZ)
        if mode == .infinite {
            lastTreeZ = worldZ
            streamTrees(zStart: worldZ - 20, zEnd: worldZ + quality.streamRange)
        }
    }

    private func spawnHeading() -> Float { atan2(trackCenterX(10) - trackCenterX(-10), 20) }

    // MARK: - Lighting
    private func addLighting() {
        func dir(_ intensity: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ ex: Float, _ ey: Float) {
            let l = SCNLight(); l.type = .directional; l.intensity = intensity; l.castsShadow = false
            l.color = UIColor(red: r, green: g, blue: b, alpha: 1)
            let n = SCNNode(); n.light = l; n.eulerAngles = SCNVector3(ex, ey, 0)
            rootNode.addChildNode(n)
        }

        // Main sun — golden afternoon angle, crisp shadows
        let sun = SCNLight(); sun.type = .directional; sun.intensity = 4000
        sun.castsShadow = quality.shadowsEnabled
        sun.color = UIColor(red: 1.00, green: 0.91, blue: 0.68, alpha: 1)
        sun.shadowRadius = 4; sun.shadowSampleCount = quality.shadowSamples; sun.shadowMode = .deferred
        sun.shadowMapSize = quality.shadowMapSize; sun.shadowBias = 0.004
        sun.shadowColor = UIColor(white: 0, alpha: 0.42)
        let sn = SCNNode(); sn.light = sun; sn.eulerAngles = SCNVector3(-0.62, 0.52, 0)
        rootNode.addChildNode(sn)

        // Sky fill — cool blue from upper-opposite hemisphere
        dir(560,  0.36, 0.58, 0.92, -1.10, 0.52 + .pi)
        // Ground bounce — warm green reflecting off the forest floor
        dir(240,  0.36, 0.56, 0.18,  1.10, 0)
        // Rim — right side, electric blue edge separation
        dir(420,  0.50, 0.72, 1.00,  0.30, 2.80)
        // Subtle front fill to lift face detail
        dir(160,  0.60, 0.68, 0.80,  0.10, .pi)

        // Ambient — lower so directional lights punch harder
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 280
        amb.color = UIColor(red: 0.30, green: 0.44, blue: 0.60, alpha: 1)
        let an = SCNNode(); an.light = amb; rootNode.addChildNode(an)
    }



    // MARK: - Sky
    private func addSky() {
        let domes: [(Double, UIColor)] = [
            (3100, UIColor(red: 0.32, green: 0.55, blue: 0.92, alpha: 1)),   // upper sky
            (3070, UIColor(red: 0.38, green: 0.62, blue: 0.90, alpha: 1)),   // mid sky
            (3040, UIColor(red: 0.52, green: 0.72, blue: 0.58, alpha: 1)),   // warm horizon haze
            (3010, UIColor(red: 0.18, green: 0.52, blue: 0.26, alpha: 1)),   // treeline blend
        ]
        let skySegs = quality == .low ? 6 : quality == .medium ? 8 : 12
        for (r, col) in domes {
            let s = SCNSphere(radius: r); s.segmentCount = skySegs
            let m = SCNMaterial(); m.diffuse.contents = col
            m.isDoubleSided = true; m.lightingModel = .constant; s.firstMaterial = m
            let n = SCNNode(geometry: s); skyNodes.append(n); rootNode.addChildNode(n)
        }
        let core = SCNSphere(radius: 20); core.segmentCount = 8
        let cm = SCNMaterial(); cm.diffuse.contents = UIColor(red: 1, green: 0.97, blue: 0.90, alpha: 1)
        cm.emission.contents = UIColor(red: 1, green: 0.93, blue: 0.76, alpha: 1); cm.lightingModel = .constant
        core.firstMaterial = cm; sunNode.addChildNode(SCNNode(geometry: core))
        let halo = SCNSphere(radius: 46); halo.segmentCount = 8
        let hm = SCNMaterial(); hm.emission.contents = UIColor(red: 1, green: 0.86, blue: 0.55, alpha: 1)
        hm.diffuse.contents = UIColor.clear; hm.lightingModel = .constant
        hm.isDoubleSided = true; hm.transparency = 0.60; halo.firstMaterial = hm
        sunNode.addChildNode(SCNNode(geometry: halo))
        sunNode.position = SCNVector3(480, 430, -880); rootNode.addChildNode(sunNode)
    }

    // MARK: - Ground
    private func buildGround() {
        let floor = SCNFloor()
        floor.reflectivity = 0
        let mat = SCNMaterial()
        mat.diffuse.contents = makeGroundTex(); mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
        mat.diffuse.contentsTransform = SCNMatrix4MakeScale(22, 22, 1)
        mat.lightingModel = .lambert; floor.firstMaterial = mat
        groundNode = SCNNode(geometry: floor)
        groundNode.position = SCNVector3(0, -0.05, 0)
        rootNode.addChildNode(groundNode)
    }

    private func makeGroundTex() -> UIImage {
        let sz: CGFloat = 256
        UIGraphicsBeginImageContextWithOptions(CGSize(width: sz, height: sz), true, 1)
        let ctx = UIGraphicsGetCurrentContext()!
        // Base earthy green
        ctx.setFillColor(UIColor(red: 0.14, green: 0.32, blue: 0.08, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: sz, height: sz))
        // LCG noise for natural micro-variation
        var rng: UInt64 = 0xdeadbeefcafe1337
        func nr() -> CGFloat {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(rng >> 33) / CGFloat(1 << 31)
        }
        // Scattered soil/moss micro-patches — small rectangles, no ellipses
        for _ in 0..<420 {
            let x = nr() * sz; let y = nr() * sz
            let w = nr() * 3.5 + 0.5; let h = nr() * 2.5 + 0.5
            let t = nr()
            let (r, g, b): (CGFloat, CGFloat, CGFloat)
            if      t < 0.22 { (r,g,b) = (0.09, 0.20, 0.04) }  // dark shadow
            else if t < 0.48 { (r,g,b) = (0.20, 0.46, 0.10) }  // bright grass
            else if t < 0.64 { (r,g,b) = (0.15, 0.10, 0.04) }  // dark soil
            else if t < 0.80 { (r,g,b) = (0.26, 0.17, 0.07) }  // brown litter
            else             { (r,g,b) = (0.24, 0.52, 0.14) }  // vivid highlight
            ctx.setFillColor(UIColor(red: r, green: g, blue: b, alpha: nr()*0.55+0.3).cgColor)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        // Grass blades — thin strokes at random angles
        ctx.setLineWidth(0.7)
        for _ in 0..<550 {
            let x = nr() * sz; let y = nr() * sz
            let len = nr() * 9 + 2
            let ang = nr() * .pi - .pi * 0.5
            let bright = nr() * 0.18
            ctx.setStrokeColor(UIColor(red: 0.15 + bright, green: 0.36 + bright * 2.6,
                                       blue: 0.05 + bright * 0.4, alpha: nr()*0.5+0.4).cgColor)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + cos(ang) * len, y: y + sin(ang) * len))
            ctx.strokePath()
        }
        let img = UIGraphicsGetImageFromCurrentImageContext()!; UIGraphicsEndImageContext(); return img
    }

    // MARK: - Track path

    func trackCenterX(_ z: Float) -> Float {
        // Grand sweeping bends with long straights between
        let wide   = 70 * sin(z / 420)                          // huge long-period sweeps
        let medium = 38 * sin(z / 170 + 0.8)                    // mid-frequency bends
        let tight  = 14 * sin(z / 65 + 2.2)                     // quick chicanes
        let wiggle =  4 * sin(z / 28 + 1.5)                     // road texture
        return wide + medium + tight + wiggle
    }

    func trackHeight(_ z: Float) -> Float { return 0 }

    // Lateral banking angle from curve gradient — used for camera roll
    private func trackBankAngle(_ z: Float) -> Float {
        let dx = (trackCenterX(z + 3) - trackCenterX(z - 3)) / 6
        return max(-0.30, min(0.30, -dx * 0.06))
    }

    // Returns a [0,1] scalar indicating how tight the current curve is (0=straight, 1=apex)
    private func curvature(_ z: Float) -> Float {
        let dx = 70/420 * cos(z/420) + 38/170 * cos(z/170 + 0.8) + 14/65 * cos(z/65 + 2.2)
        return min(1, abs(dx) / 0.65)
    }

    // MARK: - Racing level (race mode only)
    private func buildRacingLevel() {
        let root = SCNNode(); rootNode.addChildNode(root)
        var gz: Float = 250
        while gz < trackLength { buildForestGate(at: gz, parent: root); gz += 250 }
        buildForestArch(at: 0, finish: false, parent: root)
        buildForestArch(at: trackLength, finish: true, parent: root)
    }

    // Checkpoint gate — carved log cross-beam on two wooden posts, with hanging vine accents
    private func buildForestGate(at z: Float, parent: SCNNode) {
        let tc = trackCenterX(z)
        let woodMat = SCNMaterial()
        woodMat.diffuse.contents = UIColor(red: 0.32, green: 0.20, blue: 0.10, alpha: 1)
        woodMat.lightingModel = .lambert
        // Posts
        for side: Float in [-1, 1] {
            let post = SCNCylinder(radius: 0.22, height: 5.5); post.radialSegmentCount = 7; post.firstMaterial = woodMat
            let pn = SCNNode(geometry: post); pn.position = SCNVector3(tc + side * (corridorHalf + 0.3), 2.75, z); parent.addChildNode(pn)
        }
        // Cross-beam log — slightly rotated for natural look
        let beam = SCNCylinder(radius: 0.18, height: CGFloat(corridorHalf * 2 + 1.2))
        beam.radialSegmentCount = 7; beam.firstMaterial = woodMat
        let bn = SCNNode(geometry: beam)
        bn.position = SCNVector3(tc, 5.6, z)
        bn.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
        parent.addChildNode(bn)
        // Moss/lichen accent on top of beam
        let mossMat = SCNMaterial(); mossMat.diffuse.contents = UIColor(red: 0.25, green: 0.50, blue: 0.16, alpha: 1); mossMat.lightingModel = .lambert
        let moss = SCNBox(width: CGFloat(corridorHalf + 0.5), height: 0.20, length: 0.30, chamferRadius: 0.06); moss.firstMaterial = mossMat
        let mn = SCNNode(geometry: moss); mn.position = SCNVector3(tc, 5.82, z); parent.addChildNode(mn)
    }

    // Start / finish arch — ancient stone torii with vines
    private func buildForestArch(at z: Float, finish: Bool, parent: SCNNode) {
        let tc = trackCenterX(z)
        let stoneMat = SCNMaterial()
        stoneMat.diffuse.contents = finish ? UIColor(red: 0.62, green: 0.54, blue: 0.42, alpha: 1)
                                           : UIColor(red: 0.50, green: 0.46, blue: 0.38, alpha: 1)
        stoneMat.lightingModel = .lambert
        let mossMat = SCNMaterial(); mossMat.diffuse.contents = UIColor(red: 0.22, green: 0.44, blue: 0.14, alpha: 1); mossMat.lightingModel = .lambert

        // Two chunky stone columns
        for side: Float in [-1, 1] {
            let col = SCNCylinder(radius: 1.1, height: 10.0); col.radialSegmentCount = 8; col.firstMaterial = stoneMat
            let cn = SCNNode(geometry: col); cn.position = SCNVector3(tc + side * (corridorHalf + 1.5), 5.0, z); parent.addChildNode(cn)
            // Column capital
            let cap = SCNBox(width: 2.8, height: 0.9, length: 2.8, chamferRadius: 0.12); cap.firstMaterial = stoneMat
            let capn = SCNNode(geometry: cap); capn.position = SCNVector3(tc + side * (corridorHalf + 1.5), 10.6, z); parent.addChildNode(capn)
            // Moss patches on column
            let mossStrip = SCNBox(width: 2.0, height: 1.8, length: 0.5, chamferRadius: 0.1); mossStrip.firstMaterial = mossMat
            let msn = SCNNode(geometry: mossStrip); msn.position = SCNVector3(tc + side * (corridorHalf + 1.5), 4.0 + Float.random(in: 0...2), z + 1.1); parent.addChildNode(msn)
        }
        // Main lintel
        let lintel = SCNBox(width: CGFloat(corridorHalf * 2 + 5.8), height: 1.4, length: 1.8, chamferRadius: 0.15); lintel.firstMaterial = stoneMat
        let ln = SCNNode(geometry: lintel); ln.position = SCNVector3(tc, 11.3, z); parent.addChildNode(ln)
        // Second decorative beam above lintel (torii-style)
        let topBeam = SCNBox(width: CGFloat(corridorHalf * 2 + 7.0), height: 0.7, length: 1.0, chamferRadius: 0.10); topBeam.firstMaterial = stoneMat
        let tbn = SCNNode(geometry: topBeam); tbn.position = SCNVector3(tc, 12.4, z); parent.addChildNode(tbn)

        // Finish: golden glow totem on lintel centre
        if finish {
            let totemMat = SCNMaterial()
            totemMat.diffuse.contents  = UIColor(red: 0.95, green: 0.78, blue: 0.12, alpha: 1)
            totemMat.emission.contents = UIColor(red: 0.60, green: 0.42, blue: 0.02, alpha: 1)
            totemMat.lightingModel = .phong
            let totem = SCNCylinder(radius: 0.30, height: 2.2); totem.radialSegmentCount = 8; totem.firstMaterial = totemMat
            let tn = SCNNode(geometry: totem); tn.position = SCNVector3(tc, 13.5, z); parent.addChildNode(tn)
            let orb = SCNSphere(radius: 0.55); orb.segmentCount = 10; orb.firstMaterial = totemMat
            let on = SCNNode(geometry: orb); on.position = SCNVector3(tc, 14.9, z); parent.addChildNode(on)
        }
    }

    private func buildTrackDecorations() {
        let root = SCNNode(); rootNode.addChildNode(root)
        func stoneMat() -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: 0.46, green: 0.42, blue: 0.36, alpha: 1)
            m.lightingModel = .lambert; return m
        }
        let sm = stoneMat()
        // Stone archways
        for gz: Float in [600, 1200, 1800, 2400, 3000] {
            let tc = trackCenterX(gz)
            for side: Float in [-1, 1] {
                let col = SCNCylinder(radius: 1.3, height: 13.0); col.radialSegmentCount = 8; col.firstMaterial = sm
                let cn = SCNNode(geometry: col); cn.position = SCNVector3(tc + side * (corridorHalf + 2.0), 6.5, gz); root.addChildNode(cn)
                let cap = SCNBox(width: 3.0, height: 1.1, length: 3.0, chamferRadius: 0.1); cap.firstMaterial = sm
                let capn = SCNNode(geometry: cap); capn.position = SCNVector3(tc + side * (corridorHalf + 2.0), 13.7, gz); root.addChildNode(capn)
            }
            let lintel = SCNBox(width: CGFloat(corridorHalf * 2 + 6.0), height: 1.3, length: 1.7, chamferRadius: 0.2); lintel.firstMaterial = sm
            let ln = SCNNode(geometry: lintel); ln.position = SCNVector3(tc, 14.3, gz); root.addChildNode(ln)
        }
        // Stone pillars
        var pz: Float = 140
        let piSm = stoneMat()
        while pz < trackLength {
            let tc = trackCenterX(pz)
            for side: Float in [-1, 1] {
                let h = Float.random(in: 5...11)
                let pillar = SCNCylinder(radius: 0.40, height: CGFloat(h)); pillar.radialSegmentCount = 7; pillar.firstMaterial = piSm
                let pn = SCNNode(geometry: pillar)
                pn.position = SCNVector3(tc + side * (corridorHalf + Float.random(in: 3...8)), h * 0.5, pz)
                pn.eulerAngles = SCNVector3(Float.random(in: -0.10...0.10), Float.random(in: 0...Float.pi), 0)
                root.addChildNode(pn)
            }
            pz += 155
        }
        // Fallen logs
        let logMat = SCNMaterial(); logMat.diffuse.contents = UIColor(red: 0.30, green: 0.18, blue: 0.09, alpha: 1); logMat.lightingModel = .lambert
        var lz: Float = 320
        while lz < trackLength {
            let logGeo = SCNCylinder(radius: 1.1, height: 28.0); logGeo.radialSegmentCount = 7; logGeo.firstMaterial = logMat
            let ln = SCNNode(geometry: logGeo)
            ln.position = SCNVector3(trackCenterX(lz), 3.8, lz)
            ln.eulerAngles = SCNVector3(0, Float.random(in: 0.3...0.8), .pi / 2); root.addChildNode(ln)
            lz += 370
        }
    }

    // MARK: - Tree geometries
    private func buildTreeGeoms() {
        // Broadleaf trunks (0-2)
        let trunkCols: [(CGFloat,CGFloat,CGFloat)] = [
            (0.30, 0.18, 0.09), (0.25, 0.15, 0.075), (0.20, 0.12, 0.06),
            (0.28, 0.16, 0.08), (0.22, 0.13, 0.07), (0.35, 0.22, 0.12)
        ]
        for i in 0..<6 {
            let h = treeHeights[i]
            let cyl = SCNCylinder(radius: CGFloat(trunkRadii[i]), height: CGFloat(h)); cyl.radialSegmentCount = 6; cyl.heightSegmentCount = 1
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: trunkCols[i].0, green: trunkCols[i].1, blue: trunkCols[i].2, alpha: 1)
            m.lightingModel = .lambert; cyl.firstMaterial = m; treeGeoms.append(cyl)
        }

        // Canopies: 0-2 = round broadleaf, 3-4 = conical pines, 5 = dead (bare branches placeholder)
        let broadCols: [(CGFloat,CGFloat,CGFloat)] = [(0.20,0.52,0.14),(0.16,0.44,0.10),(0.12,0.36,0.08)]
        for (i, cr) in broadCols.enumerated() {
            let s = SCNSphere(radius: CGFloat(canopyRadii[i])); s.segmentCount = 6
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: cr.0, green: cr.1, blue: cr.2, alpha: 1)
            m.lightingModel = .lambert; s.firstMaterial = m; canopyGeoms.append(s)
        }
        // Conifers — dark pointed cone canopies
        let pineCols: [(CGFloat,CGFloat,CGFloat)] = [(0.08, 0.26, 0.10), (0.06, 0.22, 0.08)]
        for (i, pc) in pineCols.enumerated() {
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(canopyRadii[3 + i] * 1.3), height: CGFloat(treeHeights[3 + i] * 0.6))
            cone.radialSegmentCount = 6
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: pc.0, green: pc.1, blue: pc.2, alpha: 1)
            m.lightingModel = .lambert; cone.firstMaterial = m; canopyGeoms.append(cone)
        }
        // Dead tree — bare twisted branches (small dark sphere cluster as placeholder)
        let deadMat = SCNMaterial(); deadMat.diffuse.contents = UIColor(red: 0.30, green: 0.20, blue: 0.12, alpha: 1); deadMat.lightingModel = .lambert
        let deadCanopy = SCNSphere(radius: 2.5); deadCanopy.segmentCount = 4; deadCanopy.firstMaterial = deadMat
        canopyGeoms.append(deadCanopy)

        // Bushes — flattened spheres, 4 sizes, dark undergrowth tones
        let bushCols: [(CGFloat,CGFloat,CGFloat)] = [(0.12,0.36,0.06),(0.10,0.30,0.05),(0.15,0.42,0.08),(0.08,0.24,0.04)]
        for (i, br) in bushRadii.enumerated() {
            let s = SCNSphere(radius: CGFloat(br)); s.segmentCount = 6
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: bushCols[i].0, green: bushCols[i].1, blue: bushCols[i].2, alpha: 1)
            m.lightingModel = .lambert; s.firstMaterial = m; bushGeoms.append(s)
        }

        // Ferns — flat discs on the forest floor
        let fernCols: [(CGFloat,CGFloat,CGFloat)] = [(0.14,0.40,0.08),(0.10,0.34,0.06),(0.18,0.46,0.10)]
        for fc in fernCols {
            let fern = SCNCylinder(radius: 1.2, height: 0.05); fern.radialSegmentCount = 8
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: fc.0, green: fc.1, blue: fc.2, alpha: 1)
            m.lightingModel = .lambert; fern.firstMaterial = m; fernGeoms.append(fern)
        }

        // Giant ancient tree
        let gtMat = SCNMaterial(); gtMat.diffuse.contents = UIColor(red: 0.20, green: 0.12, blue: 0.06, alpha: 1); gtMat.lightingModel = .lambert
        let gt = SCNCylinder(radius: 3.5, height: 85); gt.radialSegmentCount = 8; gt.heightSegmentCount = 1; gt.firstMaterial = gtMat; giantTrunkGeo = gt
        let gcMat = SCNMaterial(); gcMat.diffuse.contents = UIColor(red: 0.08, green: 0.28, blue: 0.05, alpha: 1); gcMat.lightingModel = .lambert
        let gc = SCNSphere(radius: 22); gc.segmentCount = 7; gc.firstMaterial = gcMat; giantCanopyGeo = gc
    }

    // MARK: - Tree build (race = full static, infinite = streaming)

    private func buildAllTrees() {
        streamTrees(zStart: -40, zEnd: trackLength + 30)
    }

    private func streamTrees(zStart: Float, zEnd: Float) {
        let geos = treeGeoms; let cGeos = canopyGeoms; let bGeos = bushGeoms
        let fGeos = fernGeoms
        let gtGeoCapture = giantTrunkGeo; let gcGeoCapture = giantCanopyGeo
        let heights = treeHeights; let cRadii = canopyRadii; let tRadii = trunkRadii; let bRadii = bushRadii
        let treeTypeCount = min(geos.count, cGeos.count)
        let treeShadows = quality.treesCastShadows
        let jungleDepth = quality.jungleDepth; let jungleDens = quality.jungleDensity
        let bushesOn = quality.bushesEnabled; let bushScale = quality.bushDensityScale
        let clearHalf: Float = difficulty.clearZone; let bandWidth: Float = 160.0
        let outerEdge: Float = clearHalf + bandWidth
        let density = difficulty.treeDensity; let isRace = mode == .race
        let cellZ: Float = isRace ? 10 : 8; let cellX: Float = isRace ? 10 : 8

        treeQueue.async { [weak self] in
            guard let self = self else { return }
            let newRoot = SCNNode()
            var positions = [(x: Float, z: Float, r: Float)]()
            func ch(_ iz: Int, _ ix: Int, _ si: Int) -> UInt64 {
                var h = UInt64(bitPattern: Int64(iz &* 374761393 &+ ix &* 668265263 &+ si &* 1234567891))
                h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9; h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
                return h ^ (h >> 31)
            }
            func cr(_ iz: Int, _ ix: Int, _ si: Int, _ slot: Int) -> Float {
                Float(ch(iz, ix &* 7 &+ slot, si) & 0x7fffffff) / Float(0x7fffffff)
            }

            var wz = zStart
            while wz < zEnd {
                let tc = self.trackCenterX(wz); let iz = Int(wz / cellZ)
                for si in 0..<2 {
                    let side: Float = si == 0 ? -1 : 1
                    var offX = clearHalf; var ix = 0
                    while offX < outerEdge {
                        let fromEdge = (outerEdge - offX) / bandWidth
                        let d = fromEdge < 0.32 ? min(0.92, density + 0.28) : density
                        let jx = (cr(iz, ix, si, 0) - 0.5) * cellX * 0.7
                        let jz = (cr(iz, ix, si, 1) - 0.5) * cellZ * 0.7
                        if cr(iz, ix, si, 2) < d {
                            let gRaw = Int(cr(iz, ix, si, 3) * Float(treeTypeCount - 1) + 0.5) % treeTypeCount
                            let gIdx = fromEdge < 0.32 ? max(gRaw, 1) : gRaw
                            let hScale = cr(iz, ix, si, 4) * 0.55 + 0.72
                            let h      = heights[gIdx] * hScale
                            let tx = tc + side * offX + jx; let tz = wz + jz
                            let trunk = SCNNode(geometry: geos[gIdx])
                            trunk.position = SCNVector3(tx, h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            if !treeShadows { trunk.castsShadow = false }
                            newRoot.addChildNode(trunk)
                            let canopy = SCNNode(geometry: cGeos[gIdx])
                            if gIdx >= 3 && gIdx <= 4 {
                                // Conifers: canopy sits mid-trunk, cone shape
                                canopy.position = SCNVector3(tx, h * 0.55, tz)
                                canopy.scale = SCNVector3(1.0, 1.0, 1.0)
                            } else if gIdx == 5 {
                                // Dead tree: small bare crown at top
                                canopy.position = SCNVector3(tx, h * 0.85, tz)
                                canopy.scale = SCNVector3(1.2, 0.6, 1.2)
                            } else {
                                canopy.position = SCNVector3(tx, h - cRadii[gIdx] * 0.1, tz)
                                canopy.scale = SCNVector3(1.0, 0.72, 1.0)
                            }
                            if !treeShadows { canopy.castsShadow = false }
                            newRoot.addChildNode(canopy)
                            positions.append((x: tx, z: tz, r: tRadii[gIdx] * 1.2))
                        }
                        offX += cellX; ix += 1
                    }
                    // Jungle background — visual only, no collision, mixed types
                    var jOffX = outerEdge + cellX * 0.5; var jix = 200
                    while jOffX < outerEdge + jungleDepth {
                        let jx = (cr(iz, jix, si, 0) - 0.5) * cellX * 0.6
                        let jz = (cr(iz, jix, si, 1) - 0.5) * cellZ * 0.6
                        if cr(iz, jix, si, 2) < jungleDens {
                            // Mix of large broadleaf (2), conifers (3,4) in background
                            let jTypes: [Int] = [2, 2, 2, 3, 4]
                            let jIdx = jTypes[Int(cr(iz, jix, si, 3) * Float(jTypes.count - 1) + 0.5) % jTypes.count]
                            let hScale = cr(iz, jix, si, 4) * 0.65 + 0.90
                            let h      = heights[jIdx] * hScale
                            let tx = tc + side * jOffX + jx; let tz = wz + jz
                            let trunk = SCNNode(geometry: geos[jIdx])
                            trunk.position = SCNVector3(tx, h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            trunk.castsShadow = false; newRoot.addChildNode(trunk)
                            let canopy = SCNNode(geometry: cGeos[jIdx])
                            if jIdx >= 3 {
                                canopy.position = SCNVector3(tx, h * 0.55, tz)
                            } else {
                                canopy.position = SCNVector3(tx, h - cRadii[jIdx] * 0.1, tz)
                                canopy.scale = SCNVector3(1.1, 0.68, 1.1)
                            }
                            canopy.castsShadow = false; newRoot.addChildNode(canopy)
                        }
                        jOffX += cellX * 0.65; jix += 1
                    }

                    // Bushes — corridor edge and inner forest floor
                    if bushesOn {
                    var bOffX = clearHalf - 5; var bix = 700
                    while bOffX < clearHalf + 40 {
                        let insideTrack = bOffX < clearHalf
                        let bd: Float = (insideTrack ? 0.28 : 0.46) * bushScale
                        let bjx = (cr(iz, bix, si, 0) - 0.5) * 7.0 * 0.85
                        let bjz = (cr(iz, bix, si, 1) - 0.5) * Float(cellZ) * 0.85
                        if cr(iz, bix, si, 2) < bd {
                            let bIdx = insideTrack ? Int(cr(iz, bix, si, 3) * 1.99) % 2
                                                   : Int(cr(iz, bix, si, 3) * 2.99) % 3
                            let bScale = cr(iz, bix, si, 4) * 0.35 + 0.65
                            let bx = tc + side * bOffX + bjx; let bz = wz + bjz
                            let bush = SCNNode(geometry: bGeos[bIdx])
                            bush.position = SCNVector3(bx, Float(bRadii[bIdx]) * 0.45 * bScale, bz)
                            bush.scale = SCNVector3(bScale, bScale * 0.52, bScale)
                            newRoot.addChildNode(bush)
                        }
                        bOffX += 7.0; bix += 1
                    }
                    } // bushesOn

                    // Ferns — scattered on forest floor near track edge
                    if !fGeos.isEmpty {
                        var fOffX = clearHalf + 2; var fix = 900
                        while fOffX < clearHalf + 35 {
                            if cr(iz, fix, si, 2) < 0.32 * bushScale {
                                let fjx = (cr(iz, fix, si, 0) - 0.5) * 6.0
                                let fjz = (cr(iz, fix, si, 1) - 0.5) * Float(cellZ) * 0.8
                                let fIdx = Int(cr(iz, fix, si, 3) * Float(fGeos.count - 1) + 0.5) % fGeos.count
                                let fx = tc + side * fOffX + fjx; let fz = wz + fjz
                                let fern = SCNNode(geometry: fGeos[fIdx])
                                fern.position = SCNVector3(fx, 0.08, fz)
                                let fScale = cr(iz, fix, si, 4) * 0.5 + 0.7
                                fern.scale = SCNVector3(fScale, 1, fScale)
                                fern.eulerAngles.y = cr(iz, fix, si, 5) * .pi * 2
                                fern.castsShadow = false; newRoot.addChildNode(fern)
                            }
                            fOffX += 5.0; fix += 1
                        }
                    }
                }
                wz += cellZ
            }

            // ── Giant ancient trees — landmarks every ~300m ──
            if let gtGeo = gtGeoCapture, let gcGeo = gcGeoCapture {
                var gz = (zStart / 300).rounded(.up) * 300
                while gz < zEnd {
                    let giz = Int(gz)
                    let tc = self.trackCenterX(gz)
                    for si in 0..<2 {
                        if cr(giz, 90, si, 0) < 0.65 {
                            let side: Float = si == 0 ? -1 : 1
                            let gx = tc + side * (clearHalf + 14 + cr(giz, 90, si, 1) * 28)
                            let gzz = gz + (cr(giz, 90, si, 2) - 0.5) * 40
                            let hScale: Float = 0.75 + cr(giz, 90, si, 3) * 0.6
                            let trunk = SCNNode(geometry: gtGeo)
                            trunk.position = SCNVector3(gx, 85 * hScale * 0.5, gzz)
                            trunk.scale = SCNVector3(1, hScale, 1); trunk.castsShadow = false
                            newRoot.addChildNode(trunk)
                            let canopy = SCNNode(geometry: gcGeo)
                            canopy.position = SCNVector3(gx, 85 * hScale - 8, gzz)
                            canopy.scale = SCNVector3(1.1, 0.60, 1.1); canopy.castsShadow = false
                            newRoot.addChildNode(canopy)
                        }
                    }
                    gz += 300
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let old = self.treeRoot
                self.treeRoot = newRoot
                self.rootNode.addChildNode(self.treeRoot)
                old.removeFromParentNode()
                self.treePositions = positions
                self.rebuildTreeGrid()
                self.isLevelReady = true
            }
        }
    }

    // MARK: - Speeder
    private func buildSpeeder() {
        func pbr(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metal: CGFloat = 0.1, rough: CGFloat = 0.5) -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.lightingModel = .physicallyBased; m.metalness.contents = metal; m.roughness.contents = rough; return m
        }
        func glow(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, s: CGFloat = 1.0) -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: r*0.35, green: g*0.35, blue: b*0.35, alpha: 1)
            m.emission.contents = UIColor(red: r*s, green: g*s, blue: b*s, alpha: 1); m.lightingModel = .constant; return m
        }
        func glass() -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: 0.28, green: 0.58, blue: 0.88, alpha: 0.30)
            m.emission.contents = UIColor(red: 0.08, green: 0.28, blue: 0.58, alpha: 1)
            m.lightingModel = .physicallyBased; m.transparency = 0.52
            m.metalness.contents = CGFloat(0.8); m.roughness.contents = CGFloat(0.05)
            m.isDoubleSided = true; return m
        }

        // Fuselage
        let hull = SCNBox(width: 0.30, height: 0.16, length: 5.6, chamferRadius: 0.05); hull.firstMaterial = pbr(0.14, 0.14, 0.16, metal: 0.4, rough: 0.35)
        speederBody.addChildNode(SCNNode(geometry: hull))
        let fairing = SCNBox(width: 0.22, height: 0.10, length: 3.8, chamferRadius: 0.04); fairing.firstMaterial = pbr(0.52, 0.50, 0.48, metal: 0.6, rough: 0.25)
        let fn = SCNNode(geometry: fairing); fn.position = SCNVector3(0, 0.13, -0.4); speederBody.addChildNode(fn)
        let belly = SCNBox(width: 0.36, height: 0.07, length: 4.8, chamferRadius: 0.03); belly.firstMaterial = pbr(0.22, 0.22, 0.24, metal: 0.5, rough: 0.40)
        let beln = SCNNode(geometry: belly); beln.position = SCNVector3(0, -0.10, 0); speederBody.addChildNode(beln)
        // Nose (compact — no long spike)
        let noseCone = SCNBox(width: 0.16, height: 0.11, length: 0.72, chamferRadius: 0.04); noseCone.firstMaterial = pbr(0.46, 0.44, 0.42, metal: 0.7, rough: 0.20)
        let nn = SCNNode(geometry: noseCone); nn.position = SCNVector3(0, 0.02, -3.18); speederBody.addChildNode(nn)
        let noseCap = SCNSphere(radius: 0.09); noseCap.segmentCount = 8; noseCap.firstMaterial = pbr(0.52, 0.50, 0.48, metal: 0.8, rough: 0.18)
        speederBody.addChildNode(SCNNode(geometry: noseCap) ※ { $0.position = SCNVector3(0, 0.02, -3.56) })
        // Cockpit
        let cpBody = SCNBox(width: 0.24, height: 0.14, length: 1.10, chamferRadius: 0.05); cpBody.firstMaterial = pbr(0.42, 0.40, 0.38, metal: 0.5, rough: 0.30)
        speederBody.addChildNode(SCNNode(geometry: cpBody) ※ { $0.position = SCNVector3(0, 0.18, -1.1) })
        let shield = SCNBox(width: 0.20, height: 0.12, length: 0.55, chamferRadius: 0.04); shield.firstMaterial = glass()
        speederBody.addChildNode(SCNNode(geometry: shield) ※ { $0.position = SCNVector3(0, 0.25, -1.55); $0.eulerAngles.x = -0.22 })
        let bar = SCNCapsule(capRadius: 0.028, height: 0.72); bar.firstMaterial = pbr(0.30, 0.30, 0.32, metal: 0.8, rough: 0.18)
        speederBody.addChildNode(SCNNode(geometry: bar) ※ { $0.eulerAngles.z = .pi/2; $0.position = SCNVector3(0, 0.21, -1.82) })
        // Engine pods
        for side: Float in [-1, 1] {
            let pod = SCNCylinder(radius: 0.18, height: 5.20); pod.radialSegmentCount = 10; pod.firstMaterial = pbr(0.18, 0.18, 0.20, metal: 0.6, rough: 0.28)
            speederBody.addChildNode(SCNNode(geometry: pod) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side * 0.42, -0.14, 0.28) })
            // Intake rings (3 per pod)
            for i in 0..<3 {
                let ring = SCNTorus(ringRadius: 0.22, pipeRadius: 0.028); ring.ringSegmentCount = 14; ring.pipeSegmentCount = 5
                ring.firstMaterial = pbr(0.40, 0.40, 0.42, metal: 0.8, rough: 0.18)
                speederBody.addChildNode(SCNNode(geometry: ring) ※ { $0.position = SCNVector3(side * 0.42, -0.14, -0.55 + Float(i)*0.28) })
            }
            let bell = SCNCone(topRadius: 0.12, bottomRadius: 0.22, height: 0.30); bell.radialSegmentCount = 10; bell.firstMaterial = glow(1.0, 0.38, 0.06)
            speederBody.addChildNode(SCNNode(geometry: bell) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.42, -0.14, 3.0) })
            let trail = SCNCylinder(radius: 0.10, height: 0.40); trail.radialSegmentCount = 8; trail.firstMaterial = glow(1.0, 0.24, 0.04, s: 1.4)
            speederBody.addChildNode(SCNNode(geometry: trail) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.42, -0.14, 3.38) })
            let pylon = SCNBox(width: 0.16, height: 0.06, length: 1.10, chamferRadius: 0.02); pylon.firstMaterial = pbr(0.28, 0.28, 0.30, metal: 0.5, rough: 0.38)
            speederBody.addChildNode(SCNNode(geometry: pylon) ※ { $0.position = SCNVector3(side*0.22, -0.10, 0.28) })
            for fi in 0..<3 {
                let fin = SCNBox(width: 0.02, height: 0.22, length: 0.58, chamferRadius: 0.005); fin.firstMaterial = pbr(0.32, 0.32, 0.34, metal: 0.7, rough: 0.22)
                speederBody.addChildNode(SCNNode(geometry: fin) ※ { $0.position = SCNVector3(side*0.42, 0.08, -0.78 + Float(fi)*0.52) })
            }
            let stripe = SCNBox(width: 0.04, height: 0.04, length: 2.80, chamferRadius: 0.01); stripe.firstMaterial = glow(0.12, 0.70, 1.0, s: 0.55)
            speederBody.addChildNode(SCNNode(geometry: stripe) ※ { $0.position = SCNVector3(side*0.16, 0.08, -0.20) })
        }
        // Repulsor pads
        for (pz, pr): (Float, Float) in [(-1.8, 0.24), (0.2, 0.20), (2.0, 0.18)] {
            let pad = SCNCylinder(radius: CGFloat(pr), height: 0.04); pad.radialSegmentCount = 12; pad.firstMaterial = glow(0.12, 0.62, 1.0, s: 1.2)
            speederBody.addChildNode(SCNNode(geometry: pad) ※ { $0.position = SCNVector3(0, -0.24, pz) })
            let ring = SCNTorus(ringRadius: CGFloat(pr*1.5), pipeRadius: 0.016); ring.ringSegmentCount = 12; ring.pipeSegmentCount = 5; ring.firstMaterial = glow(0.08, 0.40, 0.90, s: 0.45)
            speederBody.addChildNode(SCNNode(geometry: ring) ※ { $0.position = SCNVector3(0, -0.22, pz) })
        }
        // Control vanes
        for angle: Float in [0.52, -0.52, .pi/2+0.52, .pi/2-0.52] {
            let vane = SCNBox(width: 0.38, height: 0.04, length: 0.56, chamferRadius: 0.01); vane.firstMaterial = pbr(0.36, 0.34, 0.32, metal: 0.6, rough: 0.30)
            speederBody.addChildNode(SCNNode(geometry: vane) ※ { $0.position = SCNVector3(0, -0.06, 2.55); $0.eulerAngles.z = angle })
        }
        let tailFin = SCNBox(width: 0.04, height: 0.36, length: 0.66, chamferRadius: 0.015); tailFin.firstMaterial = pbr(0.38, 0.36, 0.34, metal: 0.55, rough: 0.32)
        speederBody.addChildNode(SCNNode(geometry: tailFin) ※ { $0.position = SCNVector3(0, 0.24, 2.50) })

        // Flatten speeder body to reduce draw calls (~40 → few)
        let flatBody = speederBody.flattenedClone()
        speederBody = flatBody

        // Subtle thruster particle trail (added after flatten so it stays dynamic)
        let trail = SCNParticleSystem()
        trail.birthRate = 0; trail.emissionDuration = -1
        trail.particleLifeSpan = 0.35; trail.particleLifeSpanVariation = 0.1
        trail.particleSize = 0.04; trail.particleSizeVariation = 0.02
        trail.spreadingAngle = 8; trail.particleVelocity = 5; trail.particleVelocityVariation = 2
        trail.emittingDirection = SCNVector3(0, 0, -1)
        trail.particleColor = UIColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 0.4)
        trail.particleColorVariation = SCNVector4(0.05, 0.05, 0.1, 0.15)
        trail.blendMode = .additive; trail.isLightingEnabled = false
        thrusterTrail = trail
        let trailNode = SCNNode(); trailNode.position = SCNVector3(0, -0.14, 3.4)
        trailNode.addParticleSystem(trail)
        speederBody.addChildNode(trailNode)

        speederPivot.addChildNode(speederBody)
        speederPivot.position = SCNVector3(worldX, 5, worldZ)
        rootNode.addChildNode(speederPivot)
    }

    // MARK: - Camera
    private func buildCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 88; cam.motionBlurIntensity = 0; cam.zNear = 0.10; cam.zFar = 800
        cam.wantsHDR = quality.wantsHDR
        cam.bloomIntensity = quality.bloomIntensity; cam.bloomThreshold = quality.bloomThreshold; cam.bloomBlurRadius = quality.bloomBlurRadius
        cam.contrast = quality.contrast; cam.saturation = quality.saturation
        cam.vignettingIntensity = 0.55; cam.vignettingPower = 1.0
        cam.exposureAdaptationBrighteningSpeedFactor = 0; cam.exposureAdaptationDarkeningSpeedFactor = 0
        if quality == .high {
            cam.wantsDepthOfField = true; cam.fStop = 5.6; cam.focalBlurSampleCount = 4
        }
        cameraNode.camera = cam; rootNode.addChildNode(cameraNode)
    }

    // MARK: - Update
    func update(dt: Float, steer: Float, throttling: Bool, braking: Bool) {
        guard isLevelReady else { updateCamera(dt: dt); return }
        guard raceState != .crashed else { updateCamera(dt: dt); return }
        timeAccum += dt

        // Race state
        switch raceState {
        case .waiting: if worldZ > 5 { raceState = .racing }
        case .racing:
            raceTime += dt
            if mode == .race && worldZ >= trackLength { raceState = .finished }
        case .finished: break
        case .crashed: break
        }

        // Speed — boost drains energy, recharges when not boosting
        isBoosting = boostTimer > 0 && boostEnergy > 0
        if isBoosting {
            boostEnergy = max(0, boostEnergy - boostDrainRate * dt)
            if boostEnergy <= 0 { boostTimer = 0 }   // ran out of juice
            forwardSpeed = min(forwardSpeed + 60*dt, maxBoostSpeed)
        } else {
            boostTimer = 0
            boostEnergy = min(1.0, boostEnergy + boostRechargeRate * dt)
        }
        if !isBoosting {
            if braking {
                forwardSpeed = max(0, forwardSpeed - 60*dt)              // brake to stop, no reverse
            } else if throttling {
                forwardSpeed = min(forwardSpeed + 38*dt, maxNormalSpeed)
            } else {
                forwardSpeed = max(0, forwardSpeed - 12*dt)              // coast to stop
            }
        }

        // Steering — reduce turn rate at low speed to prevent spinning in place
        let speedSteerFactor = min(1.0, forwardSpeed / 12.0)
        turnRate += (steer * maxTurnRate * speedSteerFactor - turnRate) * min(1, dt * 5.5)
        heading  += turnRate * dt

        // Position
        worldX += sin(heading) * forwardSpeed * dt
        worldZ += cos(heading) * forwardSpeed * dt

        // Prevent going behind start
        if worldZ < -15 { worldZ = -15; forwardSpeed *= 0.5 }

        // Outer forest wall — soft bounce just inside the treeline edge
        let lateral = worldX - trackCenterX(worldZ)
        let forestEdge = difficulty.clearZone + 152.0
        if abs(lateral) > forestEdge {
            worldX = trackCenterX(worldZ) + (lateral > 0 ? forestEdge : -forestEdge)
            forwardSpeed *= 0.65; turnRate *= -0.3
        }

        // Tree collision
        resolveTreeCollisions()
        resolveObstacleCollisions()

        // Hover physics with organic bob
        let bob1 = sin(timeAccum * 1.7 * .pi * 2) * 0.13
        let bob2 = sin(timeAccum * 2.9 * .pi * 2) * 0.055
        let bobScale = 0.5 + forwardSpeed / maxNormalSpeed * 0.9
        let hoverTarget: Float = 1.35 + (bob1 + bob2) * bobScale
        var accel: Float = -24.0
        if speederY < 3.0 { accel += (hoverTarget - speederY) * 55.0 - velocityY * 14.0 }
        velocityY += accel * dt; speederY += velocityY * dt
        if speederY < 0.4 { speederY = 0.4; velocityY = max(velocityY, 0) }

        // Speeder nodes
        speederPivot.position    = SCNVector3(worldX, speederY, worldZ)
        speederPivot.eulerAngles = SCNVector3(0, heading, 0)
        bankAngle  += (-(turnRate / maxTurnRate) * 0.72 - bankAngle)  * min(1, dt * 5.5)
        pitchAngle += (-velocityY * 0.022 - pitchAngle) * min(1, dt * 6)
        speederBody.eulerAngles = SCNVector3(pitchAngle, 0, bankAngle)

        updateCamera(dt: dt)
    }

    private func updateCamera(dt: Float) {
        // Camera — pulled back to see full bike
        let camDist: Float = 5.5
        camY += (speederY + 1.60 - camY) * min(1, dt * 7)
        camY  = max(camY, speederY + 0.70)
        let speedRatio = Double(forwardSpeed / maxBoostSpeed)
        let t = forwardSpeed / maxBoostSpeed
        let shake = t * (1.8 - t * 0.9)
        let shX = (sin(timeAccum * 61.3) * 0.020 + sin(timeAccum * 127.7) * 0.008) * shake
        let shY = (sin(timeAccum * 43.1) * 0.010 + sin(timeAccum * 97.9)  * 0.005) * shake
        cameraNode.position = SCNVector3(worldX - sin(heading)*camDist + shX,
                                         camY + shY,
                                         worldZ - cos(heading)*camDist)
        let lookDist: Float = 10 + Float(speedRatio) * 18
        cameraNode.look(at: SCNVector3(worldX + sin(heading)*lookDist, speederY - 0.30, worldZ + cos(heading)*lookDist),
                        up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        let bankTarget = (turnRate / maxTurnRate) * 0.52 + trackBankAngle(worldZ) * 0.70
        camBankAngle += (bankTarget - camBankAngle) * min(1, dt * 7)
        cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
                                              simd_quatf(angle: camBankAngle, axis: SIMD3<Float>(0, 0, 1)))

        // FOV
        currentFOV += (88.0 + speedRatio * 36.0 - currentFOV) * Double(min(1, dt * 7))
        cameraNode.camera?.fieldOfView = currentFOV

        // Motion blur — scales with speed
        let targetBlur = speedRatio * 0.46
        let curBlur    = Double(cameraNode.camera?.motionBlurIntensity ?? 0)
        cameraNode.camera?.motionBlurIntensity = CGFloat(curBlur + (targetBlur - curBlur) * Double(min(1, dt*4)))

        // DOF — subtle cinematic depth on high quality
        if quality == .high, let cam = cameraNode.camera {
            cam.focusDistance = CGFloat(lookDist * 0.7)
        }

        // Infinite mode: stream trees
        if mode == .infinite && abs(worldZ - lastTreeZ) > quality.streamRange * 0.30 {
            lastTreeZ = worldZ
            streamTrees(zStart: worldZ - quality.streamRange * 0.6, zEnd: worldZ + quality.streamRange)
        }

        // Thruster trail intensity — subtle exhaust wisps
        let trailRate = CGFloat(max(0, forwardSpeed / maxBoostSpeed)) * 40 + (isBoosting ? 30 : 0)
        thrusterTrail?.birthRate = trailRate
        if isBoosting {
            thrusterTrail?.particleColor = UIColor(red: 0.8, green: 0.45, blue: 0.15, alpha: 0.35)
        } else {
            thrusterTrail?.particleColor = UIColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 0.25)
        }

        for n in skyNodes { n.position = SCNVector3(worldX, 0, worldZ) }
        sunNode.position = SCNVector3(worldX + 480, 430, worldZ - 880)
    }

    private func resolveObstacleCollisions() {
        for obs in corridorObstacles {
            let dx = worldX - obs.x; let dz = worldZ - obs.z
            guard abs(dx) < 6 && abs(dz) < 6 else { continue }
            let dist2 = dx*dx + dz*dz; let minD = obs.r + speederRadius
            guard dist2 < minD*minD, dist2 > 0.0001 else { continue }
            if abs(forwardSpeed) > 5 { triggerCrash(); return }
            let dist = sqrt(dist2)
            worldX += (dx/dist)*(minD-dist); worldZ += (dz/dist)*(minD-dist)
            forwardSpeed *= 0.76
        }
    }

    private func resolveTreeCollisions() {
        let cx = Int(floorf(worldX / treeGridCell))
        let cz = Int(floorf(worldZ / treeGridCell))
        for gx in (cx - 1)...(cx + 1) {
            for gz in (cz - 1)...(cz + 1) {
                let key = Int64(Int32(gx)) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: Int32(gz))))
                guard let cell = treeGrid[key] else { continue }
                for tree in cell {
                    let dx = worldX - tree.x; let dz = worldZ - tree.z
                    let dist2 = dx*dx + dz*dz; let minD = tree.r + speederRadius
                    guard dist2 < minD*minD, dist2 > 0.0001 else { continue }
                    if forwardSpeed > 5 { triggerCrash(); return }
                    let dist = sqrt(dist2)
                    worldX += (dx/dist)*(minD-dist); worldZ += (dz/dist)*(minD-dist)
                    forwardSpeed *= 0.88
                }
            }
        }
    }

    private func treeGridKey(_ x: Float, _ z: Float) -> Int64 {
        let gx = Int32(floorf(x / treeGridCell))
        let gz = Int32(floorf(z / treeGridCell))
        return Int64(gx) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: gz)))
    }

    private func rebuildTreeGrid() {
        var grid = [Int64: [(x: Float, z: Float, r: Float)]]()
        for t in treePositions {
            let key = treeGridKey(t.x, t.z)
            grid[key, default: []].append(t)
        }
        treeGrid = grid
    }

    var boostFraction: Float { boostEnergy }

    func triggerBoost() {
        guard boostEnergy > 0.15 else { return }  // need at least 15% to activate
        boostTimer = 2.5
    }

    // MARK: - Crash
    private func triggerCrash() {
        guard raceState == .racing || raceState == .waiting else { return }
        raceState = .crashed
        spawnExplosion(at: SCNVector3(worldX, speederY, worldZ))
        speederPivot.isHidden = true
        DispatchQueue.main.async { self.onCrash?() }
    }

    private func spawnExplosion(at position: SCNVector3) {
        // Core fireball burst
        let ps = SCNParticleSystem()
        ps.birthRate = 700; ps.emissionDuration = 0.14
        ps.particleLifeSpan = 1.1; ps.particleLifeSpanVariation = 0.4
        ps.particleSize = 0.38; ps.particleSizeVariation = 0.22
        ps.spreadingAngle = 180; ps.particleVelocity = 16; ps.particleVelocityVariation = 9
        ps.acceleration = SCNVector3(0, -4, 0)
        ps.particleColor = UIColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 1)
        ps.particleColorVariation = SCNVector4(0.04, 0.28, 0.14, 0)
        ps.blendMode = .additive; ps.isLightingEnabled = false

        // Debris sparks
        let sparks = SCNParticleSystem()
        sparks.birthRate = 300; sparks.emissionDuration = 0.10
        sparks.particleLifeSpan = 1.6; sparks.particleLifeSpanVariation = 0.6
        sparks.particleSize = 0.12; sparks.particleSizeVariation = 0.08
        sparks.spreadingAngle = 180; sparks.particleVelocity = 22; sparks.particleVelocityVariation = 12
        sparks.acceleration = SCNVector3(0, -9, 0)
        sparks.particleColor = UIColor(red: 1.0, green: 0.88, blue: 0.30, alpha: 1)
        sparks.blendMode = .additive; sparks.isLightingEnabled = false

        let node = SCNNode(); node.position = position
        rootNode.addChildNode(node)
        node.addParticleSystem(ps)
        node.addParticleSystem(sparks)
        node.runAction(.sequence([.wait(duration: 4.0), .removeFromParentNode()]))
    }
}

// MARK: - SCNNode builder helper
infix operator ※ : MultiplicationPrecedence
@discardableResult
private func ※ <T: SCNNode>(node: T, configure: (T) -> Void) -> T { configure(node); return node }
