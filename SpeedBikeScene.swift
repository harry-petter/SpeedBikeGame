import SceneKit
import UIKit

final class SpeedBikeScene: SCNScene {

    // MARK: - Config
    let mode:        GameMode
    let difficulty:  Difficulty
    let quality:     GraphicsQuality
    let trackLength: Float
    let islandRadius: Float = 3200.0

    // MARK: - Race state
    enum RaceState { case waiting, racing, finished, crashed }
    private(set) var raceState: RaceState = .waiting
    private(set) var raceTime:  Float     = 0

    private(set) var isLevelReady: Bool = false
    func forceLevelReady() { isLevelReady = true }
    var onCrash: (() -> Void)?
    var onNearMiss: ((Float) -> Void)?       // closeness 0..1
    var onCheckpoint: ((Int, Float) -> Void)? // index, raceTime
    var distanceCovered: Float { max(0, worldZ) }
    var currentSpeed:    Float { forwardSpeed }
    var speedFraction:   Float { max(0, forwardSpeed) / effectiveMaxBoost }
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
    private var currentFOV:   Double = 95
    private var boostTimer:   Float  = 0
    private var boostEnergy:  Float  = 1.0   // 0→1, full at start
    private let boostDrainRate: Float = 0.40 // drain per second while boosting
    private let boostRechargeRate: Float = 0.12 // recharge per second when not boosting
    private var timeAccum:    Float  = 0

    private let maxNormalSpeed: Float = 60   // ~75% of boost
    private let maxBoostSpeed:  Float = 80
    // Open world gets much higher top speed — holding boost ramps up to 5x race boost
    private var owBoostSpeed: Float { 400 }
    private var owNormalSpeed: Float { 78 }
    private var effectiveMaxBoost: Float { mode == .openWorld ? owBoostSpeed : maxBoostSpeed }
    private var effectiveMaxNormal: Float { mode == .openWorld ? owNormalSpeed : maxNormalSpeed }
    private let maxTurnRate:    Float = 1.0

    // MARK: - Nodes
    private var speederPivot = SCNNode()
    private var speederBody  = SCNNode()
    private var sunNode      = SCNNode()
    private var treeRoot     = SCNNode()
    private var skyNodes:    [SCNNode] = []
    private var thrusterTrail: SCNParticleSystem?
    private var pollenSystem: SCNParticleSystem?
    private var surfaceSpray: SCNParticleSystem?
    private var surfaceSprayNode: SCNNode?
    private var exhaustBellMats: [SCNMaterial] = []
    private var exhaustCoreMats: [SCNMaterial] = []

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
        self.trackLength = mode == .race ? 6400 : 0
        super.init()
        buildScene()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build
    private func buildScene() {
        background.contents = UIColor(red: 0.45, green: 0.68, blue: 0.96, alpha: 1)
        fogColor = UIColor(red: 0.38, green: 0.58, blue: 0.44, alpha: 1)
        fogStartDistance = 160; fogEndDistance = 420
        lightingEnvironment.contents = UIColor(red: 0.40, green: 0.52, blue: 0.65, alpha: 1)
        lightingEnvironment.intensity = 1.5

        buildTreeGeoms(); buildBoulderGeoms(); addLighting(); addSky()

        if mode == .openWorld {
            fogColor = UIColor(red: 0.52, green: 0.66, blue: 0.84, alpha: 1)
            fogStartDistance = 1200; fogEndDistance = 6000
            buildOpenWorldGround()
            buildSeaPlane()
            worldX = 0; worldZ = 0; heading = 0
        } else {
            buildGround()
            buildRacingLevel(); buildTrackDecorations(); buildTrackPath()
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
        camBankAngle = 0; currentFOV = 95; boostTimer = 0; boostEnergy = 1.0
        timeAccum = 0; raceState = .waiting; raceTime = 0
        isBoosting = false; boostHeld = false; nearMissCooldown = 0
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
        sun.shadowRadius = 1.5; sun.shadowSampleCount = quality.shadowSamples; sun.shadowMode = .deferred
        sun.shadowMapSize = quality.shadowMapSize; sun.shadowBias = 0.002
        sun.shadowColor = UIColor(white: 0, alpha: 0.50)
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
        let skySegs = quality == .low ? 10 : quality == .medium ? 14 : 18
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
        hm.isDoubleSided = true; hm.transparency = 0.30; halo.firstMaterial = hm
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
        cloudMat.diffuse.contents = UIColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 0.50)
        cloudMat.lightingModel = .constant; cloudMat.isDoubleSided = true
        cloudMat.writesToDepthBuffer = false

        // Wispy edge material — more transparent for softer edges
        let wispMat = SCNMaterial()
        wispMat.diffuse.contents = UIColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 0.18)
        wispMat.lightingModel = .constant; wispMat.isDoubleSided = true
        wispMat.writesToDepthBuffer = false

        let cloudContainer = SCNNode()

        let cloudCount = quality == .low ? 14 : quality == .medium ? 24 : 36
        for _ in 0..<cloudCount {
            let cloudNode = SCNNode()
            // Core puffs — overlapping flattened spheres
            let coreCount = Int(rnd() * 4) + 4
            for j in 0..<coreCount {
                let r = CGFloat(12 + rnd() * 20)
                let puff = SCNSphere(radius: r)
                puff.segmentCount = quality == .low ? 8 : 12
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
                    halo.segmentCount = quality == .low ? 6 : 10
                    halo.firstMaterial = wispMat
                    let hn = SCNNode(geometry: halo)
                    hn.position = n.position
                    hn.scale = SCNVector3(xScale * 1.2, yScale * 0.8, 1.3)
                    hn.castsShadow = false
                    cloudNode.addChildNode(hn)
                }
            }

            let angle = rnd() * .pi * 2
            let dist: Float = 800 + rnd() * 3500
            let height: Float = 200 + rnd() * 350
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

        // --- Outer backdrop range — massive peaks beyond the playable area ---
        let outerCount = quality == .low ? 28 : quality == .medium ? 44 : 64
        for i in 0..<outerCount {
            let angle = Float(i) / Float(outerCount) * .pi * 2 + (rnd() - 0.5) * 0.12
            let dist: Float = 4200 + rnd() * 1800   // well beyond island edge
            let height: Float = 300 + rnd() * 700    // towering peaks, up to 1000m
            let width: Float = 300 + rnd() * 600

            // Slightly blunted top for realism — topRadius > 0
            let topR = CGFloat(rnd() * width * 0.06)
            let cone = SCNCone(topRadius: topR, bottomRadius: CGFloat(width * 0.5), height: CGFloat(height))
            cone.radialSegmentCount = 12; cone.heightSegmentCount = 3
            let mat = SCNMaterial()
            // Colour varies by height — darker base, lighter/bluer at distance
            let shade = 0.28 + rnd() * 0.18
            let blueTint: Float = 0.12 + (dist - 4200) / 1800 * 0.15  // more blue = more distant
            mat.diffuse.contents = UIColor(red: CGFloat(shade * 0.6), green: CGFloat(shade * 0.7),
                                           blue: CGFloat(shade * 0.9 + blueTint), alpha: 1)
            mat.lightingModel = .physicallyBased; mat.roughness.contents = CGFloat(0.92); mat.metalness.contents = CGFloat(0.0)
            cone.firstMaterial = mat

            let n = SCNNode(geometry: cone)
            // Sink base below ground so no floating gap
            n.position = SCNVector3(sin(angle) * dist, height * 0.2 - 40, cos(angle) * dist)
            n.castsShadow = false
            mtContainer.addChildNode(n)

            // Snow cap on tall peaks
            if height > 400 {
                let snowH = height * (0.20 + rnd() * 0.15)
                let snowR = CGFloat(width * 0.22)
                let cap = SCNCone(topRadius: topR * 0.5, bottomRadius: snowR, height: CGFloat(snowH))
                cap.radialSegmentCount = 12; cap.heightSegmentCount = 1
                let snowMat = SCNMaterial()
                snowMat.diffuse.contents = UIColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1)
                snowMat.lightingModel = .physicallyBased; snowMat.roughness.contents = CGFloat(0.65); snowMat.metalness.contents = CGFloat(0.0)
                cap.firstMaterial = snowMat
                let capNode = SCNNode(geometry: cap)
                capNode.position = SCNVector3(0, height * 0.35, 0)
                capNode.castsShadow = false
                n.addChildNode(capNode)
            }

