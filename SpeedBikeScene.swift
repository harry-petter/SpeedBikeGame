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
    var onNearMiss: ((Float) -> Void)?       // closeness 0..1
    var onCheckpoint: ((Int, Float) -> Void)? // index, raceTime
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
    private var pollenSystem: SCNParticleSystem?

    // Near-miss
    private let nearMissThreshold: Float = 2.8
    private var nearMissCooldown: Float = 0

    // Checkpoint
    private(set) var lastCheckpointIndex: Int = -1
    private(set) var checkpointTimes: [Float] = []

    // Finish spectacle
    private(set) var finishCamActive: Bool = false
    private var finishCamTimer: Float = 0
    private var finishWorldPos: SCNVector3 = .init()

    // Boost effects
    private var boostFOVKick: Double = 0
    private var boostJustActivated: Bool = false

    // Dynamic fog
    private let fogColorOpen  = UIColor(red: 0.42, green: 0.62, blue: 0.76, alpha: 1)
    private let fogColorDense = UIColor(red: 0.34, green: 0.52, blue: 0.38, alpha: 1)
    private var currentFogLerp: Float = 0


    // MARK: - Trees
    // 0-2 = broadleaf small/med/large, 3-4 = conifers, 5 = dead tree,
    // 6 = birch, 7 = willow, 8 = twisted oak
    // Saplings (destructible): 9 = thin sapling, 10 = young birch
    private var treeGeoms:  [SCNGeometry] = []
    private var canopyGeoms:[SCNGeometry] = []
    private let treeHeights:[Float] = [22, 42, 65, 35, 55, 18,  28, 30, 20,   10, 12]
    private let canopyRadii:[Float] = [5.5, 9.0, 14.0, 5.0, 7.0, 0,  4.5, 8.0, 6.0,  2.0, 2.5]
    private let trunkRadii: [Float] = [0.42, 0.80, 1.40, 0.40, 0.60, 0.55,  0.30, 0.50, 0.70,  0.15, 0.12]
    // Per-type collision properties:
    // crashSpeed = speed above which you explode (Float.infinity = never crash)
    // smashPenalty = speed multiplier when smashing through (lower = bigger hit)
    private let treeCrashSpeed: [Float] = [
        //  0     1     2     3     4      5       6      7      8      9     10
        .infinity, 65, 45, .infinity, 65, .infinity, .infinity, 70, 70, .infinity, .infinity
    ]
    private let treeSmashPenalty: [Float] = [
        // 0    1     2     3     4     5     6     7     8     9     10
        0.78, 0.60, 0.45, 0.78, 0.60, 0.75, 0.78, 0.65, 0.65, 0.92, 0.92
    ]
    private var bushGeoms:    [SCNGeometry] = []
    private let bushRadii:    [Float] = [0.65, 1.05, 1.55, 0.45]
    private var fernGeoms:    [SCNGeometry] = []

    private var giantTrunkGeo: SCNGeometry?
    private var giantCanopyGeo: SCNGeometry?
    private var lastTreeZ:  Float   = Float.infinity
    private let treeQueue = DispatchQueue(label: "treeGen", qos: .userInitiated)

    // Tree collision data — crashSpeed threshold and penalty per tree
    private struct TreeEntry {
        let x: Float; let z: Float; let r: Float
        let crashSpeed: Float     // speed above which you explode (∞ = always smashable)
        let smashPenalty: Float   // speed multiplier on smash-through
        weak var node: SCNNode?   // node ref so we can remove on smash
    }
    private var treePositions: [TreeEntry] = []
    private var treeGrid: [Int64: [TreeEntry]] = [:]
    private let treeGridCell: Float = 16
    private let speederRadius: Float = 0.55
    var onTreeSmashed: ((Float) -> Void)?  // intensity 0..1 (bigger tree = higher)
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
        buildCanopyShadows()

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
        isBoosting = false; nearMissCooldown = 0
        lastCheckpointIndex = -1; checkpointTimes = []
        finishCamActive = false; finishCamTimer = 0
        boostFOVKick = 0; boostJustActivated = false; currentFogLerp = 0
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

    // MARK: - Canopy shadow patches on ground
    private func buildCanopyShadows() {
        let maxZ = mode == .race ? trackLength : Float(800)
        var rng: UInt64 = 0x12345678
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(1 << 31)
        }
        let shadowMat = SCNMaterial()
        shadowMat.diffuse.contents = UIColor(red: 0.02, green: 0.06, blue: 0.02, alpha: 1)
        shadowMat.lightingModel = .constant; shadowMat.transparency = 0.22; shadowMat.writesToDepthBuffer = false
        var z: Float = 60
        while z < maxZ {
            let tc = trackCenterX(z)
            let w = CGFloat(8 + rnd() * 10); let h = CGFloat(5 + rnd() * 6)
            let plane = SCNPlane(width: w, height: h); plane.firstMaterial = shadowMat
            let n = SCNNode(geometry: plane)
            n.eulerAngles.x = -.pi / 2
            n.position = SCNVector3(tc + (rnd() - 0.5) * corridorHalf * 1.2, 0.02, z)
            n.castsShadow = false
            rootNode.addChildNode(n)
            z += 90 + rnd() * 60
        }
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
        // Dramatic sweeping bends — encourages tree shortcuts
        let wide   = 130 * sin(z / 380)                         // huge long-period sweeps
        let medium =  70 * sin(z / 150 + 0.8)                   // mid-frequency bends
        let tight  =  28 * sin(z / 55 + 2.2)                    // quick chicanes
        let wiggle =   6 * sin(z / 28 + 1.5)                    // road texture
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
        let dx = 130/380 * cos(z/380) + 70/150 * cos(z/150 + 0.8) + 28/55 * cos(z/55 + 2.2)
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
        // Trunk colors for all 11 types
        let trunkCols: [(CGFloat,CGFloat,CGFloat)] = [
            (0.30, 0.18, 0.09),  // 0: small broadleaf
            (0.25, 0.15, 0.075), // 1: med broadleaf
            (0.20, 0.12, 0.06),  // 2: large broadleaf
            (0.28, 0.16, 0.08),  // 3: conifer 1
            (0.22, 0.13, 0.07),  // 4: conifer 2
            (0.35, 0.22, 0.12),  // 5: dead tree
            (0.82, 0.78, 0.72),  // 6: birch (white bark)
            (0.28, 0.17, 0.08),  // 7: willow
            (0.32, 0.16, 0.06),  // 8: twisted oak
            (0.34, 0.22, 0.10),  // 9: sapling (destructible)
            (0.75, 0.72, 0.66),  // 10: young birch (destructible)
        ]
        for i in 0..<trunkCols.count {
            let h = treeHeights[i]
            let cyl = SCNCylinder(radius: CGFloat(trunkRadii[i]), height: CGFloat(h)); cyl.radialSegmentCount = 6; cyl.heightSegmentCount = 1
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: trunkCols[i].0, green: trunkCols[i].1, blue: trunkCols[i].2, alpha: 1)
            m.lightingModel = .lambert; cyl.firstMaterial = m; treeGeoms.append(cyl)
        }

        // Canopies: 0-2 = round broadleaf, 3-4 = conical pines, 5 = dead, 6 = birch, 7 = willow, 8 = twisted oak, 9-10 = saplings
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
        // Birch — light airy canopy, slightly yellow-green
        let birchCanopyMat = SCNMaterial(); birchCanopyMat.diffuse.contents = UIColor(red: 0.32, green: 0.58, blue: 0.18, alpha: 1); birchCanopyMat.lightingModel = .lambert
        let birchCanopy = SCNSphere(radius: CGFloat(canopyRadii[6])); birchCanopy.segmentCount = 6; birchCanopy.firstMaterial = birchCanopyMat
        canopyGeoms.append(birchCanopy)
        // Willow — wide droopy oval canopy
        let willowMat = SCNMaterial(); willowMat.diffuse.contents = UIColor(red: 0.15, green: 0.42, blue: 0.12, alpha: 1); willowMat.lightingModel = .lambert
        let willowCanopy = SCNSphere(radius: CGFloat(canopyRadii[7])); willowCanopy.segmentCount = 7; willowCanopy.firstMaterial = willowMat
        canopyGeoms.append(willowCanopy)
        // Twisted oak — irregular canopy
        let oakMat = SCNMaterial(); oakMat.diffuse.contents = UIColor(red: 0.18, green: 0.40, blue: 0.10, alpha: 1); oakMat.lightingModel = .lambert
        let oakCanopy = SCNSphere(radius: CGFloat(canopyRadii[8])); oakCanopy.segmentCount = 5; oakCanopy.firstMaterial = oakMat
        canopyGeoms.append(oakCanopy)
        // Sapling canopies — small light leafy tops
        let sapMat1 = SCNMaterial(); sapMat1.diffuse.contents = UIColor(red: 0.28, green: 0.56, blue: 0.16, alpha: 1); sapMat1.lightingModel = .lambert
        let sapCanopy1 = SCNSphere(radius: CGFloat(canopyRadii[9])); sapCanopy1.segmentCount = 5; sapCanopy1.firstMaterial = sapMat1
        canopyGeoms.append(sapCanopy1)
        let sapMat2 = SCNMaterial(); sapMat2.diffuse.contents = UIColor(red: 0.36, green: 0.60, blue: 0.22, alpha: 1); sapMat2.lightingModel = .lambert
        let sapCanopy2 = SCNSphere(radius: CGFloat(canopyRadii[10])); sapCanopy2.segmentCount = 5; sapCanopy2.firstMaterial = sapMat2
        canopyGeoms.append(sapCanopy2)

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
        let crashSpeeds = treeCrashSpeed; let smashPenalties = treeSmashPenalty
        let solidTypeCount = 9  // types 0-8 are solid trees
        let saplingTypes = [9, 10]  // destructible saplings
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
            var positions = [TreeEntry]()
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
                            // ~20% chance of sapling near track edge, solid tree otherwise
                            let nearTrack = offX < clearHalf + 12
                            let isSapling = nearTrack && cr(iz, ix, si, 5) < 0.22
                            let gIdx: Int
                            if isSapling {
                                gIdx = saplingTypes[Int(cr(iz, ix, si, 6) * Float(saplingTypes.count - 1) + 0.5) % saplingTypes.count]
                            } else {
                                let gRaw = Int(cr(iz, ix, si, 3) * Float(solidTypeCount - 1) + 0.5) % solidTypeCount
                                gIdx = fromEdge < 0.32 ? max(gRaw, 1) : gRaw
                            }
                            let hScale = cr(iz, ix, si, 4) * 0.55 + 0.72
                            let h      = heights[gIdx] * hScale
                            let tx = tc + side * offX + jx; let tz = wz + jz

                            // All trees get a parent node so any can be removed on smash
                            let treeNode = SCNNode()

                            let trunk = SCNNode(geometry: geos[gIdx])
                            trunk.position = SCNVector3(tx, h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            if !treeShadows { trunk.castsShadow = false }
                            treeNode.addChildNode(trunk)
                            let canopy = SCNNode(geometry: cGeos[gIdx])
                            if gIdx >= 3 && gIdx <= 4 {
                                canopy.position = SCNVector3(tx, h * 0.55, tz)
                            } else if gIdx == 5 {
                                canopy.position = SCNVector3(tx, h * 0.85, tz)
                                canopy.scale = SCNVector3(1.2, 0.6, 1.2)
                            } else if gIdx == 7 {
                                // Willow: wide droopy canopy
                                canopy.position = SCNVector3(tx, h * 0.65, tz)
                                canopy.scale = SCNVector3(1.4, 0.55, 1.4)
                            } else if gIdx == 8 {
                                // Twisted oak: irregular canopy, slight offset
                                canopy.position = SCNVector3(tx + 1.0, h * 0.78, tz)
                                canopy.scale = SCNVector3(1.1, 0.65, 0.9)
                            } else {
                                canopy.position = SCNVector3(tx, h - cRadii[gIdx] * 0.1, tz)
                                canopy.scale = SCNVector3(1.0, 0.72, 1.0)
                            }
                            if !treeShadows { canopy.castsShadow = false }
                            treeNode.addChildNode(canopy)
                            newRoot.addChildNode(treeNode)

                            positions.append(TreeEntry(
                                x: tx, z: tz, r: tRadii[gIdx] * 1.2,
                                crashSpeed: crashSpeeds[gIdx],
                                smashPenalty: smashPenalties[gIdx],
                                node: treeNode))
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
                            // Giants always crash — crashSpeed 0 means any contact kills
                            positions.append(TreeEntry(x: gx, z: gzz, r: 3.5 * 1.2,
                                                       crashSpeed: 0, smashPenalty: 0, node: nil))
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

        // ── Main fuselage ──
        let hull = SCNBox(width: 0.32, height: 0.18, length: 5.8, chamferRadius: 0.06); hull.firstMaterial = pbr(0.12, 0.12, 0.15, metal: 0.5, rough: 0.30)
        speederBody.addChildNode(SCNNode(geometry: hull))
        // Upper fairing with accent color
        let fairing = SCNBox(width: 0.24, height: 0.08, length: 4.0, chamferRadius: 0.04); fairing.firstMaterial = pbr(0.55, 0.52, 0.48, metal: 0.65, rough: 0.22)
        speederBody.addChildNode(SCNNode(geometry: fairing) ※ { $0.position = SCNVector3(0, 0.13, -0.3) })
        // Armored belly plate
        let belly = SCNBox(width: 0.40, height: 0.06, length: 5.0, chamferRadius: 0.03); belly.firstMaterial = pbr(0.20, 0.20, 0.23, metal: 0.55, rough: 0.38)
        speederBody.addChildNode(SCNNode(geometry: belly) ※ { $0.position = SCNVector3(0, -0.12, 0) })
        // Side armor panels
        for side: Float in [-1, 1] {
            let panel = SCNBox(width: 0.03, height: 0.14, length: 3.2, chamferRadius: 0.01); panel.firstMaterial = pbr(0.16, 0.16, 0.19, metal: 0.6, rough: 0.28)
            speederBody.addChildNode(SCNNode(geometry: panel) ※ { $0.position = SCNVector3(side * 0.17, 0.02, -0.2) })
        }

        // ── Nose section ──
        let noseCone = SCNBox(width: 0.18, height: 0.12, length: 0.80, chamferRadius: 0.05); noseCone.firstMaterial = pbr(0.48, 0.46, 0.43, metal: 0.7, rough: 0.18)
        speederBody.addChildNode(SCNNode(geometry: noseCone) ※ { $0.position = SCNVector3(0, 0.02, -3.28) })
        let noseCap = SCNSphere(radius: 0.10); noseCap.segmentCount = 8; noseCap.firstMaterial = pbr(0.55, 0.52, 0.50, metal: 0.85, rough: 0.12)
        speederBody.addChildNode(SCNNode(geometry: noseCap) ※ { $0.position = SCNVector3(0, 0.02, -3.70) })
        // Nose sensor array
        let sensor = SCNCylinder(radius: 0.025, height: 0.30); sensor.radialSegmentCount = 6; sensor.firstMaterial = pbr(0.35, 0.35, 0.38, metal: 0.8, rough: 0.15)
        speederBody.addChildNode(SCNNode(geometry: sensor) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(0, 0.06, -3.80) })
        let sensorTip = SCNSphere(radius: 0.03); sensorTip.segmentCount = 6; sensorTip.firstMaterial = glow(1.0, 0.20, 0.05)
        speederBody.addChildNode(SCNNode(geometry: sensorTip) ※ { $0.position = SCNVector3(0, 0.06, -3.95) })
        // Headlights
        for side: Float in [-1, 1] {
            let light = SCNCylinder(radius: 0.035, height: 0.03); light.radialSegmentCount = 8; light.firstMaterial = glow(0.90, 0.95, 1.0, s: 1.5)
            speederBody.addChildNode(SCNNode(geometry: light) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side * 0.08, 0.02, -3.60) })
        }

        // ── Cockpit ──
        let cpBody = SCNBox(width: 0.26, height: 0.15, length: 1.20, chamferRadius: 0.05); cpBody.firstMaterial = pbr(0.40, 0.38, 0.36, metal: 0.55, rough: 0.28)
        speederBody.addChildNode(SCNNode(geometry: cpBody) ※ { $0.position = SCNVector3(0, 0.19, -1.1) })
        let shield = SCNBox(width: 0.22, height: 0.14, length: 0.60, chamferRadius: 0.04); shield.firstMaterial = glass()
        speederBody.addChildNode(SCNNode(geometry: shield) ※ { $0.position = SCNVector3(0, 0.27, -1.55); $0.eulerAngles.x = -0.22 })
        // Handlebars
        let bar = SCNCapsule(capRadius: 0.030, height: 0.78); bar.firstMaterial = pbr(0.28, 0.28, 0.30, metal: 0.8, rough: 0.15)
        speederBody.addChildNode(SCNNode(geometry: bar) ※ { $0.eulerAngles.z = .pi/2; $0.position = SCNVector3(0, 0.22, -1.85) })
        // Handlebar grips
        for side: Float in [-1, 1] {
            let grip = SCNCylinder(radius: 0.038, height: 0.10); grip.radialSegmentCount = 8; grip.firstMaterial = pbr(0.08, 0.08, 0.08, metal: 0.1, rough: 0.8)
            speederBody.addChildNode(SCNNode(geometry: grip) ※ { $0.eulerAngles.z = .pi/2; $0.position = SCNVector3(side * 0.42, 0.22, -1.85) })
        }
        // Instrument cluster — small glowing panel behind windshield
        let instrument = SCNBox(width: 0.14, height: 0.02, length: 0.10, chamferRadius: 0.005); instrument.firstMaterial = glow(0.10, 0.80, 0.50, s: 0.6)
        speederBody.addChildNode(SCNNode(geometry: instrument) ※ { $0.position = SCNVector3(0, 0.22, -1.40) })
        // Side console boxes
        for side: Float in [-1, 1] {
            let console = SCNBox(width: 0.06, height: 0.05, length: 0.30, chamferRadius: 0.01); console.firstMaterial = pbr(0.22, 0.22, 0.25, metal: 0.5, rough: 0.35)
            speederBody.addChildNode(SCNNode(geometry: console) ※ { $0.position = SCNVector3(side * 0.14, 0.15, -0.6) })
        }

        // ── Engine pods (larger, more detailed) ──
        for side: Float in [-1, 1] {
            // Main turbine nacelle
            let pod = SCNCylinder(radius: 0.20, height: 5.40); pod.radialSegmentCount = 12; pod.firstMaterial = pbr(0.16, 0.16, 0.19, metal: 0.65, rough: 0.25)
            speederBody.addChildNode(SCNNode(geometry: pod) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side * 0.46, -0.14, 0.20) })
            // Engine cowling — wider section at front
            let cowl = SCNCone(topRadius: 0.16, bottomRadius: 0.24, height: 0.50); cowl.radialSegmentCount = 12; cowl.firstMaterial = pbr(0.20, 0.20, 0.22, metal: 0.7, rough: 0.22)
            speederBody.addChildNode(SCNNode(geometry: cowl) ※ { $0.eulerAngles.x = -.pi/2; $0.position = SCNVector3(side * 0.46, -0.14, -2.30) })
            // Intake rings (4 per pod)
            for i in 0..<4 {
                let ring = SCNTorus(ringRadius: 0.24, pipeRadius: 0.022); ring.ringSegmentCount = 16; ring.pipeSegmentCount = 5
                ring.firstMaterial = pbr(0.42, 0.42, 0.44, metal: 0.85, rough: 0.15)
                speederBody.addChildNode(SCNNode(geometry: ring) ※ { $0.position = SCNVector3(side * 0.46, -0.14, -0.80 + Float(i)*0.35) })
            }
            // Exhaust bell
            let bell = SCNCone(topRadius: 0.14, bottomRadius: 0.24, height: 0.35); bell.radialSegmentCount = 12; bell.firstMaterial = glow(1.0, 0.38, 0.06)
            speederBody.addChildNode(SCNNode(geometry: bell) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.46, -0.14, 3.10) })
            // Exhaust core glow
            let exhaust = SCNCylinder(radius: 0.12, height: 0.50); exhaust.radialSegmentCount = 10; exhaust.firstMaterial = glow(1.0, 0.22, 0.03, s: 1.6)
            speederBody.addChildNode(SCNNode(geometry: exhaust) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.46, -0.14, 3.45) })
            // Pylon connecting pod to fuselage
            let pylon = SCNBox(width: 0.18, height: 0.07, length: 1.30, chamferRadius: 0.02); pylon.firstMaterial = pbr(0.26, 0.26, 0.28, metal: 0.55, rough: 0.35)
            speederBody.addChildNode(SCNNode(geometry: pylon) ※ { $0.position = SCNVector3(side*0.24, -0.10, 0.20) })
            // Rear pylon strut
            let rearPylon = SCNBox(width: 0.10, height: 0.05, length: 0.80, chamferRadius: 0.01); rearPylon.firstMaterial = pbr(0.24, 0.24, 0.26, metal: 0.5, rough: 0.38)
            speederBody.addChildNode(SCNNode(geometry: rearPylon) ※ { $0.position = SCNVector3(side*0.24, -0.08, 2.0) })
            // Cooling fins (4 per side)
            for fi in 0..<4 {
                let fin = SCNBox(width: 0.02, height: 0.24, length: 0.50, chamferRadius: 0.005); fin.firstMaterial = pbr(0.30, 0.30, 0.32, metal: 0.7, rough: 0.22)
                speederBody.addChildNode(SCNNode(geometry: fin) ※ { $0.position = SCNVector3(side*0.46, 0.08, -0.90 + Float(fi)*0.48) })
            }
            // Running light stripe
            let stripe = SCNBox(width: 0.03, height: 0.03, length: 3.20, chamferRadius: 0.008); stripe.firstMaterial = glow(0.12, 0.70, 1.0, s: 0.55)
            speederBody.addChildNode(SCNNode(geometry: stripe) ※ { $0.position = SCNVector3(side*0.18, 0.09, -0.10) })
            // Engine detail greebles — small boxes on nacelle
            for gz in stride(from: Float(-1.0), through: 1.5, by: 0.80) {
                let greeble = SCNBox(width: 0.06, height: 0.06, length: 0.12, chamferRadius: 0.005); greeble.firstMaterial = pbr(0.25, 0.25, 0.28, metal: 0.6, rough: 0.30)
                speederBody.addChildNode(SCNNode(geometry: greeble) ※ { $0.position = SCNVector3(side*0.46 + side*0.20, -0.14, gz) })
            }
            // Rear tail light
            let tailLight = SCNCylinder(radius: 0.04, height: 0.02); tailLight.radialSegmentCount = 8; tailLight.firstMaterial = glow(1.0, 0.10, 0.05, s: 1.2)
            speederBody.addChildNode(SCNNode(geometry: tailLight) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.46, -0.06, 3.55) })
        }

        // ── Repulsor pads (with wider hover rings) ──
        for (pz, pr): (Float, Float) in [(-1.8, 0.26), (0.0, 0.22), (2.0, 0.20)] {
            let pad = SCNCylinder(radius: CGFloat(pr), height: 0.04); pad.radialSegmentCount = 14; pad.firstMaterial = glow(0.12, 0.62, 1.0, s: 1.3)
            speederBody.addChildNode(SCNNode(geometry: pad) ※ { $0.position = SCNVector3(0, -0.26, pz) })
            let ring = SCNTorus(ringRadius: CGFloat(pr*1.6), pipeRadius: 0.018); ring.ringSegmentCount = 14; ring.pipeSegmentCount = 5; ring.firstMaterial = glow(0.08, 0.40, 0.90, s: 0.50)
            speederBody.addChildNode(SCNNode(geometry: ring) ※ { $0.position = SCNVector3(0, -0.24, pz) })
            // Inner glow disc
            let disc = SCNCylinder(radius: CGFloat(pr * 0.6), height: 0.01); disc.radialSegmentCount = 10; disc.firstMaterial = glow(0.08, 0.50, 1.0, s: 0.8)
            speederBody.addChildNode(SCNNode(geometry: disc) ※ { $0.position = SCNVector3(0, -0.28, pz) })
        }

        // ── Rear section ──
        // Control vanes (X-pattern)
        for angle: Float in [0.52, -0.52, .pi/2+0.52, .pi/2-0.52] {
            let vane = SCNBox(width: 0.42, height: 0.04, length: 0.60, chamferRadius: 0.01); vane.firstMaterial = pbr(0.34, 0.32, 0.30, metal: 0.6, rough: 0.28)
            speederBody.addChildNode(SCNNode(geometry: vane) ※ { $0.position = SCNVector3(0, -0.06, 2.60); $0.eulerAngles.z = angle })
        }
        // Tall tail fin
        let tailFin = SCNBox(width: 0.04, height: 0.40, length: 0.72, chamferRadius: 0.015); tailFin.firstMaterial = pbr(0.36, 0.34, 0.32, metal: 0.55, rough: 0.30)
        speederBody.addChildNode(SCNNode(geometry: tailFin) ※ { $0.position = SCNVector3(0, 0.26, 2.55) })
        // Tail fin tip light
        let finLight = SCNSphere(radius: 0.02); finLight.segmentCount = 6; finLight.firstMaterial = glow(1.0, 0.15, 0.05, s: 1.0)
        speederBody.addChildNode(SCNNode(geometry: finLight) ※ { $0.position = SCNVector3(0, 0.48, 2.55) })
        // Antenna mast
        let antenna = SCNCylinder(radius: 0.012, height: 0.28); antenna.radialSegmentCount = 5; antenna.firstMaterial = pbr(0.40, 0.40, 0.42, metal: 0.8, rough: 0.15)
        speederBody.addChildNode(SCNNode(geometry: antenna) ※ { $0.position = SCNVector3(0, 0.38, -0.5) })
        let antennaTip = SCNSphere(radius: 0.018); antennaTip.segmentCount = 5; antennaTip.firstMaterial = glow(0.10, 1.0, 0.30, s: 0.7)
        speederBody.addChildNode(SCNNode(geometry: antennaTip) ※ { $0.position = SCNVector3(0, 0.53, -0.5) })

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
        buildPollenParticles()
    }

    // MARK: - Floating pollen / dust motes
    private func buildPollenParticles() {
        let p = SCNParticleSystem()
        p.birthRate = 6; p.emissionDuration = -1
        p.particleLifeSpan = 5.0; p.particleLifeSpanVariation = 2.0
        p.particleSize = 0.04; p.particleSizeVariation = 0.025
        p.spreadingAngle = 180; p.particleVelocity = 0.4; p.particleVelocityVariation = 0.3
        p.emittingDirection = SCNVector3(0.2, 0.1, 0)
        p.particleColor = UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.45)
        p.particleColorVariation = SCNVector4(0.05, 0.05, 0.1, 0.15)
        p.blendMode = .additive; p.isLightingEnabled = false
        p.emitterShape = SCNSphere(radius: 14)
        pollenSystem = p
        let dustNode = SCNNode()
        dustNode.addParticleSystem(p)
        cameraNode.addChildNode(dustNode)
    }

    // MARK: - Update
    func update(dt: Float, steer: Float, throttling: Bool, braking: Bool) {
        guard isLevelReady else { updateCamera(dt: dt); return }
        guard raceState != .crashed else { updateCamera(dt: dt); return }

        // Finish spectacle — slow-mo camera orbit, skip physics
        if finishCamActive {
            timeAccum += dt
            finishCamTimer += dt
            forwardSpeed = max(0, forwardSpeed - 40 * dt) // decelerate
            worldZ += cos(heading) * forwardSpeed * dt
            worldX += sin(heading) * forwardSpeed * dt
            updateFinishCamera(dt: dt)
            return
        }

        timeAccum += dt
        nearMissCooldown = max(0, nearMissCooldown - dt)

        // Race state
        switch raceState {
        case .waiting: if worldZ > 5 { raceState = .racing }
        case .racing:
            raceTime += dt
            // Checkpoint detection (gates every 250m)
            if mode == .race {
                let cpIdx = Int(worldZ / 250)
                if cpIdx > lastCheckpointIndex && cpIdx > 0 && worldZ < trackLength {
                    lastCheckpointIndex = cpIdx
                    checkpointTimes.append(raceTime)
                    DispatchQueue.main.async { self.onCheckpoint?(cpIdx, self.raceTime) }
                }
                if worldZ >= trackLength {
                    raceState = .finished
                    finishCamActive = true; finishCamTimer = 0
                    finishWorldPos = SCNVector3(worldX, speederY, worldZ)
                    // Celebratory particles at finish
                    spawnFinishCelebration(at: finishWorldPos)
                }
            }
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

        // Steering — allow full rotation even at standstill
        turnRate += (steer * maxTurnRate - turnRate) * min(1, dt * 5.5)
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
        bankAngle  += (-(turnRate / maxTurnRate) * 1.05 - bankAngle)  * min(1, dt * 5.5)
        pitchAngle += (-velocityY * 0.022 - pitchAngle) * min(1, dt * 6)
        speederBody.eulerAngles = SCNVector3(pitchAngle, 0, bankAngle)

        updateCamera(dt: dt)
    }

    private func updateCamera(dt: Float) {
        let camDist: Float = 5.5
        camY += (speederY + 1.60 - camY) * min(1, dt * 7)
        camY  = max(camY, speederY + 0.70)
        let speedRatio = Double(forwardSpeed / maxBoostSpeed)
        let t = forwardSpeed / maxBoostSpeed

        // Enhanced camera shake — quadratic ramp, multi-frequency, lateral drift
        let shake = t * t * 3.0
        let shX = (sin(timeAccum * 61.3) * 0.018 + sin(timeAccum * 127.7) * 0.008 + sin(timeAccum * 203.7) * 0.004) * shake
        let shY = (sin(timeAccum * 43.1) * 0.010 + sin(timeAccum * 97.9) * 0.005) * shake
        let lateralDrift = sin(timeAccum * 7.3) * t * t * 0.12  // slow side weave
        let perpX = -cos(heading) * lateralDrift
        let perpZ =  sin(heading) * lateralDrift

        cameraNode.position = SCNVector3(worldX - sin(heading)*camDist + shX + perpX,
                                         camY + shY,
                                         worldZ - cos(heading)*camDist + perpZ)
        let lookDist: Float = 10 + Float(speedRatio) * 18
        cameraNode.look(at: SCNVector3(worldX + sin(heading)*lookDist, speederY - 0.30, worldZ + cos(heading)*lookDist),
                        up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        let bankTarget = (turnRate / maxTurnRate) * 0.82 + trackBankAngle(worldZ) * 0.85
        camBankAngle += (bankTarget - camBankAngle) * min(1, dt * 7)
        cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
                                              simd_quatf(angle: camBankAngle, axis: SIMD3<Float>(0, 0, 1)))

        // FOV — with boost kick
        boostFOVKick = max(0, boostFOVKick - Double(dt) * 12)
        let targetFOV = 88.0 + speedRatio * 36.0 + boostFOVKick
        currentFOV += (targetFOV - currentFOV) * Double(min(1, dt * 3.5))
        cameraNode.camera?.fieldOfView = currentFOV

        // Motion blur
        let targetBlur = speedRatio * 0.46
        let curBlur    = Double(cameraNode.camera?.motionBlurIntensity ?? 0)
        cameraNode.camera?.motionBlurIntensity = CGFloat(curBlur + (targetBlur - curBlur) * Double(min(1, dt*4)))

        // DOF
        if quality == .high, let cam = cameraNode.camera {
            cam.focusDistance = CGFloat(lookDist * 0.7)
        }

        // Infinite mode: stream trees
        if mode == .infinite && abs(worldZ - lastTreeZ) > quality.streamRange * 0.30 {
            lastTreeZ = worldZ
            streamTrees(zStart: worldZ - quality.streamRange * 0.6, zEnd: worldZ + quality.streamRange)
        }

        // Thruster trail — smooth boost transition
        let targetTrailRate = CGFloat(max(0, forwardSpeed / maxBoostSpeed)) * 40 + (isBoosting ? 60 : 0)
        if boostJustActivated { boostJustActivated = false }
        let curRate = CGFloat(thrusterTrail?.birthRate ?? 0)
        thrusterTrail?.birthRate = curRate + (targetTrailRate - curRate) * CGFloat(min(1, dt * 5))
        if isBoosting {
            thrusterTrail?.particleColor = UIColor(red: 0.8, green: 0.45, blue: 0.15, alpha: 0.35)
            thrusterTrail?.particleSize = 0.06
        } else {
            thrusterTrail?.particleColor = UIColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 0.25)
            thrusterTrail?.particleSize = 0.04
        }

        // Dynamic fog color — shifts warmer in tight curves
        let curveIntensity = curvature(worldZ)
        currentFogLerp += (curveIntensity - currentFogLerp) * min(1, dt * 2)
        fogColor = lerpColor(fogColorOpen, fogColorDense, currentFogLerp)

        for n in skyNodes { n.position = SCNVector3(worldX, 0, worldZ) }
        sunNode.position = SCNVector3(worldX + 480, 430, worldZ - 880)
    }

    // MARK: - Finish camera sweep
    private func updateFinishCamera(dt: Float) {
        let orbitDur: Float = 3.5
        let phase = finishCamTimer / orbitDur
        if phase >= 1.0 { finishCamActive = false; return }
        let angle = phase * .pi * 1.2  // ~216° sweep
        let radius: Float = 8 + phase * 4  // pull out gradually
        let camHeight: Float = speederY + 2 + phase * 5
        cameraNode.position = SCNVector3(finishWorldPos.x + sin(angle) * radius,
                                         camHeight,
                                         finishWorldPos.z + cos(angle) * radius)
        cameraNode.look(at: SCNVector3(finishWorldPos.x, speederY + 0.5, finishWorldPos.z),
                        up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        // Slow zoom out FOV
        cameraNode.camera?.fieldOfView = 88 - Double(phase) * 20
    }

    // MARK: - Finish celebration particles
    private func spawnFinishCelebration(at position: SCNVector3) {
        let gold = SCNParticleSystem()
        gold.birthRate = 400; gold.emissionDuration = 0.8
        gold.particleLifeSpan = 2.5; gold.particleLifeSpanVariation = 0.8
        gold.particleSize = 0.15; gold.particleSizeVariation = 0.10
        gold.spreadingAngle = 180; gold.particleVelocity = 14; gold.particleVelocityVariation = 8
        gold.acceleration = SCNVector3(0, -3, 0)
        gold.particleColor = UIColor(red: 1.0, green: 0.85, blue: 0.20, alpha: 1)
        gold.particleColorVariation = SCNVector4(0.05, 0.15, 0.10, 0)
        gold.blendMode = .additive; gold.isLightingEnabled = false
        let node = SCNNode(); node.position = SCNVector3(position.x, position.y + 4, position.z)
        rootNode.addChildNode(node)
        node.addParticleSystem(gold)
        node.runAction(.sequence([.wait(duration: 5), .removeFromParentNode()]))
    }

    // MARK: - Color lerp helper
    private func lerpColor(_ a: UIColor, _ b: UIColor, _ t: Float) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let ct = CGFloat(max(0, min(1, t)))
        return UIColor(red: ar + (br-ar)*ct, green: ag + (bg-ag)*ct, blue: ab + (bb-ab)*ct, alpha: 1)
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
        var closestNearMiss: Float = Float.greatestFiniteMagnitude
        var smashedKeys = [(gridKey: Int64, index: Int)]()
        for gx in (cx - 1)...(cx + 1) {
            for gz in (cz - 1)...(cz + 1) {
                let key = Int64(Int32(gx)) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: Int32(gz))))
                guard let cell = treeGrid[key] else { continue }
                for (idx, tree) in cell.enumerated() {
                    let dx = worldX - tree.x; let dz = worldZ - tree.z
                    let dist2 = dx*dx + dz*dz; let minD = tree.r + speederRadius
                    if dist2 < minD*minD && dist2 > 0.0001 {
                        if forwardSpeed >= tree.crashSpeed {
                            // Too fast for this tree — crash
                            triggerCrash(); return
                        }
                        if forwardSpeed < 8 {
                            // Too slow to smash — just bump and stop
                            let dist = sqrt(dist2)
                            worldX += (dx/dist)*(minD-dist); worldZ += (dz/dist)*(minD-dist)
                            forwardSpeed *= 0.5
                        } else {
                            // Smash through — apply speed penalty, remove tree
                            forwardSpeed *= tree.smashPenalty
                            let breakHeight = treeHeights[min(treeHeights.count - 1, Int(tree.r / 0.2))]
                            spawnTreeSmash(at: SCNVector3(tree.x, breakHeight * 0.3, tree.z), intensity: 1.0 - tree.smashPenalty)
                            tree.node?.removeFromParentNode()
                            smashedKeys.append((gridKey: key, index: idx))
                            DispatchQueue.main.async { self.onTreeSmashed?(1.0 - tree.smashPenalty) }
                        }
                    } else {
                        // Near-miss detection
                        let nearDist = minD + nearMissThreshold
                        if dist2 < nearDist * nearDist && forwardSpeed > 15 {
                            let dist = sqrt(dist2)
                            let gap = dist - minD
                            closestNearMiss = min(closestNearMiss, gap)
                        }
                    }
                }
            }
        }
        // Remove smashed trees from grid (iterate in reverse to keep indices valid)
        for smashed in smashedKeys.sorted(by: { $0.index > $1.index }) {
            treeGrid[smashed.gridKey]?.remove(at: smashed.index)
        }
        // Fire near-miss callback for the closest tree
        if closestNearMiss < nearMissThreshold && nearMissCooldown <= 0 {
            nearMissCooldown = 0.35
            let closeness = 1.0 - (closestNearMiss / nearMissThreshold)
            DispatchQueue.main.async { self.onNearMiss?(closeness) }
        }
    }

    /// Spawn wood splinters + leaves scaled by impact intensity (0 = tiny sapling, 1 = large tree)
    private func spawnTreeSmash(at position: SCNVector3, intensity: Float) {
        let scale = 0.4 + intensity * 0.6  // 0.4..1.0
        // Wood splinter burst
        let splinters = SCNParticleSystem()
        splinters.birthRate = CGFloat(80 + intensity * 250); splinters.emissionDuration = 0.10
        splinters.particleLifeSpan = CGFloat(0.5 + intensity * 0.5); splinters.particleLifeSpanVariation = 0.2
        splinters.particleSize = CGFloat(0.06 + intensity * 0.10); splinters.particleSizeVariation = 0.05
        splinters.spreadingAngle = 140; splinters.particleVelocity = CGFloat(8 + intensity * 14); splinters.particleVelocityVariation = 6
        splinters.acceleration = SCNVector3(0, -14, 0)
        splinters.particleColor = UIColor(red: 0.45, green: 0.30, blue: 0.12, alpha: 1)
        splinters.particleColorVariation = SCNVector4(0.08, 0.06, 0.04, 0)
        splinters.blendMode = .alpha; splinters.isLightingEnabled = true
        // Leaf burst
        let leaves = SCNParticleSystem()
        leaves.birthRate = CGFloat(40 + intensity * 120); leaves.emissionDuration = 0.12
        leaves.particleLifeSpan = CGFloat(0.8 + intensity * 0.6); leaves.particleLifeSpanVariation = 0.4
        leaves.particleSize = CGFloat(0.10 + intensity * 0.10); leaves.particleSizeVariation = 0.08
        leaves.spreadingAngle = 160; leaves.particleVelocity = CGFloat(6 + intensity * 10); leaves.particleVelocityVariation = 4
        leaves.acceleration = SCNVector3(0, -6, 0)
        leaves.particleColor = UIColor(red: 0.22, green: 0.48, blue: 0.12, alpha: 1)
        leaves.particleColorVariation = SCNVector4(0.08, 0.12, 0.06, 0)
        leaves.blendMode = .alpha; leaves.isLightingEnabled = true
        let node = SCNNode(); node.position = SCNVector3(position.x, position.y * scale, position.z)
        rootNode.addChildNode(node)
        node.addParticleSystem(splinters); node.addParticleSystem(leaves)
        node.runAction(.sequence([.wait(duration: 2.0), .removeFromParentNode()]))
    }

    private func treeGridKey(_ x: Float, _ z: Float) -> Int64 {
        let gx = Int32(floorf(x / treeGridCell))
        let gz = Int32(floorf(z / treeGridCell))
        return Int64(gx) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: gz)))
    }

    private func rebuildTreeGrid() {
        var grid = [Int64: [TreeEntry]]()
        for t in treePositions {
            let key = treeGridKey(t.x, t.z)
            grid[key, default: []].append(t)
        }
        treeGrid = grid
    }

    var boostFraction: Float { boostEnergy }

    func triggerBoost() {
        guard boostEnergy > 0.15 else { return }
        boostTimer = 2.5
        boostFOVKick = 8
        boostJustActivated = true
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
        ps.birthRate = 900; ps.emissionDuration = 0.10
        ps.particleLifeSpan = 0.4; ps.particleLifeSpanVariation = 0.15
        ps.particleSize = 0.38; ps.particleSizeVariation = 0.22
        ps.spreadingAngle = 180; ps.particleVelocity = 28; ps.particleVelocityVariation = 14
        ps.acceleration = SCNVector3(0, -4, 0)
        ps.particleColor = UIColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 1)
        ps.particleColorVariation = SCNVector4(0.04, 0.28, 0.14, 0)
        ps.blendMode = .additive; ps.isLightingEnabled = false

        // Debris sparks
        let sparks = SCNParticleSystem()
        sparks.birthRate = 400; sparks.emissionDuration = 0.08
        sparks.particleLifeSpan = 0.5; sparks.particleLifeSpanVariation = 0.2
        sparks.particleSize = 0.12; sparks.particleSizeVariation = 0.08
        sparks.spreadingAngle = 180; sparks.particleVelocity = 35; sparks.particleVelocityVariation = 16
        sparks.acceleration = SCNVector3(0, -9, 0)
        sparks.particleColor = UIColor(red: 1.0, green: 0.88, blue: 0.30, alpha: 1)
        sparks.blendMode = .additive; sparks.isLightingEnabled = false

        let node = SCNNode(); node.position = position
        rootNode.addChildNode(node)
        node.addParticleSystem(ps)
        node.addParticleSystem(sparks)
        node.runAction(.sequence([.wait(duration: 1.5), .removeFromParentNode()]))
    }
}

// MARK: - SCNNode builder helper
infix operator ※ : MultiplicationPrecedence
@discardableResult
private func ※ <T: SCNNode>(node: T, configure: (T) -> Void) -> T { configure(node); return node }
