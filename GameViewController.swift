import UIKit
import SceneKit
import CoreMotion
import AVFoundation
import CoreHaptics

final class GameViewController: UIViewController {

    // MARK: - Config
    private let difficulty:   Difficulty
    private let mode:         GameMode
    private let quality:      GraphicsQuality

    private var prebuiltScene: SpeedBikeScene?

    init(difficulty: Difficulty, mode: GameMode, quality: GraphicsQuality, scene: SpeedBikeScene? = nil) {
        self.difficulty = difficulty; self.mode = mode; self.quality = quality
        self.prebuiltScene = scene
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Properties
    private var scnView   = SCNView()
    private var gameScene: SpeedBikeScene!
    private let motion    = CMMotionManager()
    private var lastTime: TimeInterval = 0
    private var isThrottling = false
    private var isBraking    = false
    private var hudUpdatePending = false
    private var boostSatTimer: Float = 0
    private var liftBaseline: Float?

    private lazy var boostButton:    UIButton = makeBoostButton()
    private lazy var throttleButton: UIButton = makeThrottleButton()
    private lazy var brakeButton:    UIButton = makeBrakeButton()
    private lazy var menuButton:     UIButton = makeMenuButton()
    private lazy var timerLabel:      UILabel  = makeTimerLabel()
    private lazy var finishOverlay:   UIView   = makeFinishOverlay()
    private lazy var finishTimeLabel: UILabel  = UILabel()
    private lazy var bestTimeLabel:   UILabel  = UILabel()
    private lazy var crashOverlay:    UIView   = makeCrashOverlay()
    private weak var crashTryAgainBtn: UIButton?
    private lazy var speedBar:        UIView   = makeSpeedBar()
    private lazy var speedLabel:      UILabel  = makeSpeedLabel()
    private var speedBarFill = UIView()
    private let boostRing = CAShapeLayer()
    private lazy var loadingLabel: UILabel = {
        let l = UILabel(); l.text = "LOADING..."
        l.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        l.textColor = UIColor(red: 0.35, green: 0.65, blue: 0.45, alpha: 0.80)
        l.textAlignment = .center; return l
    }()
    private var levelHasBeenReady = false

    // Split time
    private lazy var splitLabel: UILabel = {
        let l = UILabel(); l.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        l.textAlignment = .center; l.alpha = 0; return l
    }()
    private var bestSplits: [Float] = []

    // Near-miss flash
    private lazy var nearMissEdge: UIView = {
        let v = UIView(); v.isUserInteractionEnabled = false
        v.layer.borderColor = UIColor(red: 1.0, green: 0.95, blue: 0.5, alpha: 0.6).cgColor
        v.layer.borderWidth = 0; v.alpha = 0; return v
    }()

    // MARK: - Audio
    private let audioEngine  = AVAudioEngine()
    private let audioState   = AudioState()
    private var hapticEngine: CHHapticEngine?
    private var continuousHapticPlayer: CHHapticAdvancedPatternPlayer?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupView(); setupScene(); setupMotion(); setupHUD(); setupAudio(); setupHaptics(); setupCallbacks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scnView.isPlaying = false
        motion.stopDeviceMotionUpdates()
        audioEngine.stop()
        stopContinuousHaptic()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scnView.isPlaying = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scnView.frame = view.bounds
        let b = view.bounds
        boostButton.frame    = CGRect(x: b.maxX - 90, y: b.maxY - 86, width: 68, height: 68)
        throttleButton.frame = CGRect(x: b.maxX - 176, y: b.maxY - 80, width: 58, height: 58)
        brakeButton.frame    = CGRect(x: b.minX + 20,  y: b.maxY - 80, width: 58, height: 58)
        menuButton.frame     = CGRect(x: b.minX + 12,  y: b.minY + 10, width: 46,  height: 36)
        timerLabel.frame     = CGRect(x: b.midX - 110, y: b.minY + 14, width: 220, height: 34)
        let ow: CGFloat = 320; let oh: CGFloat = 260
        finishOverlay.frame  = CGRect(x: b.midX - ow/2, y: b.midY - oh/2, width: ow, height: oh)
        let cw: CGFloat = 340; let ch: CGFloat = 190
        crashOverlay.frame   = CGRect(x: b.midX - cw/2, y: b.midY - ch/2, width: cw, height: ch)
        speedBar.frame       = CGRect(x: b.maxX - 28, y: b.midY - 60, width: 10, height: 120)
        loadingLabel.frame   = CGRect(x: b.midX - 100, y: b.midY - 12, width: 200, height: 24)
        splitLabel.frame     = CGRect(x: b.midX - 80, y: b.minY + 46, width: 160, height: 28)
        nearMissEdge.frame   = b
        speedLabel.frame     = CGRect(x: b.maxX - 54, y: b.midY + 64, width: 62, height: 18)
        // Boost ring tracks the boost button
        let ringPath = UIBezierPath(arcCenter: CGPoint(x: 34, y: 34), radius: 37,
                                     startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        boostRing.path = ringPath.cgPath
    }

    // MARK: - Setup
    private func setupView() {
        view.backgroundColor = .black
        scnView.frame = view.bounds; scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.antialiasingMode = quality.msaaMode
        scnView.preferredFramesPerSecond = 60; scnView.backgroundColor = .black
        scnView.alpha = 0  // hidden until level trees are ready
        view.addSubview(scnView)
    }

    private func setupScene() {
        gameScene = prebuiltScene ?? SpeedBikeScene(difficulty: difficulty, mode: mode, quality: quality)
        prebuiltScene = nil
        scnView.scene = gameScene; scnView.pointOfView = gameScene.cameraNode
        scnView.delegate = self; scnView.isPlaying = true
    }

    private func setupMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 120.0; motion.startDeviceMotionUpdates()
    }