            // Secondary shoulder peak next to tall mountains
            if height > 500 && rnd() > 0.4 {
                let sH = height * (0.4 + rnd() * 0.3)
                let sW = width * (0.4 + rnd() * 0.3)
                let shoulder = SCNCone(topRadius: CGFloat(rnd() * sW * 0.04), bottomRadius: CGFloat(sW * 0.5), height: CGFloat(sH))
                shoulder.radialSegmentCount = 10; shoulder.heightSegmentCount = 2
                shoulder.firstMaterial = mat
                let sn = SCNNode(geometry: shoulder)
                let offset = width * 0.4 * (rnd() > 0.5 ? 1 : -1)
                sn.position = SCNVector3(offset, sH * 0.15 - 20, rnd() * width * 0.2)
                sn.castsShadow = false
                n.addChildNode(sn)
            }
        }

        // --- Inner ring of smaller foothills — transition between terrain and backdrop ---
        let innerCount = quality == .low ? 12 : quality == .medium ? 20 : 30
        for i in 0..<innerCount {
            let angle = Float(i) / Float(innerCount) * .pi * 2 + (rnd() - 0.5) * 0.25
            let dist: Float = 3400 + rnd() * 600
            let height: Float = 80 + rnd() * 160
            let width: Float = 200 + rnd() * 350

            let cone = SCNCone(topRadius: CGFloat(rnd() * width * 0.08), bottomRadius: CGFloat(width * 0.5), height: CGFloat(height))
            cone.radialSegmentCount = 10; cone.heightSegmentCount = 2
            let mat = SCNMaterial()
            let shade = 0.30 + rnd() * 0.15
            mat.diffuse.contents = UIColor(red: CGFloat(shade * 0.65), green: CGFloat(shade * 0.75),
                                           blue: CGFloat(shade * 0.85), alpha: 1)
            mat.lightingModel = .physicallyBased; mat.roughness.contents = CGFloat(0.90); mat.metalness.contents = CGFloat(0.0)
            cone.firstMaterial = mat

            let n = SCNNode(geometry: cone)
            n.position = SCNVector3(sin(angle) * dist, height * 0.25 - 20, cos(angle) * dist)
            n.castsShadow = false
            mtContainer.addChildNode(n)
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
            n.position = SCNVector3(tc + (rnd() - 0.5) * corridorHalf * 1.2, trackHeight(z) + 0.02, z)
            n.castsShadow = false
            rootNode.addChildNode(n)
            z += 90 + rnd() * 60
        }
    }

    // MARK: - Ground
    private func buildGround() {
        // Build terrain mesh with track height variation
        // Extend far enough that edges are never visible (track can swing ±234m)
        let halfX: Float = 500      // lateral extent from center
        let zMin: Float = -120
        let zMax: Float = trackLength + 120
        let stepX: Float = 6; let stepZ: Float = 6
        let nx = Int((halfX * 2) / stepX) + 1
        let nz = Int((zMax - zMin) / stepZ) + 1

        var verts = [SCNVector3](); verts.reserveCapacity(nx * nz)
        var normals = [SCNVector3](); normals.reserveCapacity(nx * nz)
        var uvs = [CGPoint](); uvs.reserveCapacity(nx * nz)
        var indices = [Int32](); indices.reserveCapacity((nx - 1) * (nz - 1) * 6)

        for iz in 0..<nz {
            let z = zMin + Float(iz) * stepZ
            let baseH = trackHeight(z)
            let tc = trackCenterX(z)
            for ix in 0..<nx {
                let x = -halfX + Float(ix) * stepX
                // Blend height: on-track follows trackHeight, off-track slopes down gently
                let lateral = abs(x - tc)
                let trackBlend = min(1, max(0, (lateral - 20) / 40))  // full track height within 20m, blend over 40m
                let offTrackSlope = baseH - (lateral - 20) * 0.015 * (lateral > 20 ? 1 : 0) // gentle downward slope away from track
                let y = baseH * (1 - trackBlend) + offTrackSlope * trackBlend - 0.05
                verts.append(SCNVector3(x, y, z))

                // UV for tiled texture
                uvs.append(CGPoint(x: CGFloat(x * 0.045), y: CGFloat(z * 0.045)))

                // Normal from height gradient — sample actual terrain at neighbours
                let hL = terrainHeight(x - 1, z)
                let hR = terrainHeight(x + 1, z)
                let hF = terrainHeight(x, z + 1)
                let hB = terrainHeight(x, z - 1)
                let nx2 = hL - hR; let nz2 = hB - hF; let ny: Float = 2.0
                let len = sqrtf(nx2 * nx2 + ny * ny + nz2 * nz2)
                normals.append(SCNVector3(nx2 / len, ny / len, nz2 / len))
            }
        }

        let cols = Int32(nx)
        for iz in 0..<(nz - 1) {
            for ix in 0..<(nx - 1) {
                let tl = Int32(iz) * cols + Int32(ix)
                let tr = tl + 1; let bl = tl + cols; let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        let vertSrc = SCNGeometrySource(vertices: verts)
        let normSrc = SCNGeometrySource(normals: normals)
        let uvSrc   = SCNGeometrySource(textureCoordinates: uvs)
        let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: idxData, primitiveType: .triangles,
                                         primitiveCount: indices.count / 3,
                                         bytesPerIndex: MemoryLayout<Int32>.size)
        let geo = SCNGeometry(sources: [vertSrc, normSrc, uvSrc], elements: [element])

        let mat = SCNMaterial()
        mat.diffuse.contents = makeGroundTex(); mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
        mat.lightingModel = .physicallyBased; mat.roughness.contents = CGFloat(0.95); mat.metalness.contents = CGFloat(0.0); geo.firstMaterial = mat
        groundNode = SCNNode(geometry: geo)
        groundNode.position = SCNVector3(0, 0, 0)
        rootNode.addChildNode(groundNode)
    }

    private func makeGroundTex() -> UIImage {
        let sz: CGFloat = 512
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
        for _ in 0..<1600 {
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
        for _ in 0..<2200 {
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

    // MARK: - Open World Ground & Sea

    private func buildOpenWorldGround() {
        let worldSize: Float = 7000
        // Build terrain mesh — same vertex budget as before, coarser step for bigger world
        let gridRes = quality == .low ? 160 : quality == .medium ? 240 : 320
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

                // Tiled UVs — same scale as race mode ground
                uvs.append(CGPoint(x: CGFloat(wx * 0.045), y: CGFloat(wz * 0.045)))

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

        // Use the same tiled grass texture as race mode — crisp at any distance
        let mat = SCNMaterial()
        mat.diffuse.contents = makeGroundTex()
        mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
        mat.lightingModel = .physicallyBased; mat.roughness.contents = CGFloat(0.95); mat.metalness.contents = CGFloat(0.0); mat.isDoubleSided = false
        geo.firstMaterial = mat

        groundNode = SCNNode(geometry: geo)
        groundNode.position = SCNVector3(0, 0, 0)
        rootNode.addChildNode(groundNode)
    }

    private let waterLevel: Float = -0.3

    private func makeWaterMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        // Clearer water — lighter teal tint so you can see depth through it
        mat.diffuse.contents = UIColor(red: 0.06, green: 0.22, blue: 0.32, alpha: 1)
        mat.metalness.contents = CGFloat(0.04)
        mat.roughness.contents = CGFloat(0.15)
        mat.transparency = 0.58  // more transparent for depth visibility
        mat.transparencyMode = .dualLayer
        mat.isDoubleSided = false
        mat.fresnelExponent = 3.0  // softer fresnel so you see through more at direct angles
        mat.writesToDepthBuffer = true
        // Procedural wave normal map for surface detail
        let normalTex = makeWaterNormalTex()
        mat.normal.contents = normalTex
        mat.normal.intensity = 0.30  // subtle — enough for ripple detail, not frantic
        mat.normal.wrapS = .repeat; mat.normal.wrapT = .repeat
        mat.normal.contentsTransform = SCNMatrix4MakeScale(10, 10, 1)
        // Gentle wave animation — slow drift, small translation for stable reflections
        let scroll = CABasicAnimation(keyPath: "contentsTransform")
        scroll.fromValue = NSValue(scnMatrix4: SCNMatrix4MakeScale(10, 10, 1))
        scroll.toValue = NSValue(scnMatrix4: SCNMatrix4Mult(
            SCNMatrix4MakeTranslation(0.04, 0.03, 0),
            SCNMatrix4MakeScale(10, 10, 1)))
        scroll.duration = 8.0; scroll.repeatCount = .infinity
        scroll.autoreverses = true
        scroll.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mat.normal.addAnimation(scroll, forKey: "wave")
        return mat
    }

    /// Procedural normal map for water surface ripples — choppier, more realistic
    private func makeWaterNormalTex() -> UIImage {
        let sz = 256
        var pixels = [UInt8](repeating: 0, count: sz * sz * 4)
        for y in 0..<sz {
            for x in 0..<sz {
                let u = Float(x) / Float(sz) * .pi * 2
                let v = Float(y) / Float(sz) * .pi * 2
                // Broad swells with gentle ripple detail — stable, not frantic
                let dx = cosf(u * 2.0 + v * 1.0) * 0.40 + cosf(u * 5.0 - v * 1.5) * 0.18 + sinf(u * 9.0 + v * 3.0) * 0.06
                let dy = sinf(v * 2.0 + u * 1.0) * 0.40 + sinf(v * 5.0 - u * 1.5) * 0.18 + cosf(v * 9.0 + u * 3.0) * 0.06
                let i = (y * sz + x) * 4
                pixels[i]     = UInt8(clamping: Int((dx * 0.5 + 0.5) * 255))
                pixels[i + 1] = UInt8(clamping: Int((dy * 0.5 + 0.5) * 255))
                pixels[i + 2] = 255  // z component pointing up
                pixels[i + 3] = 255
            }
        }
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImg = CGImage(width: sz, height: sz, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: sz * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: cgImg)
    }

    private func buildSeaPlane() {
        let sea = SCNPlane(width: 12000, height: 12000)
        sea.firstMaterial = makeWaterMaterial()
        let seaNode = SCNNode(geometry: sea)
        seaNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        seaNode.position = SCNVector3(0, waterLevel, 0)
        seaNode.renderingOrder = -1
        rootNode.addChildNode(seaNode)
        // Gentle swell — slow, smooth, natural ocean rhythm
        seaNode.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.10, z: 0, duration: 2.8),
            .moveBy(x: 0, y: -0.10, z: 0, duration: 3.2),
        ])))
    }

    /// Spawn water pools near the race track as small clearings
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
                let offX = corridorHalf + 4 + rnd() * 18  // close to track edge, not far off
                // Only place pools where terrain is relatively flat
                let slope = abs(trackHeight(z + 5) - trackHeight(z - 5)) / 10.0
                guard slope < 0.12 else { z += 180 + rnd() * 250; continue }
                let poolW = CGFloat(5 + rnd() * 8)   // smaller pools that sit well on terrain
                let poolH = CGFloat(4 + rnd() * 6)

                let poolX = tc + side * offX
                let poolY = terrainHeight(poolX, z) + 0.05  // sit just above terrain surface

                let pool = SCNPlane(width: poolW, height: poolH)
                pool.firstMaterial = poolMat; pool.cornerRadius = min(poolW, poolH) * 0.4
                let n = SCNNode(geometry: pool)
                // Tilt pool to match terrain slope
                let dh = terrainHeight(poolX, z + 3) - terrainHeight(poolX, z - 3)
                let slopeAngle = atan2(dh, 6.0)
                n.eulerAngles = SCNVector3(-.pi / 2 + slopeAngle, 0, 0)
                n.position = SCNVector3(poolX, poolY, z)
                n.renderingOrder = 2; n.castsShadow = false
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

    func trackHeight(_ z: Float) -> Float {
        guard mode == .race else { return 0 }
        // Rolling hills — long gentle slopes with occasional steep sections
        let broad  = sinf(z * 0.0045 + 0.5) * 10.0             // big gentle hills
        let medium = sinf(z * 0.012 + 2.1) * 5.0               // mid-frequency undulation
        let dip    = sinf(z * 0.025 + 4.3) * 2.5               // quick dips
        // Flatten near start and finish
        let startFade = min(1, z / 120)                          // flat first 120m
        let endFade   = min(1, max(0, (trackLength - z)) / 120) // flat last 120m
        return (broad + medium + dip) * startFade * endFade
    }

    // Lateral banking angle from curve gradient — used for camera roll
    private func trackBankAngle(_ z: Float) -> Float {
        let dx = (trackCenterX(z + 3) - trackCenterX(z - 3)) / 6
        return max(-0.30, min(0.30, -dx * 0.06))
    }

    // MARK: - Surface type (spray colour)
    enum SurfaceType { case water, dirt, grass, sand }

    /// Determine what surface the speeder is over — used for spray colour
    func surfaceAt(x: Float, z: Float) -> SurfaceType {
        if mode == .race {
            let tc = trackCenterX(z)
            let lateral = abs(x - tc)
            if lateral < corridorHalf { return .dirt }  // on the dirt track
            return .grass                                // off-track forest floor
        }
        // Open world — check water first, then biome
        let tH = terrainHeight(x, z)
        if tH < waterLevel { return .water }
        let biome = biomeAt(x: x, z: z)
        switch biome {
        case .sand, .beach: return .sand
        case .forest:       return .grass
        case .grassyPlain:  return .grass
        }
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

    /// Bilinearly interpolated noise at world position — coarse 280m cells for vast biomes
    private func biomeNoise(_ x: Float, _ z: Float) -> Float {
        let cell: Float = 280
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
        if dist > islandRadius - 100 { return .beach }

        let n = biomeNoise(x, z)
        // Radial bias: center favours forest, edges favour sand
        let radialBias = dist / islandRadius       // 0 at center, ~0.95 at edge
        let adjusted = n + radialBias * 0.25 - 0.12 // shift toward sand at edges

        if adjusted < 0.30 { return .forest }
        if adjusted < 0.62 { return .grassyPlain }
        return .sand
    }

    // MARK: - Terrain height (open world only)

    /// Smooth terrain height using layered noise — vast hills, valleys and open plains
    func terrainHeight(_ x: Float, _ z: Float) -> Float {
        if mode == .race {
            let baseH = trackHeight(z)
            let tc = trackCenterX(z)
            let lateral = abs(x - tc)
            let trackBlend = min(1, max(0, (lateral - 20) / 40))
            let offTrackH = baseH - (lateral - 20) * 0.015 * (lateral > 20 ? 1 : 0)  // slope down away from track
            return baseH * (1 - trackBlend) + offTrackH * trackBlend - 0.05
        }
        guard mode == .openWorld else { return 0 }
        let dist = sqrtf(x * x + z * z)
        // Wide flat spawn area — gradually fades in terrain over 400-800m
        let centerFade: Float
        if dist < 400 {
            centerFade = 0  // completely flat spawn zone
        } else if dist < 800 {
            let t = (dist - 400) / 400
            centerFade = t * t * (3 - 2 * t)  // smooth hermite ramp
        } else {
            centerFade = 1
        }
        let edgeFade = max(0, 1 - max(0, dist - (islandRadius - 250)) / 250) // flat at beach

        // Continent-scale undulation — vast sweeping terrain
        let h1 = sinf(x * 0.0012 + 1.3) * cosf(z * 0.0014 + 0.7) * 55.0    // massive continent hills
        let h2 = sinf(x * 0.0025 + z * 0.0018 + 2.1) * 35.0                  // broad diagonal ridge system
        let h3 = sinf(x * 0.0045 + 5.1) * cosf(z * 0.0038 + 3.2) * 20.0     // mid-scale rolling hills
        // Plains flattening — use noise to create flat plateaus between hills
        let plainNoise = sinf(x * 0.0008 + 4.2) * cosf(z * 0.0009 + 1.8)
        let plainFactor: Float = plainNoise > 0.3 ? 1.0 : (plainNoise > 0.0 ? plainNoise / 0.3 : 0.0)
        // Valley carving — negative areas become deeper
        let valleyRaw = h1 + h2
        let valleyDeepen: Float = valleyRaw < -15 ? (valleyRaw + 15) * 0.4 : 0  // deepen valleys
        // Gentle surface detail — very subtle, mostly smooth
        let h4 = sinf(x * 0.015 + 2.7) * cosf(z * 0.012 + 1.1) * 2.5

        var raw = (h1 + h2 + h3) * plainFactor + valleyDeepen + h4

        // Drivable mountain peaks — large peaks scattered across the map
        // Each peak is a gaussian bump at a fixed world position
        let peaks: [(px: Float, pz: Float, height: Float, radius: Float)] = [
            ( 1800,  1400, 220, 500),   // tall peak NE
            (-1600,  2000, 180, 450),   // ridge NW
            ( 2200, -1200, 250, 550),   // massive peak SE
            (-2400, -1000, 160, 400),   // broad hill SW
            (  800,  2600, 200, 480),   // distant north peak
            (-1200, -2400, 190, 420),   // southern ridge
            ( 2800,   400, 170, 380),   // eastern outcrop
            (-2800,  1200, 210, 500),   // western summit
        ]
        for p in peaks {
            let dx = x - p.px; let dz = z - p.pz
            let d2 = dx * dx + dz * dz
            let r2 = p.radius * p.radius
            if d2 < r2 * 4 {  // only compute if within 2x radius
                let falloff = expf(-d2 / (2 * r2 * 0.18))  // steep gaussian
                raw += p.height * falloff
            }
        }

        return raw * centerFade * edgeFade
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
        let tc = trackCenterX(z); let gy = trackHeight(z)
        let woodMat = SCNMaterial()
        woodMat.diffuse.contents = UIColor(red: 0.32, green: 0.20, blue: 0.10, alpha: 1)
        woodMat.lightingModel = .physicallyBased; woodMat.roughness.contents = CGFloat(0.82); woodMat.metalness.contents = CGFloat(0.0)
        // Posts
        for side: Float in [-1, 1] {
            let post = SCNCylinder(radius: 0.22, height: 5.5); post.radialSegmentCount = 10; post.firstMaterial = woodMat
            let pn = SCNNode(geometry: post); pn.position = SCNVector3(tc + side * (corridorHalf + 0.3), gy + 2.75, z); parent.addChildNode(pn)
        }
        // Cross-beam log — slightly rotated for natural look
        let beam = SCNCylinder(radius: 0.18, height: CGFloat(corridorHalf * 2 + 1.2))
        beam.radialSegmentCount = 10; beam.firstMaterial = woodMat
        let bn = SCNNode(geometry: beam)
        bn.position = SCNVector3(tc, gy + 5.6, z)
        bn.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
        parent.addChildNode(bn)
        // Moss/lichen accent on top of beam
        let mossMat = SCNMaterial(); mossMat.diffuse.contents = UIColor(red: 0.25, green: 0.50, blue: 0.16, alpha: 1)
        mossMat.lightingModel = .physicallyBased; mossMat.roughness.contents = CGFloat(0.95); mossMat.metalness.contents = CGFloat(0.0)
        let moss = SCNBox(width: CGFloat(corridorHalf + 0.5), height: 0.20, length: 0.30, chamferRadius: 0.06); moss.firstMaterial = mossMat
        let mn = SCNNode(geometry: moss); mn.position = SCNVector3(tc, gy + 5.82, z); parent.addChildNode(mn)
    }

    // Start / finish arch — ancient stone torii with vines
    private func buildForestArch(at z: Float, finish: Bool, parent: SCNNode) {
        let tc = trackCenterX(z); let gy = trackHeight(z)
        let stoneMat = SCNMaterial()
        stoneMat.diffuse.contents = finish ? UIColor(red: 0.62, green: 0.54, blue: 0.42, alpha: 1)
                                           : UIColor(red: 0.50, green: 0.46, blue: 0.38, alpha: 1)
        stoneMat.lightingModel = .physicallyBased; stoneMat.roughness.contents = CGFloat(0.75); stoneMat.metalness.contents = CGFloat(0.0)
        let mossMat = SCNMaterial(); mossMat.diffuse.contents = UIColor(red: 0.22, green: 0.44, blue: 0.14, alpha: 1)
        mossMat.lightingModel = .physicallyBased; mossMat.roughness.contents = CGFloat(0.95); mossMat.metalness.contents = CGFloat(0.0)

        // Two chunky stone columns
        for side: Float in [-1, 1] {
            let col = SCNCylinder(radius: 1.1, height: 10.0); col.radialSegmentCount = 12; col.firstMaterial = stoneMat
            let cn = SCNNode(geometry: col); cn.position = SCNVector3(tc + side * (corridorHalf + 1.5), gy + 5.0, z); parent.addChildNode(cn)
            let cap = SCNBox(width: 2.8, height: 0.9, length: 2.8, chamferRadius: 0.12); cap.firstMaterial = stoneMat
            let capn = SCNNode(geometry: cap); capn.position = SCNVector3(tc + side * (corridorHalf + 1.5), gy + 10.6, z); parent.addChildNode(capn)
            let mossStrip = SCNBox(width: 2.0, height: 1.8, length: 0.5, chamferRadius: 0.1); mossStrip.firstMaterial = mossMat
            let msn = SCNNode(geometry: mossStrip); msn.position = SCNVector3(tc + side * (corridorHalf + 1.5), gy + 4.0 + Float.random(in: 0...2), z + 1.1); parent.addChildNode(msn)
        }
        let lintel = SCNBox(width: CGFloat(corridorHalf * 2 + 5.8), height: 1.4, length: 1.8, chamferRadius: 0.15); lintel.firstMaterial = stoneMat
        let ln = SCNNode(geometry: lintel); ln.position = SCNVector3(tc, gy + 11.3, z); parent.addChildNode(ln)
        let topBeam = SCNBox(width: CGFloat(corridorHalf * 2 + 7.0), height: 0.7, length: 1.0, chamferRadius: 0.10); topBeam.firstMaterial = stoneMat
        let tbn = SCNNode(geometry: topBeam); tbn.position = SCNVector3(tc, gy + 12.4, z); parent.addChildNode(tbn)

        // Finish: golden glow totem on lintel centre
        if finish {
            let totemMat = SCNMaterial()
            totemMat.diffuse.contents  = UIColor(red: 0.95, green: 0.78, blue: 0.12, alpha: 1)
            totemMat.emission.contents = UIColor(red: 0.60, green: 0.42, blue: 0.02, alpha: 1)
            totemMat.lightingModel = .phong
            let totem = SCNCylinder(radius: 0.30, height: 2.2); totem.radialSegmentCount = 12; totem.firstMaterial = totemMat
            let tn = SCNNode(geometry: totem); tn.position = SCNVector3(tc, gy + 13.5, z); parent.addChildNode(tn)
            let orb = SCNSphere(radius: 0.55); orb.segmentCount = 14; orb.firstMaterial = totemMat
            let on = SCNNode(geometry: orb); on.position = SCNVector3(tc, gy + 14.9, z); parent.addChildNode(on)
        }
    }

    private func buildTrackDecorations() {
        let root = SCNNode(); rootNode.addChildNode(root)
        func stoneMat() -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: 0.46, green: 0.42, blue: 0.36, alpha: 1)
            m.lightingModel = .physicallyBased; m.roughness.contents = CGFloat(0.75); m.metalness.contents = CGFloat(0.0); return m
        }
        let sm = stoneMat()
        // Stone archways
        for gz: Float in [600, 1200, 1800, 2400, 3000] {
            let tc = trackCenterX(gz); let gy = trackHeight(gz)
            for side: Float in [-1, 1] {
                let col = SCNCylinder(radius: 1.3, height: 13.0); col.radialSegmentCount = 12; col.firstMaterial = sm
                let cn = SCNNode(geometry: col); cn.position = SCNVector3(tc + side * (corridorHalf + 2.0), gy + 6.5, gz); root.addChildNode(cn)
                let cap = SCNBox(width: 3.0, height: 1.1, length: 3.0, chamferRadius: 0.1); cap.firstMaterial = sm
                let capn = SCNNode(geometry: cap); capn.position = SCNVector3(tc + side * (corridorHalf + 2.0), gy + 13.7, gz); root.addChildNode(capn)
            }
            let lintel = SCNBox(width: CGFloat(corridorHalf * 2 + 6.0), height: 1.3, length: 1.7, chamferRadius: 0.2); lintel.firstMaterial = sm
            let ln = SCNNode(geometry: lintel); ln.position = SCNVector3(tc, gy + 14.3, gz); root.addChildNode(ln)
        }
        // Stone pillars
        var pz: Float = 140
        let piSm = stoneMat()
        while pz < trackLength {
            let tc = trackCenterX(pz); let gy = trackHeight(pz)
            for side: Float in [-1, 1] {
                let h = Float.random(in: 5...11)
                let pillar = SCNCylinder(radius: 0.40, height: CGFloat(h)); pillar.radialSegmentCount = 10; pillar.firstMaterial = piSm
                let pn = SCNNode(geometry: pillar)
                pn.position = SCNVector3(tc + side * (corridorHalf + Float.random(in: 3...8)), gy + h * 0.5, pz)
                pn.eulerAngles = SCNVector3(Float.random(in: -0.10...0.10), Float.random(in: 0...Float.pi), 0)
                root.addChildNode(pn)
            }
            pz += 155
        }
        // Fallen logs
        let logMat = SCNMaterial(); logMat.diffuse.contents = UIColor(red: 0.30, green: 0.18, blue: 0.09, alpha: 1)
        logMat.lightingModel = .physicallyBased; logMat.roughness.contents = CGFloat(0.85); logMat.metalness.contents = CGFloat(0.0)
        var lz: Float = 320
        while lz < trackLength {
            let gy = trackHeight(lz)
            let logGeo = SCNCylinder(radius: 1.1, height: 28.0); logGeo.radialSegmentCount = 10; logGeo.firstMaterial = logMat
            let ln = SCNNode(geometry: logGeo)
            ln.position = SCNVector3(trackCenterX(lz), gy + 3.8, lz)
            ln.eulerAngles = SCNVector3(0, Float.random(in: 0.3...0.8), .pi / 2); root.addChildNode(ln)
            lz += 370
        }
    }

    // MARK: - Track path markers (race mode wayfinding)
    private func buildTrackPath() {
        // 1) Worn dirt strip — mesh strip that follows terrain height exactly
        let pathMat = SCNMaterial()
        pathMat.diffuse.contents = UIColor(red: 0.30, green: 0.21, blue: 0.11, alpha: 1)
        pathMat.lightingModel = .constant  // flat shading — no specular/reflection artifacts
        pathMat.transparency = 0.55
        pathMat.writesToDepthBuffer = false
        pathMat.readsFromDepthBuffer = true
        pathMat.isDoubleSided = true

        // Build a continuous mesh strip that hugs the terrain
        let pathStep: Float = 4          // fine step for smooth terrain following
        let halfW: Float = corridorHalf   // half-width of dirt strip
        let zStart: Float = -20
        let zEnd: Float = trackLength + 20
        let numZ = Int((zEnd - zStart) / pathStep) + 1
        let vertsPerRow = 5  // cross-section vertices for smooth width

        var trackVerts = [SCNVector3](); trackVerts.reserveCapacity(numZ * vertsPerRow)
        var trackNormals = [SCNVector3](); trackNormals.reserveCapacity(numZ * vertsPerRow)
        var trackUVs = [CGPoint](); trackUVs.reserveCapacity(numZ * vertsPerRow)
        var trackIndices = [Int32](); trackIndices.reserveCapacity((numZ - 1) * (vertsPerRow - 1) * 6)

        for iz in 0..<numZ {
            let z = zStart + Float(iz) * pathStep
            let tc = trackCenterX(z)
            // Direction tangent for perpendicular calculation
            let tcNext = trackCenterX(z + 1)
            let tcPrev = trackCenterX(z - 1)
            let dirX = tcNext - tcPrev; let dirZ: Float = 2.0
            let dirLen = sqrtf(dirX * dirX + dirZ * dirZ)
            // Perpendicular (right) vector
            let perpX = dirZ / dirLen; let perpZ = -dirX / dirLen

            for ix in 0..<vertsPerRow {
                let t = Float(ix) / Float(vertsPerRow - 1) * 2.0 - 1.0  // -1 to 1
                let wx = tc + perpX * t * halfW
                let wz = z + perpZ * t * halfW
                let y = terrainHeight(wx, wz) + 0.10  // slight offset above ground
                trackVerts.append(SCNVector3(wx, y, wz))
                trackNormals.append(SCNVector3(0, 1, 0))
                trackUVs.append(CGPoint(x: Double(t * 0.5 + 0.5), y: Double(z * 0.03)))
            }
        }

        let cols = Int32(vertsPerRow)
        for iz in 0..<(numZ - 1) {
            for ix in 0..<(vertsPerRow - 1) {
                let tl = Int32(iz) * cols + Int32(ix)
                let tr = tl + 1; let bl = tl + cols; let br = bl + 1
                trackIndices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        let vertSrc = SCNGeometrySource(vertices: trackVerts)
        let normSrc = SCNGeometrySource(normals: trackNormals)
        let uvSrc = SCNGeometrySource(textureCoordinates: trackUVs)
        let idxData = Data(bytes: trackIndices, count: trackIndices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: idxData, primitiveType: .triangles,
                                          primitiveCount: trackIndices.count / 3,
                                          bytesPerIndex: MemoryLayout<Int32>.size)
        let geo = SCNGeometry(sources: [vertSrc, normSrc, uvSrc], elements: [element])
        geo.firstMaterial = pathMat
        let trackNode = SCNNode(geometry: geo)
        trackNode.castsShadow = false; trackNode.renderingOrder = 1
        rootNode.addChildNode(trackNode)

        // 2) Edge markers — wooden posts with warm lantern glow
        let postMat = SCNMaterial()
        postMat.diffuse.contents = UIColor(red: 0.28, green: 0.18, blue: 0.10, alpha: 1)
        postMat.lightingModel = .physicallyBased; postMat.roughness.contents = CGFloat(0.82); postMat.metalness.contents = CGFloat(0.0)
        let postGeo = SCNCylinder(radius: 0.12, height: 1.2); postGeo.radialSegmentCount = 8
        postGeo.firstMaterial = postMat

        let lanternMat = SCNMaterial()
        lanternMat.diffuse.contents = UIColor(red: 0.90, green: 0.65, blue: 0.25, alpha: 1)
        lanternMat.emission.contents = UIColor(red: 0.50, green: 0.32, blue: 0.08, alpha: 1)
        lanternMat.lightingModel = .constant
        let lanternGeo = SCNSphere(radius: 0.22); lanternGeo.segmentCount = 6
        lanternGeo.firstMaterial = lanternMat

        let markerStep: Float = 25
        var mz: Float = 0
        while mz < trackLength {
            let tc = trackCenterX(mz)
            for side: Float in [-1, 1] {
                let px = tc + side * corridorHalf * 0.92
                let th = terrainHeight(px, mz)
                let post = SCNNode(geometry: postGeo)
                post.position = SCNVector3(px, th + 0.6, mz)
                post.castsShadow = false
                rootNode.addChildNode(post)
                let lantern = SCNNode(geometry: lanternGeo)
                lantern.position = SCNVector3(px, th + 1.3, mz)
                lantern.castsShadow = false
                rootNode.addChildNode(lantern)
            }
            mz += markerStep
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
            let cyl = SCNCylinder(radius: CGFloat(trunkRadii[i]), height: CGFloat(h)); cyl.radialSegmentCount = 10; cyl.heightSegmentCount = 1
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: trunkCols[i].0, green: trunkCols[i].1, blue: trunkCols[i].2, alpha: 1)
            m.lightingModel = .physicallyBased; m.roughness.contents = CGFloat(0.85); m.metalness.contents = CGFloat(0.0); cyl.firstMaterial = m; treeGeoms.append(cyl)
            // Root flare — a small cone that widens at the base for a natural look
            let flareH: CGFloat = CGFloat(h * 0.12)  // bottom 12% of tree
            let flareR = CGFloat(trunkRadii[i]) * 2.2 // wider than trunk
            let flare = SCNCone(topRadius: CGFloat(trunkRadii[i]), bottomRadius: flareR, height: flareH)
            flare.radialSegmentCount = 10; flare.firstMaterial = m
            rootFlareGeoms.append(flare)
        }

        // Canopies: 0-2 = round broadleaf, 3-4 = conical pines, 5 = dead, 6 = birch, 7 = willow, 8 = twisted oak, 9-10 = saplings
        func canopyPBR(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.lightingModel = .physicallyBased; m.roughness.contents = CGFloat(0.92); m.metalness.contents = CGFloat(0.0); return m
        }
        let broadCols: [(CGFloat,CGFloat,CGFloat)] = [(0.20,0.52,0.14),(0.16,0.44,0.10),(0.12,0.36,0.08)]
        for (i, _) in broadCols.enumerated() {
            let s = SCNSphere(radius: CGFloat(canopyRadii[i])); s.segmentCount = 12
            s.firstMaterial = canopyPBR(broadCols[i].0, broadCols[i].1, broadCols[i].2); canopyGeoms.append(s)
        }
        // Conifers — dark pointed cone canopies
        let pineCols: [(CGFloat,CGFloat,CGFloat)] = [(0.08, 0.26, 0.10), (0.06, 0.22, 0.08)]
        for (i, pc) in pineCols.enumerated() {
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(canopyRadii[3 + i] * 1.3), height: CGFloat(treeHeights[3 + i] * 0.6))
            cone.radialSegmentCount = 10
            cone.firstMaterial = canopyPBR(pc.0, pc.1, pc.2); canopyGeoms.append(cone)
        }
        // Dead tree — bare twisted branches
        let deadCanopy = SCNSphere(radius: 2.5); deadCanopy.segmentCount = 8; deadCanopy.firstMaterial = canopyPBR(0.30, 0.20, 0.12)
        canopyGeoms.append(deadCanopy)
        // Birch — light airy canopy, slightly yellow-green
        let birchCanopy = SCNSphere(radius: CGFloat(canopyRadii[6])); birchCanopy.segmentCount = 12; birchCanopy.firstMaterial = canopyPBR(0.32, 0.58, 0.18)
        canopyGeoms.append(birchCanopy)
        // Willow — wide droopy oval canopy
        let willowCanopy = SCNSphere(radius: CGFloat(canopyRadii[7])); willowCanopy.segmentCount = 14; willowCanopy.firstMaterial = canopyPBR(0.15, 0.42, 0.12)
        canopyGeoms.append(willowCanopy)
        // Twisted oak — irregular canopy
        let oakCanopy = SCNSphere(radius: CGFloat(canopyRadii[8])); oakCanopy.segmentCount = 10; oakCanopy.firstMaterial = canopyPBR(0.18, 0.40, 0.10)
        canopyGeoms.append(oakCanopy)
        // Sapling canopies — small light leafy tops
        let sapCanopy1 = SCNSphere(radius: CGFloat(canopyRadii[9])); sapCanopy1.segmentCount = 10; sapCanopy1.firstMaterial = canopyPBR(0.28, 0.56, 0.16)
        canopyGeoms.append(sapCanopy1)
        let sapCanopy2 = SCNSphere(radius: CGFloat(canopyRadii[10])); sapCanopy2.segmentCount = 10; sapCanopy2.firstMaterial = canopyPBR(0.36, 0.60, 0.22)
        canopyGeoms.append(sapCanopy2)

        // Bushes — flattened spheres, 4 sizes, dark undergrowth tones
        let bushCols: [(CGFloat,CGFloat,CGFloat)] = [(0.12,0.36,0.06),(0.10,0.30,0.05),(0.15,0.42,0.08),(0.08,0.24,0.04)]
        for (i, br) in bushRadii.enumerated() {
            let s = SCNSphere(radius: CGFloat(br)); s.segmentCount = 10
            s.firstMaterial = canopyPBR(bushCols[i].0, bushCols[i].1, bushCols[i].2); bushGeoms.append(s)
        }

        // Ferns — flat discs on the forest floor
        let fernCols: [(CGFloat,CGFloat,CGFloat)] = [(0.14,0.40,0.08),(0.10,0.34,0.06),(0.18,0.46,0.10)]
        for fc in fernCols {
            let fern = SCNCylinder(radius: 1.2, height: 0.05); fern.radialSegmentCount = 12
            fern.firstMaterial = canopyPBR(fc.0, fc.1, fc.2); fernGeoms.append(fern)
        }

        // Giant ancient tree
        let gtMat = SCNMaterial(); gtMat.diffuse.contents = UIColor(red: 0.20, green: 0.12, blue: 0.06, alpha: 1)
        gtMat.lightingModel = .physicallyBased; gtMat.roughness.contents = CGFloat(0.88); gtMat.metalness.contents = CGFloat(0.0)
        let gt = SCNCylinder(radius: 3.5, height: 85); gt.radialSegmentCount = 14; gt.heightSegmentCount = 1; gt.firstMaterial = gtMat; giantTrunkGeo = gt
        let gc = SCNSphere(radius: 22); gc.segmentCount = 14; gc.firstMaterial = canopyPBR(0.08, 0.28, 0.05); giantCanopyGeo = gc
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
            mat.lightingModel = .physicallyBased; mat.roughness.contents = CGFloat(0.78); mat.metalness.contents = CGFloat(0.0)
            sphere.firstMaterial = mat; sphere.segmentCount = 16
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

            let cell: Float = 22  // larger cells to keep node count manageable for 3200m radius
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

                    // Clump noise — trees cluster in deliberate groups
                    let clumpFreq: Float = 0.018
                    let clumpVal = sinf(tx * clumpFreq + 3.7) * cosf(tz * clumpFreq * 1.1 + 1.2) * 0.5 + 0.5
                    // Second octave for varied clump shapes
                    let clump2 = sinf(tx * clumpFreq * 2.3 + 5.1) * cosf(tz * clumpFreq * 1.8 + 4.2) * 0.3
                    let clumpDensity = clumpVal + clump2

                    switch biome {
                    case .forest:
                        // Trees cluster in clumps — dense where clump value is high, sparse between
                        let treeDensity: Float = clumpDensity > 0.45 ? 0.52 : (clumpDensity > 0.25 ? 0.12 : 0.02)
                        if roll < treeDensity {
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
                        // Bushes in forest — follow clumps
                        if bushesOn && cr(ix, iz, 7) < (clumpDensity > 0.35 ? 0.40 : 0.10) * bushScale {
                            let bi = Int(cr(ix, iz, 8) * 3.0 + 0.5) % bGeos.count
                            let bush = SCNNode(geometry: bGeos[bi])
                            bush.position = SCNVector3(tx + 2, gy + 0.3, tz + 1.5)
                            bush.castsShadow = false; newRoot.addChildNode(bush)
                        }
                        // Ferns in forest — follow clumps
                        if cr(ix, iz, 9) < (clumpDensity > 0.30 ? 0.28 : 0.06) {
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
                        // Sparse — small clumps of birch and broadleaf on plains
                        let plainTreeDensity: Float = clumpDensity > 0.55 ? 0.08 : 0.015
                        if roll < plainTreeDensity {
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
                            let gy = isRace ? self.trackHeight(tz) : Float(0)

                            // All trees get a parent node so any can be removed on smash
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
                                // Willow: wide droopy canopy
                                canopy.position = SCNVector3(tx, gy + h * 0.65, tz)
                                canopy.scale = SCNVector3(1.4, 0.55, 1.4)
                            } else if gIdx == 8 {
                                // Twisted oak: irregular canopy, slight offset
                                canopy.position = SCNVector3(tx + 1.0, gy + h * 0.78, tz)
                                canopy.scale = SCNVector3(1.1, 0.65, 0.9)
                            } else {
                                canopy.position = SCNVector3(tx, gy + h - cRadii[gIdx] * 0.1, tz)
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
                            let jgy = isRace ? self.trackHeight(tz) : Float(0)
                            let trunk = SCNNode(geometry: geos[jIdx])
                            trunk.position = SCNVector3(tx, jgy + h * 0.5, tz); trunk.scale = SCNVector3(1, hScale, 1)
                            trunk.castsShadow = false; newRoot.addChildNode(trunk)
                            let canopy = SCNNode(geometry: cGeos[jIdx])
                            if jIdx >= 3 {
                                canopy.position = SCNVector3(tx, jgy + h * 0.55, tz)
                            } else {
                                canopy.position = SCNVector3(tx, jgy + h - cRadii[jIdx] * 0.1, tz)
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
                            let bgy = isRace ? self.trackHeight(bz) : Float(0)
                            let bush = SCNNode(geometry: bGeos[bIdx])
                            bush.position = SCNVector3(bx, bgy + Float(bRadii[bIdx]) * 0.45 * bScale, bz)
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
                                let fgy = isRace ? self.trackHeight(fz) : Float(0)
                                let fern = SCNNode(geometry: fGeos[fIdx])
                                fern.position = SCNVector3(fx, fgy + 0.08, fz)
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
                            let ggy = isRace ? self.trackHeight(gzz) : Float(0)
                            let trunk = SCNNode(geometry: gtGeo)
                            trunk.position = SCNVector3(gx, ggy + 85 * hScale * 0.5, gzz)
                            trunk.scale = SCNVector3(1, hScale, 1); trunk.castsShadow = false
                            newRoot.addChildNode(trunk)
                            let canopy = SCNNode(geometry: gcGeo)
                            canopy.position = SCNVector3(gx, ggy + 85 * hScale - 8, gzz)
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
            // Exhaust bell — starts dim/neutral, intensifies with speed
            let bellMat = glow(0.30, 0.35, 0.45, s: 0.3)  // cool neutral at idle
            let bell = SCNCone(topRadius: 0.14, bottomRadius: 0.24, height: 0.35); bell.radialSegmentCount = 12; bell.firstMaterial = bellMat
            speederBody.addChildNode(SCNNode(geometry: bell) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.46, -0.14, 3.10) })
            exhaustBellMats.append(bellMat)
            // Exhaust core glow — starts dim, ramps to bright with speed
            let coreMat = glow(0.25, 0.30, 0.40, s: 0.2)  // cool neutral at idle
            let exhaust = SCNCylinder(radius: 0.12, height: 0.50); exhaust.radialSegmentCount = 10; exhaust.firstMaterial = coreMat
            speederBody.addChildNode(SCNNode(geometry: exhaust) ※ { $0.eulerAngles.x = .pi/2; $0.position = SCNVector3(side*0.46, -0.14, 3.45) })
            exhaustCoreMats.append(coreMat)
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
        trail.emittingDirection = SCNVector3(0, 0, 1)  // emit backward (local +Z = world rear after π flip)
        trail.particleColor = UIColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 0.4)
        trail.particleColorVariation = SCNVector4(0.05, 0.05, 0.1, 0.15)
        trail.blendMode = .additive; trail.isLightingEnabled = false
        thrusterTrail = trail
        let trailNode = SCNNode(); trailNode.position = SCNVector3(0, -0.14, 3.4)
        trailNode.addParticleSystem(trail)
        speederBody.addChildNode(trailNode)

        // Surface spray — colour and behaviour adapts to terrain type beneath the bike
        let spray = SCNParticleSystem()
        spray.birthRate = 0  // off by default, activated per-frame based on surface
        spray.emissionDuration = -1; spray.particleLifeSpan = 0.7; spray.particleLifeSpanVariation = 0.25
        spray.particleSize = 0.12; spray.particleSizeVariation = 0.08
        spray.spreadingAngle = 50; spray.particleVelocity = 5; spray.particleVelocityVariation = 2
        spray.emittingDirection = SCNVector3(0, 1, 0)
        spray.particleColor = UIColor.white  // overridden each frame
        spray.particleColorVariation = SCNVector4(0.04, 0.04, 0.04, 0.10)
        spray.blendMode = .alpha; spray.isLightingEnabled = false
        spray.acceleration = SCNVector3(0, -7, 0)
        surfaceSpray = spray
        let sprayNode = SCNNode(); sprayNode.position = SCNVector3(0, -0.5, 0)
        sprayNode.addParticleSystem(spray)
        surfaceSprayNode = sprayNode
        speederPivot.addChildNode(sprayNode)

        speederPivot.addChildNode(speederBody)
        speederPivot.position = SCNVector3(worldX, 5, worldZ)
        rootNode.addChildNode(speederPivot)
    }

    // MARK: - Camera
    private func buildCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 95; cam.motionBlurIntensity = 0; cam.zNear = 0.10
        cam.zFar = mode == .openWorld ? 6000 : 800
        cam.wantsHDR = quality.wantsHDR
        cam.bloomIntensity = quality.bloomIntensity; cam.bloomThreshold = quality.bloomThreshold; cam.bloomBlurRadius = quality.bloomBlurRadius
        cam.contrast = quality.contrast; cam.saturation = quality.saturation
        cam.vignettingIntensity = 0; cam.vignettingPower = 0
        cam.exposureAdaptationBrighteningSpeedFactor = 0; cam.exposureAdaptationDarkeningSpeedFactor = 0
        cam.wantsDepthOfField = false
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

        // Speed — unlimited boost while held; open world ramps smoothly to 2x boost
        let curMaxBoost = effectiveMaxBoost
        let curMaxNormal = effectiveMaxNormal
        isBoosting = boostHeld
        if isBoosting {
            // Smooth acceleration curve: fast initial boost, gentler ramp at high speeds
            let boostAccel: Float
            if mode == .openWorld {
                // Ease off acceleration as speed climbs — smooth logarithmic feel
                let t = max(0, forwardSpeed / curMaxBoost)  // 0 at rest, 1 at max
                boostAccel = 80 * (1 - t * 0.75)  // 80 at low speed, 20 near max
            } else {
                boostAccel = 60
            }
            forwardSpeed = min(forwardSpeed + boostAccel * dt, curMaxBoost)
        }
        if !isBoosting {
            if braking {
                forwardSpeed = max(-20, forwardSpeed - 60*dt)            // brake then reverse
            } else if throttling {
                forwardSpeed = min(forwardSpeed + 38*dt, curMaxNormal)
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
            let shoreStart = islandRadius - 60  // where water begins
            let hardLimit = islandRadius + 200   // max distance out to sea
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

        // Hover physics — smooth, floaty suspension with gentle bob
        let terrainH = terrainHeight(worldX, worldZ)
        let groundH = mode == .race ? terrainH : max(terrainH, waterLevel) // race follows track; open world floats on water
        let speedRat = min(abs(forwardSpeed) / effectiveMaxNormal, 1.0)
        // Smooth sinusoidal bob — low frequencies only, no jitter
        let bob1 = sin(timeAccum * 0.7 * .pi * 2) * 0.12       // primary gentle heave
        let bob2 = sin(timeAccum * 1.15 * .pi * 2) * 0.06      // secondary sway
        // Turn-reactive roll bob — bike dips into turns
        let turnBob = abs(turnRate / maxTurnRate) * 0.08
        let bobScale: Float = 0.4 + speedRat * 0.6
        // Sample terrain ahead & behind to anticipate slopes and prevent clipping
        let lookAheadDist: Float = max(2.0, abs(forwardSpeed) * 0.12)
        let aheadX = worldX + sin(heading) * lookAheadDist
        let aheadZ = worldZ + cos(heading) * lookAheadDist
        let aheadH = mode == .race ? terrainHeight(aheadX, aheadZ) : max(terrainHeight(aheadX, aheadZ), waterLevel)
        let effectiveGroundH = max(groundH, aheadH)  // never clip into upcoming slope

        let hoverTarget: Float = effectiveGroundH + 1.35 + (bob1 + bob2 - turnBob) * bobScale
        var accel: Float = -12.0                                // gentler gravity
        accel += lift * 65.0                                    // gradual lift — builds altitude slowly
        let heightAboveGround = speederY - effectiveGroundH
        let damping: Float = 5.0 + speedRat * 4.0
        let maxHover = effectiveGroundH + 90.0
        if speederY < maxHover {
            // Strong spring keeps bike on terrain; much stiffer when close to ground
            let springStr: Float
            if heightAboveGround < 1.0 {
                springStr = 80.0  // very stiff near ground — prevents clipping
            } else if lift > 0.01 {
                springStr = 12.0
            } else {
                springStr = 40.0
            }
            accel += (hoverTarget - speederY) * springStr - velocityY * damping
        }
        // Extra downward pull when high up and not lifting — ensures return to ground
        if lift < 0.01 && heightAboveGround > 3.0 {
            let pullDown = min(25.0, (heightAboveGround - 3.0) * 1.8)
            accel -= pullDown
        }
        velocityY += accel * dt; speederY += velocityY * dt
        // Hard floor — raised to account for speeder body geometry below pivot
        let floorH = effectiveGroundH + 0.9
        if speederY < floorH { speederY = floorH; velocityY = max(velocityY, 0) }
        if speederY > effectiveGroundH + 88.0 { speederY = effectiveGroundH + 88.0; velocityY = min(velocityY, 0) }

        // Speeder nodes
        speederPivot.position    = SCNVector3(worldX, speederY, worldZ)
        speederPivot.eulerAngles = SCNVector3(0, heading + .pi, 0)    // +π so nose (local -Z) faces direction of travel
        bankAngle  += (-(turnRate / maxTurnRate) * 1.05 - bankAngle)  * min(1, dt * 3.5)
        pitchAngle += (-velocityY * 0.035 - pitchAngle) * min(1, dt * 3.0)
        speederBody.eulerAngles = SCNVector3(-pitchAngle, 0, -bankAngle)  // negated to compensate for π flip

        // Surface spray — colour adapts to terrain type beneath the bike
        if let spray = surfaceSpray {
            let spd = abs(forwardSpeed)
            let heightAbove = speederY - groundH
            if spd > 5 && heightAbove < 4.0 {
                let proximity = max(0, 1.0 - heightAbove / 4.0)
                let speedScale = min(1.0, spd / 50.0)
                let surface = surfaceAt(x: worldX, z: worldZ)
                let rate: Float
                let color: UIColor
                let size: CGFloat
                let grav: Float
                switch surface {
                case .water:
                    color = UIColor(red: 0.70, green: 0.85, blue: 0.95, alpha: 0.45)
                    rate = proximity * speedScale * 120
                    size = 0.15; grav = -8
                case .dirt:
                    color = UIColor(red: 0.50, green: 0.38, blue: 0.22, alpha: 0.28)
                    rate = proximity * speedScale * 18
                    size = 0.06; grav = -16
                case .grass:
                    color = UIColor(red: 0.28, green: 0.50, blue: 0.18, alpha: 0.22)
                    rate = proximity * speedScale * 12
                    size = 0.05; grav = -18
                case .sand:
                    color = UIColor(red: 0.78, green: 0.68, blue: 0.45, alpha: 0.30)
                    rate = proximity * speedScale * 22
                    size = 0.06; grav = -14
                }
                spray.birthRate = CGFloat(rate)
                spray.particleColor = color
                spray.particleSize = size
                spray.particleVelocity = CGFloat(3 + spd * 0.08)
                spray.acceleration = SCNVector3(0, grav, 0)
            } else {
                spray.birthRate = 0
            }
        }

        updateCamera(dt: dt)
    }

    private func updateCamera(dt: Float) {
        let camDist: Float = 5.5
        camY += (speederY + 1.60 - camY) * min(1, dt * 6.0)
        camY  = max(camY, speederY + 0.70)
        let speedRatio = Double(forwardSpeed / effectiveMaxBoost)
        let t = forwardSpeed / effectiveMaxBoost

        // Camera shake — gentle, low-frequency only to avoid jitter
        let shake = t * t * 1.2
        let shX = sin(timeAccum * 23.1) * 0.010 * shake
        let shY = sin(timeAccum * 17.3) * 0.006 * shake
        let lateralDrift = sin(timeAccum * 5.1) * t * t * 0.06  // slow side weave
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
        camBankAngle += (bankTarget - camBankAngle) * min(1, dt * 5)
        cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
                                              simd_quatf(angle: camBankAngle, axis: SIMD3<Float>(0, 0, 1)))

        // FOV — wider base, expands at speed with boost kick
        boostFOVKick = max(0, boostFOVKick - Double(dt) * 12)
        let targetFOV = 95.0 + speedRatio * 30.0 + boostFOVKick
        currentFOV += (targetFOV - currentFOV) * Double(min(1, dt * 4.0))
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

        // Motion blur — gentle at high speeds, adds cinematic feel without pixelation
        let targetBlur = speedRatio * speedRatio * 0.18
        let curBlur    = Double(cameraNode.camera?.motionBlurIntensity ?? 0)
        cameraNode.camera?.motionBlurIntensity = CGFloat(curBlur + (targetBlur - curBlur) * Double(min(1, dt*3)))

        // DOF
        if quality == .high, let cam = cameraNode.camera {
            cam.focusDistance = CGFloat(lookDist * 0.7)
        }

        // (streaming removed — open world builds all trees at init)

        // Thruster trail + exhaust glow — intensity and colour driven by speed
        let spdT = CGFloat(max(0, min(1, forwardSpeed / effectiveMaxBoost)))  // 0→1
        if boostJustActivated { boostJustActivated = false }

        // Trail particles: rate scales with speed
        let targetTrailRate = spdT * 50 + (isBoosting ? 50 : 0)
        let curRate = CGFloat(thrusterTrail?.birthRate ?? 0)
        thrusterTrail?.birthRate = curRate + (targetTrailRate - curRate) * CGFloat(min(1, dt * 5))

        // Trail + exhaust colour: dim → red glow → blue-white at max speed
        // spdT 0.0 = idle (dim), 0.5 = mid (red/orange), 1.0 = max (blue-white)
        let trR: CGFloat, trG: CGFloat, trB: CGFloat
        if spdT < 0.5 {
            let t = spdT / 0.5  // 0→1 over first half
            trR = 0.20 + t * 0.80   // dim → bright red
            trG = 0.15 + t * 0.10   // stays low
            trB = 0.15 - t * 0.05   // stays low
        } else {
            let t = (spdT - 0.5) / 0.5  // 0→1 over second half
            trR = 1.00 - t * 0.60   // red fades
            trG = 0.25 + t * 0.55   // green rises
            trB = 0.10 + t * 0.90   // blue rises strongly
        }
        let trA = 0.15 + spdT * 0.30
        thrusterTrail?.particleColor = UIColor(red: trR, green: trG, blue: trB, alpha: trA)
        thrusterTrail?.particleSize = CGFloat(0.03 + Float(spdT) * 0.04)

        // Exhaust bell + core: same dim → red → blue-white ramp, increasing emission
        let bellS = 0.3 + spdT * 1.4
        let coreS = 0.2 + spdT * 1.8
        for m in exhaustBellMats {
            m.emission.contents = UIColor(red: trR * bellS, green: trG * bellS, blue: trB * bellS, alpha: 1)
            m.diffuse.contents = UIColor(red: trR * 0.30, green: trG * 0.30, blue: trB * 0.30, alpha: 1)
        }
        for m in exhaustCoreMats {
            m.emission.contents = UIColor(red: trR * coreS, green: trG * coreS, blue: trB * coreS, alpha: 1)
            m.diffuse.contents = UIColor(red: trR * 0.30, green: trG * 0.30, blue: trB * 0.30, alpha: 1)
        }

        // Dynamic fog — shifts warmer in tight curves (race), tightens at high speed for performance
        if mode == .race {
            let curveIntensity = curvature(worldZ)
            currentFogLerp += (curveIntensity - currentFogLerp) * min(1, dt * 2)
            fogColor = lerpColor(fogColorOpen, fogColorDense, currentFogLerp)
        }
        // Performance: pull fog closer at high speeds (motion blur hides the cull boundary)
        let speedPct = abs(forwardSpeed) / effectiveMaxBoost
        if mode == .openWorld {
            let baseFogEnd: Float = 4200
            let highSpeedFog = baseFogEnd - speedPct * 1200  // tighter at speed
            fogEndDistance = CGFloat(max(2400, highSpeedFog))
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

    var boostFraction: Float { 1.0 }  // always full — unlimited boost
    private var boostHeld: Bool = false

    func setBoostHeld(_ held: Bool) {
        let wasHeld = boostHeld
        boostHeld = held
        if held && !wasHeld {
            boostFOVKick = 8
            boostJustActivated = true
        }
    }

    // Legacy — kept for compatibility
    func triggerBoost() { setBoostHeld(true) }

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
