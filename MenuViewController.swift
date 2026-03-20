import UIKit
import SceneKit

// MARK: - Shared game types (accessible across all files in module)

enum Difficulty: String, CaseIterable {
    case easy = "easy"
    var displayName: String { "EASY" }
    var treeDensity: Float  { 0.40 }
    var clearZone:   Float  { 16.0 }
}

enum GameMode { case race, infinite }

enum GraphicsQuality: String, CaseIterable {
    case low, medium, high
    var displayName: String { switch self { case .low: return "LOW"; case .medium: return "MED"; case .high: return "HIGH" } }

    static var saved: GraphicsQuality {
        get { GraphicsQuality(rawValue: UserDefaults.standard.string(forKey: "gfxQuality") ?? "medium") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gfxQuality") }
    }

    var msaaMode: SCNAntialiasingMode { switch self { case .low: return .none; case .medium: return .multisampling2X; case .high: return .multisampling4X } }
    var wantsHDR: Bool    { self != .low }
    var bloomIntensity:  CGFloat { switch self { case .low: return 0;    case .medium: return 2.2; case .high: return 3.8 } }
    var bloomThreshold:  CGFloat { switch self { case .low: return 1;    case .medium: return 0.52; case .high: return 0.38 } }
    var bloomBlurRadius: CGFloat { switch self { case .low: return 0;    case .medium: return 14;  case .high: return 22 } }
    var contrast:    CGFloat { switch self { case .low: return 0.18; case .medium: return 0.32; case .high: return 0.42 } }
    var saturation:  CGFloat { switch self { case .low: return 1.30; case .medium: return 1.50; case .high: return 1.60 } }
    var shadowsEnabled: Bool  { self != .low }
    var shadowMapSize:  CGSize { switch self { case .low: return .zero; case .medium: return CGSize(width: 1024, height: 1024); case .high: return CGSize(width: 2048, height: 2048) } }
    var shadowSamples:  Int   { switch self { case .low: return 1; case .medium: return 4; case .high: return 8 } }
    var treesCastShadows: Bool { self == .high }
    var streamRange:   Float { switch self { case .low: return 200; case .medium: return 260; case .high: return 330 } }
    var streamTrigger: Float { streamRange * 0.44 }
    var jungleDepth:   Float { switch self { case .low: return 25;  case .medium: return 55;  case .high: return 90  } }
    var jungleDensity: Float { switch self { case .low: return 0.60; case .medium: return 0.78; case .high: return 0.90 } }
    var bushesEnabled:    Bool  { self != .low }
    var bushDensityScale: Float { self == .high ? 1.0 : 0.70 }
}

struct BestTimes {
    private static func key(_ d: Difficulty, _ m: GameMode) -> String {
        "\(m == .race ? "race" : "inf")_\(d.rawValue)"
    }
    static func get(_ d: Difficulty, _ m: GameMode) -> Float? {
        let v = UserDefaults.standard.float(forKey: key(d, m))
        return v > 0 ? v : nil
    }
    static func save(_ value: Float, _ d: Difficulty, _ m: GameMode) {
        let k = key(d, m)
        let ex = UserDefaults.standard.float(forKey: k)
        let better = m == .infinite ? (ex == 0 || value > ex) : (ex == 0 || value < ex)
        if better { UserDefaults.standard.set(value, forKey: k) }
    }
    static func formatted(_ d: Difficulty, _ m: GameMode) -> String {
        guard let v = get(d, m) else { return "--" }
        if m == .race { return formatTime(v) }
        return String(format: "%.1f km", v / 1000)
    }
    static func formatTime(_ t: Float) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60; let ms = Int((t - Float(Int(t))) * 1000)
        return String(format: "%d:%02d.%03d", m, s, ms)
    }
}

// MARK: - Menu

/// Three full-screen panels navigated by tapping, not swiping.
/// Panel 0 = Title (home), Panel 1 = Game Select, Panel 2 = Settings
final class MenuViewController: UIViewController {

    private var selectedDifficulty: Difficulty      = .easy
    private var selectedMode:       GameMode        = .race
    private var selectedQuality:    GraphicsQuality = GraphicsQuality.saved
    private var modeButtons:        [GameMode: UIButton]        = [:]
    private var qualityButtons:     [GraphicsQuality: UIButton] = [:]
    private var bestLabel:          UILabel?
    private var selectionLabel:     UILabel?

    // Panels
    private var panels: [UIView] = []
    private var currentPanel = 0