    private func setupHUD() {
        view.addSubview(timerLabel)
        view.addSubview(throttleButton); view.addSubview(brakeButton)
        view.addSubview(boostButton); view.addSubview(menuButton)
        view.addSubview(speedBar); view.addSubview(speedLabel)
        view.addSubview(loadingLabel)
        view.addSubview(splitLabel)
        view.addSubview(nearMissEdge)
        // Hide gameplay controls until level is ready
        throttleButton.alpha = 0; brakeButton.alpha = 0; boostButton.alpha = 0
        speedBar.alpha = 0; speedLabel.alpha = 0; timerLabel.alpha = 0
        // Boost energy ring around the boost button
        boostRing.fillColor = nil
        boostRing.strokeColor = UIColor(red: 0.30, green: 0.75, blue: 1.0, alpha: 0.85).cgColor
        boostRing.lineWidth = 3.5
        boostRing.lineCap = .round
        boostRing.strokeEnd = 1.0
        boostButton.layer.addSublayer(boostRing)
        view.addSubview(finishOverlay); finishOverlay.isHidden = true
        view.addSubview(crashOverlay); crashOverlay.isHidden = true
    }

    private func setupHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        hapticEngine = try? CHHapticEngine()
        try? hapticEngine?.start()
        startContinuousHaptic()
    }

    private func startContinuousHaptic() {
        guard let engine = hapticEngine else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
        ], relativeTime: 0, duration: 300)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []) else { return }
        continuousHapticPlayer = try? engine.makeAdvancedPlayer(with: pattern)
        try? continuousHapticPlayer?.start(atTime: CHHapticTimeImmediate)
    }

    private func stopContinuousHaptic() {
        try? continuousHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        continuousHapticPlayer = nil
    }

    private func setupCallbacks() {
        gameScene.onCrash = { [weak self] in
            self?.playCrashHaptic()
            self?.doCrashShake()
        }
        gameScene.onNearMiss = { [weak self] closeness in
            guard let self = self else { return }
            self.playHaptic(intensity: closeness * 0.6, sharpness: 0.3)
            self.doNearMissFlash(intensity: closeness)
        }
        gameScene.onCheckpoint = { [weak self] index, time in
            self?.showSplit(index: index, time: time)
        }
        gameScene.onTreeSmashed = { [weak self] intensity in
            // Bigger trees = stronger haptic + camera shake
            self?.playHaptic(intensity: 0.3 + intensity * 0.6, sharpness: 0.5 + intensity * 0.4)
            if intensity > 0.3 { self?.doSmashShake(intensity: intensity) }
        }
        // Load best splits
        if let data = UserDefaults.standard.array(forKey: splitKey()) as? [Float] {
            bestSplits = data
        }
    }

    private func splitKey() -> String {
        "\(mode == .race ? "race" : "inf")_\(difficulty.rawValue)_splits"
    }

    private func makeThrottleButton() -> UIButton {
        let btn = UIButton(type: .custom)
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let icon = UIImage(systemName: "arrowtriangle.up.fill", withConfiguration: cfg)
        btn.setImage(icon, for: .normal)
        btn.tintColor = UIColor(red: 0.30, green: 0.88, blue: 0.50, alpha: 0.90)
        btn.backgroundColor = UIColor(red: 0.04, green: 0.10, blue: 0.06, alpha: 0.65)
        btn.layer.cornerRadius  = 29
        btn.layer.borderWidth   = 1.0
        btn.layer.borderColor   = UIColor(red: 0.28, green: 0.78, blue: 0.45, alpha: 0.35).cgColor
        btn.layer.shadowColor   = UIColor(red: 0.18, green: 0.70, blue: 0.35, alpha: 1).cgColor
        btn.layer.shadowRadius  = 10; btn.layer.shadowOpacity = 0.35; btn.layer.shadowOffset = .zero
        btn.addTarget(self, action: #selector(throttleDown), for: .touchDown)
        btn.addTarget(self, action: #selector(throttleDown), for: .touchDragInside)
        btn.addTarget(self, action: #selector(throttleUp),   for: .touchUpInside)
        btn.addTarget(self, action: #selector(throttleUp),   for: .touchUpOutside)
        btn.addTarget(self, action: #selector(throttleUp),   for: .touchCancel)
        return btn
    }

    private func makeBrakeButton() -> UIButton {
        let btn = UIButton(type: .custom)
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let icon = UIImage(systemName: "arrowtriangle.down.fill", withConfiguration: cfg)
        btn.setImage(icon, for: .normal)
        btn.tintColor = UIColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 0.90)
        btn.backgroundColor = UIColor(red: 0.12, green: 0.04, blue: 0.02, alpha: 0.65)
        btn.layer.cornerRadius  = 29
        btn.layer.borderWidth   = 1.0
        btn.layer.borderColor   = UIColor(red: 0.85, green: 0.35, blue: 0.18, alpha: 0.35).cgColor
        btn.layer.shadowColor   = UIColor(red: 0.85, green: 0.28, blue: 0.10, alpha: 1).cgColor
        btn.layer.shadowRadius  = 10; btn.layer.shadowOpacity = 0.30; btn.layer.shadowOffset = .zero
        btn.addTarget(self, action: #selector(brakeDown), for: .touchDown)
        btn.addTarget(self, action: #selector(brakeDown), for: .touchDragInside)
        btn.addTarget(self, action: #selector(brakeUp),   for: .touchUpInside)
        btn.addTarget(self, action: #selector(brakeUp),   for: .touchUpOutside)
        btn.addTarget(self, action: #selector(brakeUp),   for: .touchCancel)
        return btn
    }

    private func makeMenuButton() -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle("≡", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 20, weight: .light)
        btn.setTitleColor(UIColor(white: 1.0, alpha: 0.55), for: .normal)
        btn.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.18, alpha: 0.55)
        btn.layer.cornerRadius = 10
        btn.layer.borderWidth  = 0.8
        btn.layer.borderColor  = UIColor(white: 1.0, alpha: 0.15).cgColor
        btn.addTarget(self, action: #selector(menuPressed), for: .touchUpInside)
        return btn
    }

    private func setupAudio() {
        let outputFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        let sampleRate   = outputFormat.sampleRate
        let format       = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let state        = audioState
        // Sci-fi hover engine — dual detuned oscillators + sub-bass throb + pulse modulation
        let srcNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let spd: Double  = Double(state.speed)
            let boost: Double = state.boostPitchOffset
            let baseHz: Double = (48.0 + spd * 65.0) * (1.0 + boost)
            let pdt1: Double = baseHz / sampleRate
            let pdt2: Double = (baseHz * 1.007) / sampleRate
            let subHz: Double = (22.0 + spd * 18.0) / sampleRate
            let vol: Double  = 0.14 + spd * 0.32
            let pulseRate: Double = 3.5 + spd * 8.0
            let ablPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                state.phase += pdt1; if state.phase >= 1.0 { state.phase -= 1.0 }
                state.phase2 += pdt2; if state.phase2 >= 1.0 { state.phase2 -= 1.0 }
                state.subPhase += subHz; if state.subPhase >= 1.0 { state.subPhase -= 1.0 }
                let p1: Double = state.phase * 2.0 * Double.pi
                let p2: Double = state.phase2 * 2.0 * Double.pi
                let ps: Double = state.subPhase * 2.0 * Double.pi
                // Osc 1: saw-ish
                var s: Double = sin(p1) * 0.28
                s += sin(p1 * 2.0) * 0.14
                s += sin(p1 * 3.0) * 0.08
                s += sin(p1 * 5.0) * 0.04
                // Osc 2: detuned
                s += sin(p2) * 0.22
                s += sin(p2 * 3.0) * 0.07
                s += sin(p2 * 5.0) * 0.03
                // Sub-bass throb
                let subAmp: Double = 0.10 + boost * 0.15
                s += sin(ps) * subAmp
                // Pulse amplitude modulation
                let pArg: Double = Double(frame) / sampleRate * pulseRate * 2.0 * Double.pi
                let pulse: Double = 0.80 + 0.20 * sin(pArg + state.phase * 40.0)
                s *= vol * pulse
                let sample = Float(s)
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    if frame < ptr.count { ptr[frame] = sample }
                }
            }
            return noErr
        }
        // Filtered turbine rush — bandpass-like filtered noise
        let windNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let spd: Double = Double(state.speed)
            let vol: Double = spd * spd * 0.09
            let lpfCoeff: Double = 0.92 - spd * 0.12
            let ablPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let noise: Double = Double.random(in: -1...1)
                let oneMinusLPF: Double = 1.0 - lpfCoeff
                state.windPhase = state.windPhase * lpfCoeff + noise * oneMinusLPF
                state.windLPF = state.windLPF * 0.85 + state.windPhase * 0.15
                let sample = Float(state.windLPF * vol)
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    if frame < ptr.count { ptr[frame] = sample }
                }
            }
            return noErr
        }

        audioEngine.attach(srcNode); audioEngine.attach(windNode)
        audioEngine.connect(srcNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.connect(windNode, to: audioEngine.mainMixerNode, format: format)
        do { try audioEngine.start() } catch { print("Audio start error: \(error)") }
    }

    // MARK: - HUD factories

    private func makeTimerLabel() -> UILabel {
        let l = UILabel(); l.text = "0:00.000"
        l.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        l.textColor = UIColor(red: 0.75, green: 0.95, blue: 1.0, alpha: 0.90)
        l.textAlignment = .center
        l.layer.shadowColor = UIColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1).cgColor
        l.layer.shadowRadius = 6; l.layer.shadowOpacity = 0.7; l.layer.shadowOffset = .zero
        return l
    }

    private func makeBoostButton() -> UIButton {
        let btn = UIButton(type: .custom)
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        btn.setImage(UIImage(systemName: "bolt.fill", withConfiguration: cfg), for: .normal)
        btn.tintColor = UIColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1)
        btn.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.18, alpha: 0.76)
        btn.layer.cornerRadius  = 34
        btn.layer.borderWidth   = 1.2
        btn.layer.borderColor   = UIColor(red: 0.30, green: 0.68, blue: 1.0, alpha: 0.68).cgColor
        btn.layer.shadowColor   = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1).cgColor
        btn.layer.shadowRadius  = 10; btn.layer.shadowOpacity = 0.55; btn.layer.shadowOffset = .zero
        btn.addTarget(self, action: #selector(boostPressed), for: .touchDown)
        return btn
    }

    private func makeFinishOverlay() -> UIView {
        let panel = UIView()
        panel.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 0.88)
        panel.layer.cornerRadius = 18
        panel.layer.borderWidth  = 1.5
        panel.layer.borderColor  = UIColor(red: 0.28, green: 0.80, blue: 0.50, alpha: 0.85).cgColor
        panel.layer.shadowColor  = UIColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1).cgColor
        panel.layer.shadowRadius = 16; panel.layer.shadowOpacity = 0.5; panel.layer.shadowOffset = .zero

        let titleStr = mode == .race ? "FINISH" : "STOPPED"
        let titleLbl = uiLabel(titleStr, size: 28, weight: .black, color: UIColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1))
        finishTimeLabel = uiLabel("--", size: 24, weight: .bold, color: .white)
        bestTimeLabel   = uiLabel("BEST  --", size: 12, weight: .semibold, color: UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 0.85))

        let raceAgain = actionBtn("↺  RACE AGAIN", #selector(resetPressed))
        let menuBtn   = actionBtn("≡  MENU",       #selector(menuPressed), secondary: true)

        let btnRow = UIStackView(arrangedSubviews: [raceAgain, menuBtn])
        btnRow.axis = .horizontal; btnRow.spacing = 12; btnRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [titleLbl, finishTimeLabel, bestTimeLabel, btnRow])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32),
        ])
        return panel
    }

    private func uiLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel(); l.text = text; l.font = .monospacedSystemFont(ofSize: size, weight: weight)
        l.textColor = color; l.textAlignment = .center; return l
    }

    private func actionBtn(_ title: String, _ action: Selector, secondary: Bool = false) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        ]))
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        cfg.cornerStyle = .fixed
        if secondary {
            cfg.baseBackgroundColor = UIColor(red: 0.08, green: 0.14, blue: 0.10, alpha: 0.7)
            cfg.baseForegroundColor = UIColor(red: 0.55, green: 0.88, blue: 0.70, alpha: 1)
        } else {
            cfg.baseBackgroundColor = UIColor(red: 0.28, green: 0.80, blue: 0.50, alpha: 1)
            cfg.baseForegroundColor = UIColor(red: 0.04, green: 0.08, blue: 0.14, alpha: 1)
        }
        let btn = UIButton(configuration: cfg)
        if secondary {
            btn.layer.borderWidth = 1.2
            btn.layer.borderColor = UIColor(red: 0.28, green: 0.80, blue: 0.50, alpha: 0.40).cgColor
        }
        btn.layer.cornerRadius = 10
        btn.heightAnchor.constraint(equalToConstant: 40).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func makeCrashOverlay() -> UIView {
        let panel = UIView()
        panel.backgroundColor = UIColor(red: 0.10, green: 0.03, blue: 0.02, alpha: 0.92)
        panel.layer.cornerRadius = 18
        panel.layer.borderWidth  = 1.5
        panel.layer.borderColor  = UIColor(red: 1.00, green: 0.30, blue: 0.10, alpha: 0.90).cgColor
        panel.layer.shadowColor  = UIColor(red: 1.00, green: 0.30, blue: 0.10, alpha: 1).cgColor
        panel.layer.shadowRadius = 18; panel.layer.shadowOpacity = 0.6; panel.layer.shadowOffset = .zero

        let titleLbl    = uiLabel("CRASHED!", size: 30, weight: .black,
                                  color: UIColor(red: 1.00, green: 0.40, blue: 0.10, alpha: 1))
        let subtitleLbl = uiLabel("Speeder destroyed", size: 13, weight: .regular,
                                  color: UIColor(white: 0.80, alpha: 0.70))
        let tryAgain = actionBtn("↺  TRY AGAIN", #selector(resetPressed))
        let menuBtn2 = actionBtn("≡  MENU",      #selector(menuPressed), secondary: true)
        crashTryAgainBtn = tryAgain

        let btnRow = UIStackView(arrangedSubviews: [tryAgain, menuBtn2])
        btnRow.axis = .horizontal; btnRow.spacing = 14; btnRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [titleLbl, subtitleLbl, btnRow])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -28),
        ])
        return panel
    }

    // MARK: - Speed bar
    private func makeSpeedBar() -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.15, alpha: 0.6)
        container.layer.cornerRadius = 5; container.layer.borderWidth = 0.8
        container.layer.borderColor = UIColor(white: 1.0, alpha: 0.2).cgColor
        speedBarFill.backgroundColor = UIColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 0.9)
        speedBarFill.layer.cornerRadius = 4
        container.addSubview(speedBarFill)
        return container
    }

    private func makeSpeedLabel() -> UILabel {
        let l = UILabel(); l.text = "0"
        l.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        l.textColor = UIColor(white: 1.0, alpha: 0.7); l.textAlignment = .center
        return l
    }

    // MARK: - Visual effects

    private func doNearMissFlash(intensity: Float) {
        nearMissEdge.layer.borderWidth = CGFloat(2 + intensity * 4)
        nearMissEdge.alpha = CGFloat(intensity * 0.7)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.nearMissEdge.alpha = 0
        }
    }

    private func showSplit(index: Int, time: Float) {
        let hasBest = index - 1 < bestSplits.count
        if hasBest {
            let bestTime = bestSplits[index - 1]
            let diff = time - bestTime
            if diff <= 0 {
                splitLabel.text = String(format: "-%.2fs", -diff)
                splitLabel.textColor = UIColor(red: 0.30, green: 0.90, blue: 0.45, alpha: 1)
            } else {
                splitLabel.text = String(format: "+%.2fs", diff)
                splitLabel.textColor = UIColor(red: 1.0, green: 0.40, blue: 0.25, alpha: 1)
            }
        } else {
            splitLabel.text = BestTimes.formatTime(time)
            splitLabel.textColor = UIColor(white: 0.9, alpha: 0.9)
        }
        splitLabel.alpha = 1; splitLabel.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        UIView.animate(withDuration: 0.2) { self.splitLabel.transform = .identity }
        UIView.animate(withDuration: 0.5, delay: 1.8, options: []) {
            self.splitLabel.alpha = 0
        }
        playHaptic(intensity: 0.4, sharpness: 0.6)
    }

    private func doCrashShake() {
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -12, 10, -8, 6, -3, 0]
        anim.duration = 0.4; anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scnView.layer.add(anim, forKey: "crashShake")
    }

    private func doSmashShake(intensity: Float) {
        let s = CGFloat(intensity)
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -6*s, 4*s, -2*s, 0]
        anim.duration = 0.2; anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scnView.layer.add(anim, forKey: "smashShake")
    }

    // MARK: - Haptics
    private func playHaptic(intensity: Float, sharpness: Float) {
        guard let engine = hapticEngine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: 0)
        try? engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: 0)
    }

    private func playCrashHaptic() {
        guard let engine = hapticEngine else { return }
        var events: [CHHapticEvent] = []
        for i in 0..<4 {
            let t = Double(i) * 0.08
            let intensity = Float(1.0 - Double(i) * 0.2)
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
            ], relativeTime: t))
        }
        try? engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: 0)
    }

    // MARK: - Actions
    @objc private func throttleDown() {
        isThrottling = true
        UIView.animate(withDuration: 0.08) { self.throttleButton.transform = CGAffineTransform(scaleX: 0.90, y: 0.90) }
        throttleButton.backgroundColor = UIColor(red: 0.06, green: 0.16, blue: 0.08, alpha: 0.80)
    }
    @objc private func throttleUp() {
        isThrottling = false
        UIView.animate(withDuration: 0.15) { self.throttleButton.transform = .identity }
        throttleButton.backgroundColor = UIColor(red: 0.04, green: 0.10, blue: 0.06, alpha: 0.65)
    }
    @objc private func brakeDown() {
        isBraking = true
        UIView.animate(withDuration: 0.08) { self.brakeButton.transform = CGAffineTransform(scaleX: 0.90, y: 0.90) }
        brakeButton.backgroundColor = UIColor(red: 0.18, green: 0.06, blue: 0.03, alpha: 0.80)
    }
    @objc private func brakeUp() {
        isBraking = false
        UIView.animate(withDuration: 0.15) { self.brakeButton.transform = .identity }
        brakeButton.backgroundColor = UIColor(red: 0.12, green: 0.04, blue: 0.02, alpha: 0.65)
    }

    @objc private func boostPressed() {
        guard gameScene.boostFraction > 0.15 else { return }
        gameScene.triggerBoost()
        playHaptic(intensity: 0.8, sharpness: 0.5)
        UIView.animate(withDuration: 0.06, animations: { self.boostButton.transform = CGAffineTransform(scaleX: 1.18, y: 1.18) },
                       completion: { _ in UIView.animate(withDuration: 0.10) { self.boostButton.transform = .identity } })
        boostSatTimer = 0.5  // smooth saturation pulse handled in render loop
    }

    @objc private func resetPressed() {
        crashTryAgainBtn?.isEnabled = true; crashTryAgainBtn?.alpha = 1.0
        gameScene.resetRace()
        resetLiftBaseline()
        finishOverlay.isHidden = true
        crashOverlay.isHidden = true; crashOverlay.alpha = 1.0
        timerLabel.text = "0:00.000"
    }

    @objc private func menuPressed() {
        dismiss(animated: false)
    }

    // MARK: - HUD update
    private func updateHUD() {
        hudUpdatePending = false

        // Show controls once level is ready
        if !levelHasBeenReady && gameScene.isLevelReady {
            levelHasBeenReady = true
            loadingLabel.isHidden = true
            UIView.animate(withDuration: 0.5) {
                self.scnView.alpha = 1  // reveal the fully-loaded scene
                self.throttleButton.alpha = 1; self.brakeButton.alpha = 1; self.boostButton.alpha = 1
                self.speedBar.alpha = 1; self.speedLabel.alpha = 1; self.timerLabel.alpha = 1
            }
        }

        // Speed bar (always visible during gameplay)
        let frac = CGFloat(gameScene.speedFraction)
        let barH = speedBar.bounds.height
        let fillH = max(2, barH * frac)
        speedBarFill.frame = CGRect(x: 1, y: barH - fillH - 1, width: speedBar.bounds.width - 2, height: fillH)
        if gameScene.isBoosting {
            speedBarFill.backgroundColor = UIColor(red: 1.0, green: 0.5, blue: 0.15, alpha: 0.95)
        } else if frac > 0.7 {
            speedBarFill.backgroundColor = UIColor(red: 1.0, green: 0.85, blue: 0.20, alpha: 0.9)
        } else {
            speedBarFill.backgroundColor = UIColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 0.9)
        }
        speedLabel.text = String(format: "%.0f", gameScene.currentSpeed)

        // Boost energy ring
        let energy = CGFloat(gameScene.boostFraction)
        boostRing.strokeEnd = energy
        if gameScene.isBoosting {
            boostRing.strokeColor = UIColor(red: 1.0, green: 0.5, blue: 0.15, alpha: 0.95).cgColor
        } else if energy < 0.15 {
            boostRing.strokeColor = UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5).cgColor
        } else {
            boostRing.strokeColor = UIColor(red: 0.30, green: 0.75, blue: 1.0, alpha: 0.85).cgColor
        }
        boostButton.alpha = energy < 0.15 ? 0.45 : 1.0

        switch gameScene.raceState {
        case .waiting:
            if mode == .openWorld {
                timerLabel.text = ""
            } else {
                timerLabel.text = "0:00.000"
            }
            finishOverlay.isHidden = true; crashOverlay.isHidden = true
        case .racing:
            if mode == .openWorld {
                timerLabel.text = ""
            } else {
                timerLabel.text = BestTimes.formatTime(gameScene.raceTime)
            }
            finishOverlay.isHidden = true; crashOverlay.isHidden = true
        case .finished:
            let score = gameScene.raceTime
            timerLabel.text = BestTimes.formatTime(score)
            if finishOverlay.isHidden && !gameScene.finishCamActive {
                BestTimes.save(score, difficulty, mode)
                let splits = gameScene.checkpointTimes
                if !splits.isEmpty {
                    let existing = UserDefaults.standard.array(forKey: splitKey()) as? [Float] ?? []
                    if existing.isEmpty || score < (BestTimes.get(difficulty, mode) ?? Float.greatestFiniteMagnitude) {
                        UserDefaults.standard.set(splits, forKey: splitKey())
                        bestSplits = splits
                    }
                }
                finishTimeLabel.text = BestTimes.formatTime(score)
                if let best = BestTimes.get(difficulty, mode) {
                    bestTimeLabel.text = "BEST  " + BestTimes.formatTime(best)
                }
                finishOverlay.isHidden = false
            }
        case .crashed:
            if crashOverlay.isHidden {
                crashTryAgainBtn?.isEnabled = true
                crashTryAgainBtn?.alpha = 1.0
                crashOverlay.alpha = 1.0
                crashOverlay.isHidden = false
            }
        }
    }

    // MARK: - Orientation
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    /// Returns -1 or +1 to flip gravity-based controls for current landscape orientation.
    private var landscapeSign: Float {
        guard let scene = view.window?.windowScene else { return 1 }
        return scene.interfaceOrientation == .landscapeLeft ? -1 : 1
    }
}

