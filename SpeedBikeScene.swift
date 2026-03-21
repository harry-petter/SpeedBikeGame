import SceneKit
import UIKit

final class SpeedBikeScene: SCNScene {

    // MARK: - Config
    let mode:        GameMode
    let difficulty:  Difficulty
    let quality:     GraphicsQuality
    let trackLength: Float
    let islandRadius: Float = 750.0

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
    private var waterSpray: SCNParticleSystem?
    private var waterSprayNode: SCNNode?

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
    private var rootFlareGeoms: [SCNGeometry] = []
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
        self.trackLength = mode == .race ? 3200 : 0
        super.init()
        buildScene()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build
    private func buildScene() {
        background.contents = UIColor(red: 0.45, green: 0.68, blue: 0.96, alpha: 1)
        fogColor = UIColor(red: 0.38, green: 0.58, blue: 0.44, alpha: 1)
        fogStartDistance = 160; fogEndDistance = 420
        lightingEnvironment.contents = UIColor(white: 0.5, alpha: 1)
        lightingEnvironment.intensity = 1.0

        buildTreeGeoms(); buildBoulderGeoms(); addLighting(); addSky()

        if mode == .openWorld {
            fogColor = UIColor(red: 0.48, green: 0.60, blue: 0.78, alpha: 1)
            fogStartDistance = 500; fogEndDistance = 2000
            buildOpenWorldGround()
            buildSeaPlane()
            worldX = 0; worldZ = 0; heading = 0
        } else {
            buildGround()
            buildRacingLevel(); buildTrackDecorations()
            worldX = trackCenterX(worldZ)
            heading = spawnHeading()
        }

        buildSpeeder()
        buildCamera()
        buildCanopyShadows()

        if mode == .openWorld {
            buildOpenWorldVegetation()
        } else {
            buildAllTrees()
            buildForestPools()
        }
    }