    override func viewDidLoad()      { super.viewDidLoad(); buildUI() }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refreshBestLabel() }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: - UI construction

    private func buildUI() {
        let grad = CAGradientLayer()
        grad.frame = view.bounds; grad.startPoint = CGPoint(x: 0.5, y: 0); grad.endPoint = CGPoint(x: 0.5, y: 1)
        grad.colors = [
            UIColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1).cgColor,
            UIColor(red: 0.04, green: 0.12, blue: 0.10, alpha: 1).cgColor,
            UIColor(red: 0.02, green: 0.06, blue: 0.04, alpha: 1).cgColor,
        ]
        grad.locations = [0, 0.5, 1]
        view.layer.insertSublayer(grad, at: 0)
        addAmbientGlow()

        let p0 = buildTitlePanel()
        let p1 = buildGameSelectPanel()
        let p2 = buildSettingsPanel()
        panels = [p0, p1, p2]

        for p in panels {
            p.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: view.topAnchor),
                p.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                p.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                p.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        showPanel(0, animated: false)
        refreshModeButtons(); refreshQualityButtons()
        refreshSelectionLabel(); refreshBestLabel()
    }

    // MARK: - Panel builders

    private func buildTitlePanel() -> UIView {
        let panel = UIView()

        let titleLbl = label("SPEEDER", size: 44, weight: .black,
                             color: UIColor(red: 0.88, green: 0.96, blue: 1.0, alpha: 1))
        titleLbl.layer.shadowColor = UIColor(red: 0.20, green: 0.60, blue: 0.35, alpha: 1).cgColor
        titleLbl.layer.shadowRadius = 18; titleLbl.layer.shadowOpacity = 0.6; titleLbl.layer.shadowOffset = .zero

        let subtitleLbl = label("FOREST RUN", size: 11, weight: .semibold,
                                color: UIColor(red: 0.35, green: 0.65, blue: 0.45, alpha: 0.70))
        subtitleLbl.letterSpacing(6)

        let divider = UIView()
        divider.backgroundColor = UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: 0.25)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let selLbl = label("RACE", size: 12, weight: .semibold,
                           color: UIColor(red: 0.35, green: 0.85, blue: 0.50, alpha: 0.80))
        selectionLabel = selLbl

        let playBtn  = navButton("▶  PLAY",     action: #selector(goToGameSelect))
        let settBtn  = navButton("⚙  SETTINGS", action: #selector(goToSettings), secondary: true)

        let btnRow = UIStackView(arrangedSubviews: [playBtn, settBtn])
        btnRow.axis = .horizontal; btnRow.spacing = 12; btnRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [titleLbl, subtitleLbl, spacer(6), divider, spacer(6), selLbl, spacer(16), btnRow])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        return panel
    }

    private func buildGameSelectPanel() -> UIView {
        let panel = UIView()

        let pageTitle = label("GAME SELECT", size: 11, weight: .semibold,
                              color: UIColor(white: 0.42, alpha: 1))
        pageTitle.letterSpacing(3)

        let modeTitle = label("MODE", size: 10, weight: .semibold, color: UIColor(white: 0.5, alpha: 1))
        modeTitle.letterSpacing(3)
        let modeRow = UIStackView(); modeRow.axis = .horizontal; modeRow.spacing = 10
        for m in [GameMode.race, GameMode.infinite] {
            let btn = toggleBtn(m == .race ? "RACE" : "INFINITE", tag: m == .race ? 0 : 1,
                                action: #selector(modeTapped(_:)))
            modeButtons[m] = btn; modeRow.addArrangedSubview(btn)
        }

        // Best time label
        let bestLbl = label("--", size: 13, weight: .semibold,
                            color: UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 0.85))
        bestLabel = bestLbl

        let startBtn = makeStartButton()

        let backBtn = navButton("← BACK", action: #selector(goToTitle), secondary: true)
        backBtn.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let bottomRow = UIStackView(arrangedSubviews: [backBtn, startBtn])
        bottomRow.axis = .horizontal; bottomRow.spacing = 14

        let stack = UIStackView(arrangedSubviews: [
            pageTitle, spacer(10),
            modeTitle, modeRow, spacer(8),
            bestLbl, spacer(14),
            bottomRow,
        ])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        return panel
    }

    private func buildSettingsPanel() -> UIView {
        let panel = UIView()

        let pageTitle = label("SETTINGS", size: 11, weight: .semibold,
                              color: UIColor(white: 0.42, alpha: 1))
        pageTitle.letterSpacing(3)

        let qualTitle = label("GRAPHICS", size: 10, weight: .semibold, color: UIColor(white: 0.5, alpha: 1))
        qualTitle.letterSpacing(3)
        let qualRow = UIStackView(); qualRow.axis = .horizontal; qualRow.spacing = 10
        for q in GraphicsQuality.allCases {
            let btn = toggleBtn(q.displayName, tag: GraphicsQuality.allCases.firstIndex(of: q)!,
                                action: #selector(qualityTapped(_:)))
            qualityButtons[q] = btn; qualRow.addArrangedSubview(btn)
        }

        let backBtn = navButton("← BACK", action: #selector(goToTitle), secondary: true)

        let stack = UIStackView(arrangedSubviews: [pageTitle, spacer(14), qualTitle, qualRow, spacer(18), backBtn])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        return panel
    }

    // MARK: - Panel navigation

    private func showPanel(_ index: Int, animated: Bool) {
        guard index >= 0 && index < panels.count else { return }
        let incoming = panels[index]
        let outgoing = currentPanel < panels.count ? panels[currentPanel] : nil
        currentPanel = index

        if !animated {
            panels.forEach { $0.isHidden = true }
            incoming.isHidden = false; incoming.alpha = 1
            return
        }

        incoming.alpha = 0; incoming.isHidden = false
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseInOut) {
            incoming.alpha = 1
            outgoing?.alpha = 0
        } completion: { _ in
            outgoing?.isHidden = true; outgoing?.alpha = 1
        }
    }

    // MARK: - Button factories

    private func makeStartButton() -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "START"
        cfg.image = UIImage(systemName: "play.fill")
        cfg.imagePadding = 8
        cfg.imagePlacement = .leading
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        cfg.baseBackgroundColor = UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: 1)
        cfg.baseForegroundColor = UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1)
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 36, bottom: 12, trailing: 36)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming; out.font = .monospacedSystemFont(ofSize: 17, weight: .bold); return out
        }
        let btn = UIButton(configuration: cfg)
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        btn.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0; pulse.toValue = 1.03
        pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
        btn.layer.add(pulse, forKey: "pulse")
        return btn
    }

    private func navButton(_ title: String, action: Selector, secondary: Bool = false) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        ]))
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        cfg.cornerStyle = .fixed
        if secondary {
            cfg.baseBackgroundColor = UIColor(red: 0.08, green: 0.14, blue: 0.10, alpha: 0.7)
            cfg.baseForegroundColor = UIColor(red: 0.55, green: 0.88, blue: 0.70, alpha: 1)
        } else {
            cfg.baseBackgroundColor = UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: 1)
            cfg.baseForegroundColor = UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1)
        }
        let btn = UIButton(configuration: cfg)
        btn.layer.cornerRadius = 12
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if secondary {
            btn.layer.borderWidth = 1.2
            btn.layer.borderColor = UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: 0.38).cgColor
        }
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func toggleBtn(_ title: String, tag: Int, action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        ]))
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22)
        cfg.cornerStyle = .fixed
        let btn = UIButton(configuration: cfg)
        btn.layer.cornerRadius = 10; btn.layer.borderWidth = 1.5
        btn.tag = tag
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel(); l.text = text
        l.font = .monospacedSystemFont(ofSize: size, weight: weight)
        l.textColor = color; return l
    }

    private func spacer(_ h: CGFloat) -> UIView {
        let v = UIView(); v.heightAnchor.constraint(equalToConstant: h).isActive = true; return v
    }

    // MARK: - Ambient background

    private func addAmbientGlow() {
        let b = UIScreen.main.bounds
        // Soft green glow — bottom center
        let glow1 = UIView(frame: CGRect(x: b.midX - 200, y: b.maxY - 120, width: 400, height: 240))
        glow1.backgroundColor = UIColor(red: 0.12, green: 0.40, blue: 0.22, alpha: 0.18)
        glow1.layer.cornerRadius = 120; glow1.clipsToBounds = true
        glow1.layer.compositingFilter = "screenBlendMode"
        view.addSubview(glow1)
        // Subtle blue glow — top right
        let glow2 = UIView(frame: CGRect(x: b.maxX - 180, y: -60, width: 300, height: 200))
        glow2.backgroundColor = UIColor(red: 0.15, green: 0.30, blue: 0.55, alpha: 0.14)
        glow2.layer.cornerRadius = 100; glow2.clipsToBounds = true
        view.addSubview(glow2)
        // Breathing animation on the green glow
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0; breathe.toValue = 0.5
        breathe.duration = 3.0; breathe.autoreverses = true; breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow1.layer.add(breathe, forKey: "breathe")
    }

    // MARK: - State refresh

    private func refreshSelectionLabel() {
        let mode = selectedMode == .race ? "RACE" : "INFINITE"
        selectionLabel?.text = mode
    }

    private func refreshModeButtons() {
        for (m, btn) in modeButtons {
            let sel = m == selectedMode
            btn.configuration?.baseBackgroundColor = sel ? UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: 1)
                                                        : UIColor(red: 0.08, green: 0.14, blue: 0.10, alpha: 0.7)
            btn.configuration?.baseForegroundColor = sel ? UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1)
                                                        : UIColor(red: 0.55, green: 0.88, blue: 0.70, alpha: 1)
            btn.layer.borderColor = UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: sel ? 1 : 0.35).cgColor
        }
    }

    private func refreshQualityButtons() {
        for (q, btn) in qualityButtons {
            let sel = q == selectedQuality
            btn.configuration?.baseBackgroundColor = sel ? UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: 1)
                                                        : UIColor(red: 0.08, green: 0.14, blue: 0.10, alpha: 0.7)
            btn.configuration?.baseForegroundColor = sel ? UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1)
                                                        : UIColor(red: 0.55, green: 0.88, blue: 0.70, alpha: 1)
            btn.layer.borderColor = UIColor(red: 0.28, green: 0.82, blue: 0.50, alpha: sel ? 1 : 0.35).cgColor
        }
    }

    private func refreshBestLabel() {
        let best = BestTimes.formatted(.easy, selectedMode)
        bestLabel?.text = best == "--" ? "" : "BEST  \(best)"
    }

    // MARK: - Navigation actions

    @objc private func goToTitle()      { showPanel(0, animated: true) }
    @objc private func goToGameSelect() { showPanel(1, animated: true) }
    @objc private func goToSettings()  { showPanel(2, animated: true) }

    // MARK: - Selection actions

    @objc private func modeTapped(_ sender: UIButton) {
        selectedMode = sender.tag == 0 ? .race : .infinite
        refreshModeButtons(); refreshBestLabel(); refreshSelectionLabel()
    }

    @objc private func qualityTapped(_ sender: UIButton) {
        selectedQuality = GraphicsQuality.allCases[sender.tag]
        GraphicsQuality.saved = selectedQuality
        refreshQualityButtons()
    }

    @objc private func startTapped() {
        showLoadingScreen()
    }

    // MARK: - Loading screen

    private func showLoadingScreen() {
        let loadingView = UIView(frame: view.bounds)
        loadingView.backgroundColor = UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1)
        loadingView.tag = 999

        // Title
        let titleLbl = label("SPEEDER", size: 28, weight: .black,
                             color: UIColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1))
        titleLbl.textAlignment = .center

        // Loading indicator
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = UIColor(red: 0.30, green: 0.82, blue: 0.50, alpha: 1)
        spinner.startAnimating()

        let loadingLbl = label("GENERATING FOREST...", size: 10, weight: .semibold,
                               color: UIColor(red: 0.35, green: 0.65, blue: 0.45, alpha: 0.70))
        loadingLbl.letterSpacing(4); loadingLbl.textAlignment = .center

        let spinRow = UIStackView(arrangedSubviews: [spinner, loadingLbl])
        spinRow.axis = .horizontal; spinRow.spacing = 10; spinRow.alignment = .center

        // Mode info
        let modeName = selectedMode == .race ? "RACE" : "INFINITE"
        let infoLbl = label(modeName, size: 12, weight: .semibold,
                            color: UIColor(red: 0.35, green: 0.85, blue: 0.50, alpha: 0.60))
        infoLbl.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [titleLbl, infoLbl, spacer(24), spinRow])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
        ])

        // Fade in
        loadingView.alpha = 0
        view.addSubview(loadingView)
        UIView.animate(withDuration: 0.2) { loadingView.alpha = 1 }

        // Capture selections
        let diff = selectedDifficulty; let mode = selectedMode; let quality = selectedQuality

        // Build the scene (expensive) off-main, then present the VC on main
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = SpeedBikeScene(difficulty: diff, mode: mode, quality: quality)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let vc = GameViewController(difficulty: diff, mode: mode, quality: quality, scene: scene)
                vc.modalPresentationStyle = .fullScreen
                self.present(vc, animated: false) {
                    loadingView.removeFromSuperview()
                }
            }
        }
    }
}

private extension UILabel {
    func letterSpacing(_ spacing: CGFloat) {
        guard let t = text else { return }
        let attr = NSMutableAttributedString(string: t)
        attr.addAttribute(.kern, value: spacing, range: NSRange(location: 0, length: t.count))
        attributedText = attr
    }
}
