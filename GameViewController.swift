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

    // MARK: - Audio
    private let audioEngine  = AVAudioEngine()
    private let audioState   = AudioState()
    private var hapticEngine: CHHapticEngine?

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
        speedLabel.frame     = CGRect(x: b.maxX - 54, y: b.midY + 64, width: 62, height: 18)
        // Boost ring tracks the boost button
        let ringPath = UIBezierPath(arcCenter: CGPoint(x: 34, y: 34), radius: 37,
                                     startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        boostRing.path = ringPath.cgPath
    }

    // MARK: - Setup
    private func setupView() {
        scnView.frame = view.bounds; scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.antialiasingMode = quality.msaaMode
        scnView.preferredFramesPerSecond = 60; scnView.backgroundColor = .black
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
    }

    private func setupCallbacks() {
        gameScene.onCrash = { [weak self] in
            // Already dispatched to main by triggerCrash
            self?.playCrashHaptic()
            self?.doCrashShake()
        }
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
        // Phase is tracked in CYCLES [0,1) to avoid discontinuity on wrap.
        // Idle hz ~55 Hz (above sub-bass); max hz ~125 Hz — clean engine tone range.
        let srcNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let spd  = Double(state.speed)
            let hz   = 55.0 + spd * 70.0         // 55 Hz idle → 125 Hz max boost
            let pdt  = hz / sampleRate            // cycles per sample
            let vol  = 0.18 + spd * 0.38
            let ablPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                state.phase += pdt
                if state.phase >= 1.0 { state.phase -= 1.0 }
                let p = state.phase * 2 * Double.pi
                var s = sin(p) * 0.42             // fundamental
                s += sin(p * 2) * 0.22            // 2nd harmonic
                s += sin(p * 3) * 0.10            // 3rd harmonic
                s += sin(p * 4) * 0.05            // 4th harmonic
                s *= vol
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    if frame < ptr.count { ptr[frame] = Float(s) }
                }
            }
            return noErr
        }
        // Wind noise layer — filtered noise that builds with speed
        let windNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let spd = Double(state.speed)
            let vol = spd * spd * 0.12  // quadratic ramp — only audible at higher speeds
            let ablPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // Simple filtered noise: LCG → low-pass via running average
                state.windPhase = state.windPhase * 0.97 + Double.random(in: -1...1) * 0.03
                let s = state.windPhase * vol
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    if frame < ptr.count { ptr[frame] = Float(s) }
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

    private func doCrashShake() {
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -12, 10, -8, 6, -3, 0]
        anim.duration = 0.4; anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scnView.layer.add(anim, forKey: "crashShake")
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
        guard gameScene.boostFraction > 0.15 else { return }  // not enough energy
        gameScene.triggerBoost()
        playHaptic(intensity: 0.8, sharpness: 0.5)
        UIView.animate(withDuration: 0.06, animations: { self.boostButton.transform = CGAffineTransform(scaleX: 1.18, y: 1.18) },
                       completion: { _ in UIView.animate(withDuration: 0.10) { self.boostButton.transform = .identity } })
    }

    @objc private func resetPressed() {
        crashTryAgainBtn?.isEnabled = true; crashTryAgainBtn?.alpha = 1.0
        gameScene.resetRace()
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
            UIView.animate(withDuration: 0.4) {
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
            timerLabel.text = "0:00.000"; finishOverlay.isHidden = true; crashOverlay.isHidden = true
        case .racing:
            timerLabel.text = mode == .race ? BestTimes.formatTime(gameScene.raceTime)
                                            : String(format: "%.0f m", gameScene.distanceCovered)
            finishOverlay.isHidden = true; crashOverlay.isHidden = true
        case .finished:
            let score = gameScene.raceTime
            timerLabel.text = BestTimes.formatTime(score)
            if finishOverlay.isHidden {
                BestTimes.save(score, difficulty, mode)
                finishTimeLabel.text = mode == .race ? BestTimes.formatTime(score)
                                                     : String(format: "%.1f km", gameScene.distanceCovered / 1000)
                if let best = BestTimes.get(difficulty, mode) {
                    bestTimeLabel.text = "BEST  " + (mode == .race ? BestTimes.formatTime(best)
                                                                   : String(format: "%.1f km", best / 1000))
                }
                finishOverlay.isHidden = false
            }
        case .crashed:
            if crashOverlay.isHidden {
                crashTryAgainBtn?.isEnabled = false
                crashTryAgainBtn?.alpha = 0.35
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.gameScene.raceState == .crashed else { return }
                    UIView.animate(withDuration: 0.25) { self.crashOverlay.alpha = 1.0 }
                    self.crashOverlay.isHidden = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.crashTryAgainBtn?.isEnabled = true
                        UIView.animate(withDuration: 0.3) { self?.crashTryAgainBtn?.alpha = 1.0 }
                    }
                }
                crashOverlay.alpha = 0
                crashOverlay.isHidden = false
            }
        }
    }

    // MARK: - Orientation
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}

// MARK: - Audio state (class so it's safely captured by AVAudioSourceNode closure)
private final class AudioState {
    var phase: Double = 0
    var speed: Float  = 0
    var windPhase: Double = 0
}

// MARK: - SCNSceneRendererDelegate
extension GameViewController: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard lastTime != 0 else { lastTime = time; return }
        let dt = Float(min(time - lastTime, 1.0 / 20.0)); lastTime = time
        gameScene.update(dt: dt, steer: resolveSteer(), throttling: isThrottling, braking: isBraking)
        audioState.speed = max(0, gameScene.currentSpeed) / 80.0
        if !hudUpdatePending { hudUpdatePending = true; DispatchQueue.main.async { self.updateHUD() } }
    }

    private func resolveSteer() -> Float {
        guard let grav = motion.deviceMotion?.gravity else { return 0 }
        return max(-1, min(1, Float(grav.y) * 1.8))
    }
}