// MARK: - Audio state (class so it's safely captured by AVAudioSourceNode closure)
private final class AudioState {
    var phase: Double = 0
    var phase2: Double = 0      // detuned oscillator
    var subPhase: Double = 0    // sub-bass throb
    var speed: Float  = 0
    var windPhase: Double = 0
    var windLPF: Double = 0     // low-pass filtered wind
    var boostPitchOffset: Double = 0
}

// MARK: - SCNSceneRendererDelegate
extension GameViewController: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard lastTime != 0 else { lastTime = time; return }
        let dt = Float(min(time - lastTime, 1.0 / 20.0)); lastTime = time
        gameScene.update(dt: dt, steer: resolveSteer(), throttling: isThrottling, braking: isBraking, lift: resolveLift())
        audioState.speed = max(0, gameScene.currentSpeed) / 80.0

        // Boost engine pitch offset — spike on activate, spool down
        if gameScene.isBoosting {
            audioState.boostPitchOffset = min(0.35, audioState.boostPitchOffset + Double(dt) * 2.0)
        } else {
            audioState.boostPitchOffset = max(0, audioState.boostPitchOffset - Double(dt) * 0.7)
        }

        // Smooth boost saturation pulse
        if boostSatTimer > 0 {
            boostSatTimer = max(0, boostSatTimer - dt)
        }
        if let cam = gameScene.cameraNode.camera {
            let baseSat = Float(quality.saturation)
            let satBoost = boostSatTimer > 0 ? min(boostSatTimer * 1.5, 0.2) : Float(0)
            let targetSat = baseSat + satBoost
            let curSat = Float(cam.saturation)
            cam.saturation = CGFloat(curSat + (targetSat - curSat) * min(1, dt * 6))
        }

        // Continuous speed haptic — subtle rumble that scales with speed
        let speedHaptic = gameScene.speedFraction * gameScene.speedFraction * 0.22
        try? continuousHapticPlayer?.sendParameters(
            [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: speedHaptic, relativeTime: 0)],
            atTime: CHHapticTimeImmediate)

        if !hudUpdatePending { hudUpdatePending = true; DispatchQueue.main.async { self.updateHUD() } }
    }

    private func resolveSteer() -> Float {
        guard let grav = motion.deviceMotion?.gravity else { return 0 }
        // gravity.y flips between landscapeLeft/Right — landscapeSign corrects it
        return max(-1, min(1, Float(grav.y) * 1.8 * landscapeSign))
    }

    private func resolveLift() -> Float {
        guard let grav = motion.deviceMotion?.gravity else { return 0 }
        // gravity.z: tilting top edge toward you (screen faces ceiling) → positive z
        // This is orientation-independent, so no landscapeSign needed.
        let tilt = Float(grav.z)
        if liftBaseline == nil { liftBaseline = tilt }
        let delta = tilt - liftBaseline!
        let deadzone: Float = 0.06                  // ~3° before it kicks in
        guard delta > deadzone else { return 0 }
        return min(1, (delta - deadzone) * 2.5)     // smooth ramp up
    }

    func resetLiftBaseline() { liftBaseline = nil }
}