    // MARK: - Reset
    func resetRace() {
        if mode == .openWorld {
            worldX = 0; worldZ = 0; heading = 0
        } else {
            let sz: Float = -12
            worldZ = sz; worldX = trackCenterX(sz); heading = spawnHeading()
        }
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
            (3100, UIColor(red: 0.45, green: 0.68, blue: 0.96, alpha: 1)),   // upper sky — bright blue
            (3070, UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1)),   // mid sky
            (3040, UIColor(red: 0.70, green: 0.82, blue: 0.92, alpha: 1)),   // warm horizon haze — pale
            (3010, UIColor(red: 0.58, green: 0.74, blue: 0.68, alpha: 1)),   // treeline blend — soft green-blue
        ]
        let skySegs = quality == .low ? 6 : quality == .medium ? 8 : 12
        for (r, col) in domes {
            let s = SCNSphere(radius: r); s.segmentCount = skySegs
            let m = SCNMaterial(); m.diffuse.contents = col
            m.isDoubleSided = true; m.lightingModel = .constant; s.firstMaterial = m
            let n = SCNNode(geometry: s); skyNodes.append(n); rootNode.addChildNode(n)
        }
        // Sun
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

        // Clouds
        addClouds()

        // Distant mountains (open world only)
        if mode == .openWorld { addDistantMountains() }
    }

    private func addClouds() {
        var rng: UInt64 = 0xc10dface
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(1 << 31)
        }

        let cloudMat = SCNMaterial()
        // Keep color well below bloom threshold to prevent glow
        cloudMat.diffuse.contents = UIColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 0.50)
        cloudMat.lightingModel = .constant; cloudMat.isDoubleSided = true
        cloudMat.writesToDepthBuffer = false
        // Clamp output to prevent bloom — cap brightness in fragment shader
        cloudMat.shaderModifiers = [
            .fragment: """
            float3 c = _surface.diffuse.rgb;
            c = min(c, float3(0.75));
            _output.color = float4(c, _surface.diffuse.a);
            """
        ]

        // Wispy edge material — more transparent for softer edges
        let wispMat = SCNMaterial()
        wispMat.diffuse.contents = UIColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 0.18)
        wispMat.lightingModel = .constant; wispMat.isDoubleSided = true
        wispMat.writesToDepthBuffer = false
        wispMat.shaderModifiers = [
            .fragment: """
            float3 c = _surface.diffuse.rgb;
            c = min(c, float3(0.75));
            _output.color = float4(c, _surface.diffuse.a);
            """
        ]

        let cloudContainer = SCNNode()

        let cloudCount = quality == .low ? 14 : quality == .medium ? 24 : 36
        for _ in 0..<cloudCount {
            let cloudNode = SCNNode()
            // Core puffs — overlapping flattened spheres
            let coreCount = Int(rnd() * 4) + 4
            for j in 0..<coreCount {
                let r = CGFloat(12 + rnd() * 20)
                let puff = SCNSphere(radius: r)
                puff.segmentCount = quality == .low ? 5 : 7
                puff.firstMaterial = cloudMat
                let n = SCNNode(geometry: puff)
                n.position = SCNVector3((rnd() - 0.5) * 50, (rnd() - 0.5) * 5, (rnd() - 0.5) * 20)
                // Flatten vertically for cloud shape
                let yScale = 0.25 + rnd() * 0.15
                let xScale = 0.9 + rnd() * 0.4
                n.scale = SCNVector3(xScale, yScale, 1.0)
                n.castsShadow = false
                cloudNode.addChildNode(n)

                // Wispy outer halo on some puffs
                if j % 2 == 0 {
                    let haloR = r * 1.5
                    let halo = SCNSphere(radius: haloR)
                    halo.segmentCount = quality == .low ? 4 : 6
                    halo.firstMaterial = wispMat
                    let hn = SCNNode(geometry: halo)
                    hn.position = n.position
                    hn.scale = SCNVector3(xScale * 1.2, yScale * 0.8, 1.3)
                    hn.castsShadow = false
                    cloudNode.addChildNode(hn)
                }
            }

            let angle = rnd() * .pi * 2
            let dist: Float = 600 + rnd() * 2000
            let height: Float = 180 + rnd() * 280
            cloudNode.position = SCNVector3(sin(angle) * dist, height, cos(angle) * dist)
            cloudNode.castsShadow = false
            cloudContainer.addChildNode(cloudNode)
        }

        skyNodes.append(cloudContainer)
        rootNode.addChildNode(cloudContainer)
    }

    private func addDistantMountains() {
        var rng: UInt64 = 0xb16b00b5
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(1 << 31)
        }

        let mtContainer = SCNNode()
        let peakCount = quality == .low ? 16 : quality == .medium ? 24 : 36

        for i in 0..<peakCount {
            let angle = Float(i) / Float(peakCount) * .pi * 2 + (rnd() - 0.5) * 0.15
            let dist: Float = 1400 + rnd() * 400
            let height: Float = 60 + rnd() * 180
            let width: Float = 80 + rnd() * 200

            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(width * 0.5), height: CGFloat(height))
            cone.radialSegmentCount = 6; cone.heightSegmentCount = 1
            let mat = SCNMaterial()
            let shade = 0.35 + rnd() * 0.15
            mat.diffuse.contents = UIColor(red: CGFloat(shade * 0.7), green: CGFloat(shade * 0.8),
                                           blue: CGFloat(shade * 1.0), alpha: 1)
            mat.lightingModel = .lambert
            cone.firstMaterial = mat

            let n = SCNNode(geometry: cone)
            n.position = SCNVector3(sin(angle) * dist, height * 0.3, cos(angle) * dist)
            n.castsShadow = false
            mtContainer.addChildNode(n)

            if height > 140 && rnd() > 0.3 {
                let cap = SCNCone(topRadius: 0, bottomRadius: CGFloat(width * 0.18), height: CGFloat(height * 0.25))
                cap.radialSegmentCount = 6; cap.heightSegmentCount = 1
                let snowMat = SCNMaterial()
                snowMat.diffuse.contents = UIColor(red: 0.88, green: 0.90, blue: 0.94, alpha: 1)
                snowMat.lightingModel = .lambert
                cap.firstMaterial = snowMat
                let capNode = SCNNode(geometry: cap)
                capNode.position = SCNVector3(0, height * 0.42, 0)
                capNode.castsShadow = false
                n.addChildNode(capNode)
            }
        }

        skyNodes.append(mtContainer)
        rootNode.addChildNode(mtContainer)
    }

    // MARK: - Canopy shadow patches on ground
    private func buildCanopyShadows() {
        guard mode == .race else { return } // open world gets shadows from tree nodes
        var rng: UInt64 = 0x12345678
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(1 << 31)
        }
        let shadowMat = SCNMaterial()
        shadowMat.diffuse.contents = UIColor(red: 0.02, green: 0.06, blue: 0.02, alpha: 1)
        shadowMat.lightingModel = .constant; shadowMat.transparency = 0.22; shadowMat.writesToDepthBuffer = false
        var z: Float = 60
        while z < trackLength {
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

    /// Detail texture for multiply-blending on open world ground.
    /// Kept bright and even — no dark patches. Grass blades only.
    private func makeGrassDetailTex() -> UIImage {
        let sz: CGFloat = 512
        UIGraphicsBeginImageContextWithOptions(CGSize(width: sz, height: sz), true, 1)
        let ctx = UIGraphicsGetCurrentContext()!
        // Bright even base — multiply preserves biome colors cleanly
        ctx.setFillColor(UIColor(red: 0.78, green: 0.92, blue: 0.70, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: sz, height: sz))
        var rng: UInt64 = 0xfade9876cafe5432
        func nr() -> CGFloat {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(rng >> 33) / CGFloat(1 << 31)
        }
        // Subtle micro-variation — small bright/slightly-darker spots, no dirt
        for _ in 0..<300 {
            let x = nr() * sz; let y = nr() * sz
            let w = nr() * 2.5 + 0.5; let h = nr() * 2.0 + 0.5
            let v = 0.72 + nr() * 0.22  // range 0.72–0.94, never very dark
            ctx.setFillColor(UIColor(red: v * 0.90, green: v, blue: v * 0.82, alpha: 0.3).cgColor)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        // Dense grass blade strokes — all green tones, no dark outliers
        for _ in 0..<1200 {
            let x = nr() * sz; let y = nr() * sz
            let len = nr() * 10 + 2
            let ang = nr() * .pi - .pi * 0.5
            let t = nr()
            let (r, g, b): (CGFloat, CGFloat, CGFloat)
            if t < 0.35 { (r,g,b) = (0.60, 0.82, 0.45) }      // mid green blade
            else if t < 0.65 { (r,g,b) = (0.70, 0.92, 0.52) }  // bright blade
            else { (r,g,b) = (0.80, 0.98, 0.60) }               // highlight blade
            ctx.setLineWidth(nr() * 0.6 + 0.4)
            ctx.setStrokeColor(UIColor(red: r, green: g, blue: b, alpha: nr() * 0.4 + 0.4).cgColor)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + cos(ang) * len, y: y + sin(ang) * len))
            ctx.strokePath()
        }
        let img = UIGraphicsGetImageFromCurrentImageContext()!; UIGraphicsEndImageContext(); return img
    }

    // MARK: - Open World Ground & Sea

    private func buildOpenWorldGround() {
        let texSize = quality == .low ? 2048 : 4096
        let worldSize: Float = 1600
        let img = makeOpenWorldTex(size: texSize, worldSize: worldSize)

        // Build terrain mesh with height variation
        let gridRes = quality == .low ? 120 : quality == .medium ? 180 : 240
        let half = worldSize * 0.5
        let step = worldSize / Float(gridRes)

        var verts = [SCNVector3](); verts.reserveCapacity((gridRes + 1) * (gridRes + 1))
        var normals = [SCNVector3](); normals.reserveCapacity(verts.capacity)
        var uvs = [CGPoint](); uvs.reserveCapacity(verts.capacity)
        var indices = [Int32](); indices.reserveCapacity(gridRes * gridRes * 6)

        for iz in 0...gridRes {
            for ix in 0...gridRes {
                let wx = Float(ix) * step - half
                let wz = Float(iz) * step - half
                let y = terrainHeight(wx, wz) - 0.05
                verts.append(SCNVector3(wx, y, wz))

                // UV maps to texture
                uvs.append(CGPoint(x: CGFloat(ix) / CGFloat(gridRes),
                                   y: CGFloat(iz) / CGFloat(gridRes)))

                // Compute normal from height gradient
                let dx = terrainHeight(wx + 1, wz) - terrainHeight(wx - 1, wz)
                let dz = terrainHeight(wx, wz + 1) - terrainHeight(wx, wz - 1)
                let nx = -dx; let nz = -dz; let ny: Float = 2.0
                let len = sqrtf(nx * nx + ny * ny + nz * nz)
                normals.append(SCNVector3(nx / len, ny / len, nz / len))
            }
        }

        let cols = Int32(gridRes + 1)
        for iz in 0..<gridRes {
            for ix in 0..<gridRes {
                let tl = Int32(iz) * cols + Int32(ix)
                let tr = tl + 1
                let bl = tl + cols
                let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        let vertSrc  = SCNGeometrySource(vertices: verts)
        let normSrc  = SCNGeometrySource(normals: normals)
        let uvSrc    = SCNGeometrySource(textureCoordinates: uvs)
        let idxData  = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element  = SCNGeometryElement(data: idxData, primitiveType: .triangles,
                                          primitiveCount: indices.count / 3,
                                          bytesPerIndex: MemoryLayout<Int32>.size)
        let geo = SCNGeometry(sources: [vertSrc, normSrc, uvSrc], elements: [element])

        let mat = SCNMaterial()
        mat.diffuse.contents = img
        mat.diffuse.wrapS = .clampToBorder; mat.diffuse.wrapT = .clampToBorder
        mat.diffuse.intensity = 0.8  // prevent bloom glow on ground
        mat.lightingModel = .lambert; mat.isDoubleSided = false
        // Tiled grass detail overlay — tiles for close-up crispness
        let detailTex = makeGrassDetailTex()
        mat.multiply.contents = detailTex
        mat.multiply.wrapS = .repeat; mat.multiply.wrapT = .repeat
        mat.multiply.intensity = 1.0
        // Tile every ~8 world-meters: worldSize/8 = 200 tiles across
        let tileScale = Float(worldSize) / 8.0
        mat.multiply.contentsTransform = SCNMatrix4MakeScale(tileScale, tileScale, 1)
        geo.firstMaterial = mat

        groundNode = SCNNode(geometry: geo)
        groundNode.position = SCNVector3(0, 0, 0)
        rootNode.addChildNode(groundNode)
    }

    private func makeOpenWorldTex(size: Int, worldSize: Float) -> UIImage {
        let sz = CGFloat(size)
        UIGraphicsBeginImageContextWithOptions(CGSize(width: sz, height: sz), true, 1)
        let ctx = UIGraphicsGetCurrentContext()!

        // Fill with water color as base
        ctx.setFillColor(UIColor(red: 0.12, green: 0.32, blue: 0.52, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: sz, height: sz))

        var rng: UInt64 = 0xdeadbeefcafe1337
        func nr() -> CGFloat {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(rng >> 33) / CGFloat(1 << 31)
        }

        let half = worldSize * 0.5
        for py in 0..<size {
            for px in 0..<size {
                let wx = Float(px) / Float(size) * worldSize - half
                let wz = Float(py) / Float(size) * worldSize - half
                let dist = sqrtf(wx * wx + wz * wz)
                guard dist < islandRadius + 10 else { continue }

                let biome = biomeAt(x: wx, z: wz)
                let noise = nr() * 0.08 // micro variation

                let (r, g, b): (CGFloat, CGFloat, CGFloat)
                switch biome {
                case .forest:
                    // Match race-mode ground palette
                    let t = nr()
                    if t < 0.22 { (r,g,b) = (0.09 + noise, 0.20 + noise, 0.04 + noise) }      // dark shadow
                    else if t < 0.48 { (r,g,b) = (0.20 + noise, 0.46 + noise, 0.10 + noise) }  // bright grass
                    else if t < 0.64 { (r,g,b) = (0.15 + noise, 0.10 + noise, 0.04 + noise) }  // dark soil
                    else if t < 0.80 { (r,g,b) = (0.14 + noise, 0.32 + noise, 0.08 + noise) }  // base earthy green
                    else { (r,g,b) = (0.24 + noise, 0.52 + noise, 0.14 + noise) }               // vivid highlight
                case .grassyPlain:
                    // Slightly brighter variant of the race-mode palette
                    let t = nr()
                    if t < 0.3 { (r,g,b) = (0.20 + noise, 0.46 + noise, 0.10 + noise) }       // bright grass
                    else if t < 0.6 { (r,g,b) = (0.24 + noise, 0.52 + noise, 0.14 + noise) }   // vivid highlight
                    else { (r,g,b) = (0.14 + noise, 0.32 + noise, 0.08 + noise) }               // earthy green
                case .sand:
                    let t = nr()
                    if t < 0.5 { (r,g,b) = (0.52 + noise, 0.45 + noise, 0.28 + noise) }
                    else { (r,g,b) = (0.48 + noise, 0.42 + noise, 0.26 + noise) }
                case .beach:
                    let edgeFade = CGFloat(max(0, (dist - (islandRadius - 40)) / 40))
                    (r,g,b) = (0.58 + noise - edgeFade * 0.12,
                               0.52 + noise - edgeFade * 0.10,
                               0.36 + noise - edgeFade * 0.04)
                }

                // Soft circular edge blend to water
                if dist > islandRadius - 15 {
                    let blend = CGFloat(min(1, (dist - (islandRadius - 15)) / 15))
                    let wr: CGFloat = 0.12, wg: CGFloat = 0.32, wb: CGFloat = 0.52
                    let fr = r + (wr - r) * blend
                    let fg = g + (wg - g) * blend
                    let fb = b + (wb - b) * blend
                    ctx.setFillColor(UIColor(red: fr, green: fg, blue: fb, alpha: 1).cgColor)
                } else {
                    ctx.setFillColor(UIColor(red: r, green: g, blue: b, alpha: 1).cgColor)
                }
                ctx.fill(CGRect(x: CGFloat(px), y: CGFloat(py), width: 1, height: 1))
            }
        }

        // Grass blade strokes — matching race-mode detail
        ctx.setLineWidth(0.7)
        let bladeCount = size * size / 80  // scale with resolution
        for _ in 0..<bladeCount {
            let px = nr() * sz; let py = nr() * sz
            let wx = Float(px) / Float(sz) * worldSize - half
            let wz = Float(py) / Float(sz) * worldSize - half
            let dist = sqrtf(wx * wx + wz * wz)
            guard dist < islandRadius - 20 else { continue }
            let biome = biomeAt(x: wx, z: wz)
            guard biome == .forest || biome == .grassyPlain else { continue }
            let len = nr() * 6 + 1.5
            let ang = nr() * .pi - .pi * 0.5
            let bright = nr() * 0.18
            ctx.setStrokeColor(UIColor(red: 0.15 + bright, green: 0.36 + bright * 2.6,
                                       blue: 0.05 + bright * 0.4, alpha: nr() * 0.5 + 0.4).cgColor)
            ctx.move(to: CGPoint(x: px, y: py))
            ctx.addLine(to: CGPoint(x: px + cos(ang) * len, y: py + sin(ang) * len))
            ctx.strokePath()
        }

        // Wildflower patches — subtle color dots in grassy plains
        for _ in 0..<(size * size / 600) {
            let px = nr() * sz; let py = nr() * sz
            let wx = Float(px) / Float(sz) * worldSize - half
            let wz = Float(py) / Float(sz) * worldSize - half
            let dist = sqrtf(wx * wx + wz * wz)
            guard dist < islandRadius - 40, biomeAt(x: wx, z: wz) == .grassyPlain else { continue }
            let flowerType = nr()
            let (fr, fg, fb): (CGFloat, CGFloat, CGFloat)
            if flowerType < 0.3 { (fr,fg,fb) = (0.72, 0.65, 0.18) }       // yellow
            else if flowerType < 0.55 { (fr,fg,fb) = (0.70, 0.30, 0.55) }  // purple
            else if flowerType < 0.75 { (fr,fg,fb) = (0.80, 0.80, 0.75) }  // white
            else { (fr,fg,fb) = (0.65, 0.20, 0.18) }                        // red
            ctx.setFillColor(UIColor(red: fr, green: fg, blue: fb, alpha: 0.55 + nr() * 0.3).cgColor)
            let dotR = nr() * 1.2 + 0.4
            ctx.fillEllipse(in: CGRect(x: px - dotR, y: py - dotR, width: dotR * 2, height: dotR * 2))
        }

        // Dirt path traces — winding trails between biomes
        var pathRng: UInt64 = 0xda7e1234
        func pr() -> Float {
            pathRng = pathRng &* 6364136223846793005 &+ 1442695040888963407
            return Float(pathRng >> 33) / Float(1 << 31)
        }
        let pathCount = 5
        for _ in 0..<pathCount {
            var px = pr() * Float(size); var py = pr() * Float(size)
            let angle = pr() * .pi * 2
            var dir = angle
            ctx.setStrokeColor(UIColor(red: 0.26, green: 0.17, blue: 0.07, alpha: 0.25).cgColor)
            ctx.setLineWidth(CGFloat(2.0 + pr() * 2.5))
            ctx.move(to: CGPoint(x: CGFloat(px), y: CGFloat(py)))
            for _ in 0..<120 {
                dir += (pr() - 0.5) * 0.4
                let step: Float = 8 + pr() * 6
                px += cos(dir) * step; py += sin(dir) * step
                let wx = px / Float(size) * worldSize - half
                let wz = py / Float(size) * worldSize - half
                let dist = sqrtf(wx * wx + wz * wz)
                if dist > islandRadius - 50 { break }
                ctx.addLine(to: CGPoint(x: CGFloat(px), y: CGFloat(py)))
            }
            ctx.strokePath()
        }

        let img = UIGraphicsGetImageFromCurrentImageContext()!; UIGraphicsEndImageContext(); return img
    }

    private let waterLevel: Float = -0.3

    private func makeWaterMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.05, green: 0.22, blue: 0.38, alpha: 0.78)
        mat.specular.contents = UIColor(red: 0.90, green: 0.95, blue: 1.00, alpha: 1)
        mat.specular.intensity = 0.6
        mat.reflective.contents = UIColor(red: 0.25, green: 0.45, blue: 0.65, alpha: 1)
        mat.reflective.intensity = 0.3
        mat.transparent.contents = UIColor(white: 1, alpha: 0.78)
        mat.lightingModel = .blinn
        mat.isDoubleSided = false
        mat.shininess = 80
        mat.fresnelExponent = 2.5
        mat.writesToDepthBuffer = true
        // Animated UV scroll for wave ripple effect
        let scroll = CABasicAnimation(keyPath: "contentsTransform")
        scroll.fromValue = NSValue(scnMatrix4: SCNMatrix4MakeScale(8, 8, 1))
        scroll.toValue = NSValue(scnMatrix4: SCNMatrix4Mult(
            SCNMatrix4MakeTranslation(0.12, 0.08, 0),
            SCNMatrix4MakeScale(8, 8, 1)))
        scroll.duration = 4.0; scroll.repeatCount = .infinity
        scroll.autoreverses = true
        mat.diffuse.addAnimation(scroll, forKey: "wave")
        return mat
    }

    private func buildSeaPlane() {
        let sea = SCNPlane(width: 5000, height: 5000)
        sea.firstMaterial = makeWaterMaterial()
        let seaNode = SCNNode(geometry: sea)
        seaNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        seaNode.position = SCNVector3(0, waterLevel, 0)
        seaNode.renderingOrder = -1
        rootNode.addChildNode(seaNode)
        // Gentle wave oscillation
        seaNode.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.12, z: 0, duration: 2.5),
            .moveBy(x: 0, y: -0.12, z: 0, duration: 2.5)
        ])))
    }

    /// Spawn water pools along the race track as clearings
    private func buildForestPools() {
        guard mode == .race else { return }

        var rng: UInt64 = 0x9001cafe
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(1 << 31)
        }

        let poolMat = makeWaterMaterial()
        poolMat.diffuse.contents = UIColor(red: 0.06, green: 0.20, blue: 0.32, alpha: 0.72)

        var z: Float = 300
        while z < trackLength - 200 {
            if rnd() < 0.4 {
                let tc = trackCenterX(z)
                let side: Float = rnd() > 0.5 ? 1 : -1
                let offX = 25 + rnd() * 60  // offset from track center into forest
                let poolW = CGFloat(15 + rnd() * 30)
                let poolH = CGFloat(10 + rnd() * 20)

                let pool = SCNPlane(width: poolW, height: poolH)
                pool.firstMaterial = poolMat; pool.cornerRadius = min(poolW, poolH) * 0.4
                let n = SCNNode(geometry: pool)
                n.eulerAngles.x = -.pi / 2
                n.position = SCNVector3(tc + side * offX, -0.02, z)
                n.renderingOrder = -1; n.castsShadow = false
                rootNode.addChildNode(n)
            }
            z += 180 + rnd() * 250
        }
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

    // MARK: - Biomes (open world)

    enum Biome { case forest, grassyPlain, sand, beach }

    /// Deterministic hash for biome noise — same family as tree ch()
    private func biomeHash(_ ix: Int, _ iz: Int) -> Float {
        var h = UInt64(bitPattern: Int64(ix &* 374761393 &+ iz &* 668265263 &+ 987654321))
        h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9
        h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
        h = h ^ (h >> 31)
        return Float(h & 0x7fffffff) / Float(0x7fffffff)
    }

    /// Bilinearly interpolated noise at world position — coarse 120m cells
    private func biomeNoise(_ x: Float, _ z: Float) -> Float {
        let cell: Float = 120
        let fx = x / cell; let fz = z / cell
        let ix = Int(floorf(fx)); let iz = Int(floorf(fz))
        let tx = fx - Float(ix); let tz = fz - Float(iz)
        let v00 = biomeHash(ix, iz)
        let v10 = biomeHash(ix + 1, iz)
        let v01 = biomeHash(ix, iz + 1)
        let v11 = biomeHash(ix + 1, iz + 1)
        let a = v00 + (v10 - v00) * tx
        let b = v01 + (v11 - v01) * tx
        return a + (b - a) * tz
    }

    func biomeAt(x: Float, z: Float) -> Biome {
        let dist = sqrtf(x * x + z * z)
        if dist > islandRadius - 40 { return .beach }

        let n = biomeNoise(x, z)
        // Radial bias: center favours forest, edges favour sand
        let radialBias = dist / islandRadius       // 0 at center, ~0.95 at edge
        let adjusted = n + radialBias * 0.25 - 0.12 // shift toward sand at edges

        if adjusted < 0.30 { return .forest }
        if adjusted < 0.62 { return .grassyPlain }
        return .sand
    }

    // MARK: - Terrain height (open world only)

    /// Smooth terrain height using layered noise — gentle rolling hills
    func terrainHeight(_ x: Float, _ z: Float) -> Float {
        guard mode == .openWorld else { return 0 }
        let dist = sqrtf(x * x + z * z)
        // Flatten near center (spawn area) and at beach edges
        let centerFade = min(1, dist / 120)                     // flat within 120m of center
        let edgeFade = max(0, 1 - max(0, dist - (islandRadius - 100)) / 100) // flat at beach

        // Two octaves of smooth hills
        let h1 = sinf(x * 0.008 + 1.3) * cosf(z * 0.010 + 0.7) * 12.0
        let h2 = sinf(x * 0.022 + 5.1) * cosf(z * 0.018 + 3.2) * 4.0
        let h3 = sinf(x * 0.005 + z * 0.006) * 8.0             // broad undulation

        return (h1 + h2 + h3) * centerFade * edgeFade
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
            (0.62, 0.58, 0.52),  // 6: birch (white bark — toned down to avoid yellow glow)
            (0.28, 0.17, 0.08),  // 7: willow
            (0.32, 0.16, 0.06),  // 8: twisted oak
            (0.34, 0.22, 0.10),  // 9: sapling (destructible)
            (0.58, 0.55, 0.50),  // 10: young birch (destructible)
        ]
        for i in 0..<trunkCols.count {
            let h = treeHeights[i]
            let cyl = SCNCylinder(radius: CGFloat(trunkRadii[i]), height: CGFloat(h)); cyl.radialSegmentCount = 6; cyl.heightSegmentCount = 1
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: trunkCols[i].0, green: trunkCols[i].1, blue: trunkCols[i].2, alpha: 1)
            m.lightingModel = .lambert; cyl.firstMaterial = m; treeGeoms.append(cyl)
            // Root flare — a small cone that widens at the base for a natural look
            let flareH: CGFloat = CGFloat(h * 0.12)  // bottom 12% of tree
            let flareR = CGFloat(trunkRadii[i]) * 2.2 // wider than trunk
            let flare = SCNCone(topRadius: CGFloat(trunkRadii[i]), bottomRadius: flareR, height: flareH)
            flare.radialSegmentCount = 6; flare.firstMaterial = m
            rootFlareGeoms.append(flare)
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

    // MARK: - Open World Vegetation

    private var boulderGeoms: [SCNGeometry] = []

    private func buildBoulderGeoms() {
        let sizes: [(r: CGFloat, sx: Float, sy: Float, sz: Float)] = [
            (1.5, 1.2, 0.55, 1.0),
            (1.0, 1.0, 0.65, 1.1),
            (2.0, 1.3, 0.50, 0.9),
        ]
        for s in sizes {
            let sphere = SCNSphere(radius: s.r)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor(red: 0.48, green: 0.42, blue: 0.36, alpha: 1)
            mat.lightingModel = .lambert
            sphere.firstMaterial = mat; sphere.segmentCount = 12
            boulderGeoms.append(sphere)
        }
    }

    private let boulderScales: [(Float, Float, Float)] = [
        (1.2, 0.55, 1.0), (1.0, 0.65, 1.1), (1.3, 0.50, 0.9)
    ]

    private func buildOpenWorldVegetation() {
        let geos = treeGeoms; let cGeos = canopyGeoms; let bGeos = bushGeoms
        let fGeos = fernGeoms; let rfGeos = rootFlareGeoms
        let gtGeo = giantTrunkGeo; let gcGeo = giantCanopyGeo
        let heights = treeHeights; let cRadii = canopyRadii; let tRadii = trunkRadii
        let crashSpeeds = treeCrashSpeed; let smashPenalties = treeSmashPenalty
        let treeShadows = quality.treesCastShadows
        let bushesOn = quality.bushesEnabled; let bushScale = quality.bushDensityScale
        let boulders = boulderGeoms; let bScales = boulderScales
        let solidTypeCount = 9
        let saplingTypes = [9, 10]
        let radius = islandRadius

        treeQueue.async { [weak self] in
            guard let self = self else { return }
            let newRoot = SCNNode()
            var positions = [TreeEntry]()

            func ch(_ ix: Int, _ iz: Int, _ slot: Int) -> UInt64 {
                var h = UInt64(bitPattern: Int64(ix &* 374761393 &+ iz &* 668265263 &+ slot &* 1234567891))
                h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9; h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
                return h ^ (h >> 31)
            }
            func cr(_ ix: Int, _ iz: Int, _ slot: Int) -> Float {
                Float(ch(ix, iz, slot) & 0x7fffffff) / Float(0x7fffffff)
            }

            let cell: Float = 10
            let gridMin = Int(floorf(-radius / cell))
            let gridMax = Int(ceilf(radius / cell))

            for iz in gridMin...gridMax {
                for ix in gridMin...gridMax {
                    let baseX = Float(ix) * cell
                    let baseZ = Float(iz) * cell
                    let dist = sqrtf(baseX * baseX + baseZ * baseZ)
                    guard dist < radius - 30 else { continue } // skip beach/sea

                    let biome = self.biomeAt(x: baseX, z: baseZ)
                    let jx = (cr(ix, iz, 0) - 0.5) * cell * 0.7
                    let jz = (cr(ix, iz, 1) - 0.5) * cell * 0.7
                    let tx = baseX + jx; let tz = baseZ + jz
                    let gy = self.terrainHeight(tx, tz)  // ground offset
                    // Skip vegetation below water level
                    guard gy >= self.waterLevel else { continue }
                    let roll = cr(ix, iz, 2)

                    switch biome {
                    case .forest:
                        // Dense trees — similar to race mode
                        if roll < 0.38 {
                            let isSapling = cr(ix, iz, 5) < 0.15
                            let gIdx: Int
                            if isSapling {
                                gIdx = saplingTypes[Int(cr(ix, iz, 6) * Float(saplingTypes.count - 1) + 0.5) % saplingTypes.count]
                            } else {
                                gIdx = Int(cr(ix, iz, 3) * Float(solidTypeCount - 1) + 0.5) % solidTypeCount
                            }
                            let hScale = cr(ix, iz, 4) * 0.55 + 0.72
                            let h = heights[gIdx] * hScale

                            let treeNode = SCNNode()
                            let trunk = SCNNode(geometry: geos[gIdx])
                            trunk.position = SCNVector3(tx, gy + h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            if !treeShadows { trunk.castsShadow = false }
                            treeNode.addChildNode(trunk)
                            // Root flare at base
                            if gIdx < rfGeos.count {
                                let flare = SCNNode(geometry: rfGeos[gIdx])
                                let flareH = heights[gIdx] * 0.12 * hScale
                                flare.position = SCNVector3(tx, gy + flareH * 0.5, tz)
                                flare.scale = SCNVector3(1, hScale, 1)
                                flare.castsShadow = false; treeNode.addChildNode(flare)
                            }
                            let canopy = SCNNode(geometry: cGeos[gIdx])
                            if gIdx >= 3 && gIdx <= 4 {
                                canopy.position = SCNVector3(tx, gy + h * 0.55, tz)
                            } else if gIdx == 5 {
                                canopy.position = SCNVector3(tx, gy + h * 0.85, tz)
                                canopy.scale = SCNVector3(1.2, 0.6, 1.2)
                            } else if gIdx == 7 {
                                canopy.position = SCNVector3(tx, gy + h * 0.65, tz)
                                canopy.scale = SCNVector3(1.4, 0.55, 1.4)
                            } else if gIdx == 8 {
                                canopy.position = SCNVector3(tx + 1.0, gy + h * 0.78, tz)
                                canopy.scale = SCNVector3(1.1, 0.65, 0.9)
                            } else {
                                canopy.position = SCNVector3(tx, gy + h - cRadii[gIdx] * 0.1, tz)
                                canopy.scale = SCNVector3(1.0, 0.72, 1.0)
                            }
                            if !treeShadows { canopy.castsShadow = false }
                            treeNode.addChildNode(canopy)
                            newRoot.addChildNode(treeNode)
                            positions.append(TreeEntry(x: tx, z: tz, r: tRadii[gIdx] * 1.2,
                                                       crashSpeed: crashSpeeds[gIdx], smashPenalty: smashPenalties[gIdx], node: treeNode))
                        }
                        // Bushes in forest
                        if bushesOn && cr(ix, iz, 7) < 0.35 * bushScale {
                            let bi = Int(cr(ix, iz, 8) * 3.0 + 0.5) % bGeos.count
                            let bush = SCNNode(geometry: bGeos[bi])
                            bush.position = SCNVector3(tx + 2, gy + 0.3, tz + 1.5)
                            bush.castsShadow = false; newRoot.addChildNode(bush)
                        }
                        // Ferns in forest
                        if cr(ix, iz, 9) < 0.25 {
                            let fi = Int(cr(ix, iz, 10) * 2.0 + 0.5) % max(1, fGeos.count)
                            if fi < fGeos.count {
                                let fern = SCNNode(geometry: fGeos[fi])
                                fern.position = SCNVector3(tx - 1.5, gy + 0.05, tz - 2)
                                fern.castsShadow = false; newRoot.addChildNode(fern)
                            }
                        }
                        // Mossy boulders in forest — scattered ground detail
                        if !boulders.isEmpty && cr(ix, iz, 14) < 0.06 {
                            let bi = Int(cr(ix, iz, 15) * Float(boulders.count - 1) + 0.5) % boulders.count
                            let boulder = SCNNode(geometry: boulders[bi])
                            let s = bScales[bi]
                            boulder.scale = SCNVector3(s.0 * 0.7, s.1 * 0.7, s.2 * 0.7)
                            let bR = Float(boulders[bi] is SCNSphere ? (boulders[bi] as! SCNSphere).radius : 1.5)
                            boulder.position = SCNVector3(tx - 3, gy + bR * s.1 * 0.7, tz + 2)
                            boulder.eulerAngles.y = cr(ix, iz, 16) * .pi * 2
                            boulder.castsShadow = false; newRoot.addChildNode(boulder)
                        }
                        // Giant trees — rare landmarks
                        if let gt = gtGeo, let gc = gcGeo, cr(ix, iz, 11) < 0.008 {
                            let giantH: Float = 85 * (cr(ix, iz, 12) * 0.3 + 0.85)
                            let trunk = SCNNode(geometry: gt)
                            trunk.position = SCNVector3(tx, gy + giantH * 0.5, tz)
                            trunk.scale = SCNVector3(1, giantH / 85, 1)
                            trunk.castsShadow = false; newRoot.addChildNode(trunk)
                            let can = SCNNode(geometry: gc)
                            can.position = SCNVector3(tx, gy + giantH * 0.78, tz)
                            can.castsShadow = false; newRoot.addChildNode(can)
                        }

                    case .grassyPlain:
                        // Very sparse — only birch and small broadleaf
                        if roll < 0.03 {
                            let gIdx = cr(ix, iz, 3) < 0.5 ? 0 : 6
                            let hScale = cr(ix, iz, 4) * 0.55 + 0.72
                            let h = heights[gIdx] * hScale
                            let treeNode = SCNNode()
                            let trunk = SCNNode(geometry: geos[gIdx])
                            trunk.position = SCNVector3(tx, gy + h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            if !treeShadows { trunk.castsShadow = false }
                            treeNode.addChildNode(trunk)
                            // Root flare at base
                            if gIdx < rfGeos.count {
                                let flare = SCNNode(geometry: rfGeos[gIdx])
                                let flareH = heights[gIdx] * 0.12 * hScale
                                flare.position = SCNVector3(tx, gy + flareH * 0.5, tz)
                                flare.scale = SCNVector3(1, hScale, 1)
                                flare.castsShadow = false; treeNode.addChildNode(flare)
                            }
                            let canopy = SCNNode(geometry: cGeos[gIdx])
                            canopy.position = SCNVector3(tx, gy + h - cRadii[gIdx] * 0.1, tz)
                            canopy.scale = SCNVector3(1.0, 0.72, 1.0)
                            if !treeShadows { canopy.castsShadow = false }
                            treeNode.addChildNode(canopy)
                            newRoot.addChildNode(treeNode)
                            positions.append(TreeEntry(x: tx, z: tz, r: tRadii[gIdx] * 1.2,
                                                       crashSpeed: crashSpeeds[gIdx], smashPenalty: smashPenalties[gIdx], node: treeNode))
                        }
                        // Grass-like ferns scattered
                        if cr(ix, iz, 9) < 0.12, !fGeos.isEmpty {
                            let fern = SCNNode(geometry: fGeos[0])
                            fern.position = SCNVector3(tx, gy + 0.05, tz)
                            fern.castsShadow = false; newRoot.addChildNode(fern)
                        }

                    case .sand:
                        if roll < 0.02 {
                            let gIdx = cr(ix, iz, 3) < 0.4 ? 5 : saplingTypes[Int(cr(ix, iz, 6)) % saplingTypes.count]
                            let hScale = cr(ix, iz, 4) * 0.55 + 0.72
                            let h = heights[gIdx] * hScale
                            let treeNode = SCNNode()
                            let trunk = SCNNode(geometry: geos[gIdx])
                            trunk.position = SCNVector3(tx, gy + h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            trunk.castsShadow = false; treeNode.addChildNode(trunk)
                            // Root flare at base
                            if gIdx < rfGeos.count {
                                let flare = SCNNode(geometry: rfGeos[gIdx])
                                let flareH = heights[gIdx] * 0.12 * hScale
                                flare.position = SCNVector3(tx, gy + flareH * 0.5, tz)
                                flare.scale = SCNVector3(1, hScale, 1)
                                flare.castsShadow = false; treeNode.addChildNode(flare)
                            }
                            let canopy = SCNNode(geometry: cGeos[gIdx])
                            canopy.position = SCNVector3(tx, gy + h * 0.85, tz)
                            canopy.scale = SCNVector3(1.2, 0.6, 1.2)
                            canopy.castsShadow = false; treeNode.addChildNode(canopy)
                            newRoot.addChildNode(treeNode)
                            positions.append(TreeEntry(x: tx, z: tz, r: tRadii[gIdx] * 1.2,
                                                       crashSpeed: crashSpeeds[gIdx], smashPenalty: smashPenalties[gIdx], node: treeNode))
                        }
                        // Boulders
                        if !boulders.isEmpty && cr(ix, iz, 7) < 0.04 {
                            let bi = Int(cr(ix, iz, 8) * Float(boulders.count - 1) + 0.5) % boulders.count
                            let boulder = SCNNode(geometry: boulders[bi])
                            let s = bScales[bi]
                            boulder.scale = SCNVector3(s.0, s.1, s.2)
                            let bR = Float(boulders[bi] is SCNSphere ? (boulders[bi] as! SCNSphere).radius : 1.5)
                            boulder.position = SCNVector3(tx, gy + bR * s.1, tz)
                            boulder.eulerAngles.y = cr(ix, iz, 13) * .pi * 2
                            boulder.castsShadow = false; newRoot.addChildNode(boulder)
                        }

                    case .beach:
                        break // nothing on beach
                    }
                }
            }

            // Build spatial grid
            var grid = [Int64: [TreeEntry]]()
            let gridCell: Float = 16
            for p in positions {
                let gx = Int(floorf(p.x / gridCell))
                let gz = Int(floorf(p.z / gridCell))
                let key = Int64(Int32(gx)) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: Int32(gz))))
                grid[key, default: []].append(p)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.treeRoot.removeFromParentNode()
                self.treeRoot = newRoot
                self.rootNode.addChildNode(newRoot)
                self.treePositions = positions
                self.treeGrid = grid
                self.isLevelReady = true
            }
        }
    }

    private func buildAllTrees() {
        streamTrees(zStart: -40, zEnd: trackLength + 30)
    }

    private func streamTrees(zStart: Float, zEnd: Float) {
        let geos = treeGeoms; let cGeos = canopyGeoms; let bGeos = bushGeoms
        let fGeos = fernGeoms; let rfGeos = rootFlareGeoms
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
                            // Root flare at base
                            if gIdx < rfGeos.count {
                                let flare = SCNNode(geometry: rfGeos[gIdx])
                                let flareH = heights[gIdx] * 0.12 * hScale
                                flare.position = SCNVector3(tx, flareH * 0.5, tz)
                                flare.scale = SCNVector3(1, hScale, 1)
                                flare.castsShadow = false; treeNode.addChildNode(flare)
                            }
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

        // Water spray — activated when flying over water
        let spray = SCNParticleSystem()
        spray.birthRate = 0  // off by default
        spray.emissionDuration = -1; spray.particleLifeSpan = 0.8; spray.particleLifeSpanVariation = 0.3
        spray.particleSize = 0.15; spray.particleSizeVariation = 0.10
        spray.spreadingAngle = 45; spray.particleVelocity = 6; spray.particleVelocityVariation = 3
        spray.emittingDirection = SCNVector3(0, 1, 0)  // spray upward
        spray.particleColor = UIColor(red: 0.70, green: 0.85, blue: 0.95, alpha: 0.45)
        spray.particleColorVariation = SCNVector4(0.05, 0.05, 0.05, 0.15)
        spray.blendMode = .alpha; spray.isLightingEnabled = false
        spray.acceleration = SCNVector3(0, -8, 0)  // falls back down
        waterSpray = spray
        let sprayNode = SCNNode(); sprayNode.position = SCNVector3(0, -0.5, 0)
        sprayNode.addParticleSystem(spray)
        waterSprayNode = sprayNode
        speederPivot.addChildNode(sprayNode)

        speederPivot.addChildNode(speederBody)
        speederPivot.position = SCNVector3(worldX, 5, worldZ)
        rootNode.addChildNode(speederPivot)
    }

    // MARK: - Camera
    private func buildCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 88; cam.motionBlurIntensity = 0; cam.zNear = 0.10
        cam.zFar = mode == .openWorld ? 4000 : 800
        cam.wantsHDR = quality.wantsHDR
        cam.bloomIntensity = quality.bloomIntensity; cam.bloomThreshold = quality.bloomThreshold; cam.bloomBlurRadius = quality.bloomBlurRadius
        cam.contrast = quality.contrast; cam.saturation = quality.saturation
        cam.vignettingIntensity = 0.35; cam.vignettingPower = 1.2
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
    func update(dt: Float, steer: Float, throttling: Bool, braking: Bool, lift: Float = 0) {
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
        case .waiting:
            if mode == .openWorld {
                if forwardSpeed > 1 { raceState = .racing }
            } else {
                if worldZ > 5 { raceState = .racing }
            }
        case .racing:
            raceTime += dt
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
                forwardSpeed = max(-20, forwardSpeed - 60*dt)            // brake then reverse
            } else if throttling {
                forwardSpeed = min(forwardSpeed + 38*dt, maxNormalSpeed)
            } else if forwardSpeed > 0 {
                forwardSpeed = max(0, forwardSpeed - 12*dt)              // coast to stop
            } else {
                forwardSpeed = min(0, forwardSpeed + 12*dt)              // coast to stop from reverse
            }
        }

        // Steering — allow full rotation even at standstill
        turnRate += (steer * maxTurnRate - turnRate) * min(1, dt * 5.5)
        heading  += turnRate * dt

        // Position
        worldX += sin(heading) * forwardSpeed * dt
        worldZ += cos(heading) * forwardSpeed * dt

        if mode == .openWorld {
            // Water zone — speeder can float but slows down
            let dist = sqrtf(worldX * worldX + worldZ * worldZ)
            let shoreStart = islandRadius - 30  // where water begins
            let hardLimit = islandRadius + 80    // max distance out to sea
            if dist > shoreStart {
                // Gradual drag on water — the further out, the stronger
                let waterDepth = (dist - shoreStart) / (hardLimit - shoreStart)
                forwardSpeed *= max(0.92, 1.0 - waterDepth * 0.06)
            }
            if dist > hardLimit {
                let scale = hardLimit / dist
                worldX *= scale; worldZ *= scale
                forwardSpeed *= 0.7; turnRate *= -0.2
            }
        } else {
            // Prevent going behind start
            if worldZ < -15 { worldZ = -15; forwardSpeed *= 0.5 }
            // Outer forest wall — soft bounce just inside the treeline edge
            let lateral = worldX - trackCenterX(worldZ)
            let forestEdge = difficulty.clearZone + 152.0
            if abs(lateral) > forestEdge {
                worldX = trackCenterX(worldZ) + (lateral > 0 ? forestEdge : -forestEdge)
                forwardSpeed *= 0.65; turnRate *= -0.3
            }
        }

        // Tree collision
        resolveTreeCollisions()
        resolveObstacleCollisions()

        // Hover physics — soft, floaty suspension with elastic bounce
        let terrainH = terrainHeight(worldX, worldZ)
        let groundH = max(terrainH, waterLevel)                 // float on water or terrain
        let bob1 = sin(timeAccum * 1.1 * .pi * 2) * 0.18
        let bob2 = sin(timeAccum * 1.8 * .pi * 2) * 0.08
        let bob3 = sin(timeAccum * 0.4 * .pi * 2) * 0.10       // slow sway
        let speedRat = min(abs(forwardSpeed) / maxNormalSpeed, 1.0)
        let bobScale = 0.5 + speedRat * 0.9
        let hoverTarget: Float = groundH + 1.35 + (bob1 + bob2 + bob3) * bobScale
        var accel: Float = -16.0
        accel += lift * 120.0                                   // strong lift — can reach treetop height
        let damping: Float = 5.0 + speedRat * 6.0              // softer suspension for flight feel
        let maxHover = groundH + 45.0                           // medium tree height (~42)
        if speederY < maxHover { accel += (hoverTarget - speederY) * 35.0 - velocityY * damping }
        velocityY += accel * dt; speederY += velocityY * dt
        let floorH = groundH + 0.4
        if speederY < floorH { speederY = floorH; velocityY = max(velocityY, 0) }
        if speederY > groundH + 44.0 { speederY = groundH + 44.0; velocityY = min(velocityY, 0) }

        // Speeder nodes
        speederPivot.position    = SCNVector3(worldX, speederY, worldZ)
        speederPivot.eulerAngles = SCNVector3(0, heading, 0)
        bankAngle  += (-(turnRate / maxTurnRate) * 1.05 - bankAngle)  * min(1, dt * 5.5)
        pitchAngle += (-velocityY * 0.045 - pitchAngle) * min(1, dt * 4.5)
        speederBody.eulerAngles = SCNVector3(pitchAngle, 0, bankAngle)

        // Water spray — activate when hovering over water
        if let spray = waterSpray {
            let overWater = terrainH < waterLevel && mode == .openWorld
            let spd = abs(forwardSpeed)
            let heightAboveWater = speederY - waterLevel
            if overWater && spd > 5 && heightAboveWater < 4.0 {
                // Spray intensity scales with speed and proximity to water
                let proximity = max(0, 1.0 - heightAboveWater / 4.0)
                let speedScale = min(1.0, spd / 50.0)
                spray.birthRate = CGFloat(proximity * speedScale) * 120
                spray.particleVelocity = CGFloat(3 + spd * 0.1)
            } else {
                spray.birthRate = 0
            }
        }

        updateCamera(dt: dt)
    }

    private func updateCamera(dt: Float) {
        let camDist: Float = 5.5
        camY += (speederY + 1.60 - camY) * min(1, dt * 4.5)
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
        let trackBank: Float = mode == .openWorld ? 0 : trackBankAngle(worldZ) * 0.85
        let bankTarget = (turnRate / maxTurnRate) * 0.82 + trackBank
        camBankAngle += (bankTarget - camBankAngle) * min(1, dt * 7)
        cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
                                              simd_quatf(angle: camBankAngle, axis: SIMD3<Float>(0, 0, 1)))

        // FOV — with boost kick
        boostFOVKick = max(0, boostFOVKick - Double(dt) * 12)
        let targetFOV = 88.0 + speedRatio * 36.0 + boostFOVKick
        currentFOV += (targetFOV - currentFOV) * Double(min(1, dt * 3.5))
        cameraNode.camera?.fieldOfView = currentFOV

        // Dynamic vignetting — subtle at rest, more at speed, eased during boost
        if let cam = cameraNode.camera {
            let baseVig: CGFloat = 0.25
            let speedVig = CGFloat(speedRatio) * 0.30
            let boostVig: CGFloat = isBoosting ? 0.15 : 0
            let targetVig = baseVig + speedVig + boostVig
            let curVig = cam.vignettingIntensity
            cam.vignettingIntensity = curVig + (targetVig - curVig) * CGFloat(min(1, dt * 4))
        }

        // Motion blur
        let targetBlur = speedRatio * 0.46
        let curBlur    = Double(cameraNode.camera?.motionBlurIntensity ?? 0)
        cameraNode.camera?.motionBlurIntensity = CGFloat(curBlur + (targetBlur - curBlur) * Double(min(1, dt*4)))

        // DOF
        if quality == .high, let cam = cameraNode.camera {
            cam.focusDistance = CGFloat(lookDist * 0.7)
        }

        // (streaming removed — open world builds all trees at init)

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

        // Dynamic fog color — shifts warmer in tight curves (race only)
        if mode == .race {
            let curveIntensity = curvature(worldZ)
            currentFogLerp += (curveIntensity - currentFogLerp) * min(1, dt * 2)
            fogColor = lerpColor(fogColorOpen, fogColorDense, currentFogLerp)
        }

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
