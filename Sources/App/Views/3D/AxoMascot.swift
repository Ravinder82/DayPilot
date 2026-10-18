@preconcurrency import SceneKit
import SwiftUI

// MARK: - Mood + shared session

/// Mascot moods, bound to the session lifecycle by AppModel:
/// working on start/resume, idle on pause, think on stop.
/// (sleep and celebrate remain available for future bindings.)
enum MascotMood: String, CaseIterable, Sendable {
    case idle, working, celebrate, think, sleep
}

/// Registry of every live Axo stage (one per report window). A mood change
/// reaches all of them; each stage ticks its own instance on its renderer thread.
final class MascotSession {
    nonisolated(unsafe) static let shared = MascotSession()
    private var mascots: [AxoMascot] = []
    var mood: MascotMood = .idle
    private init() {}

    func register(_ mascot: AxoMascot) {
        mascots.append(mascot)
        mascot.mood = mood
    }

    func unregister(_ mascot: AxoMascot) {
        mascots.removeAll { $0 === mascot }
    }

    func setMood(_ mood: MascotMood) {
        self.mood = mood
        for mascot in mascots { mascot.mood = mood }
    }
}

// MARK: - Axo

/// "Axo" — the Cyber Axolotl mascot, loaded 1:1 from the exported GLB
/// (`Resources/axo.glb`, 26 meshes, PBR materials).
///
/// Animation architecture: every mood contributes (1) a *pose target* for the
/// pivots — smoothed through damped springs so hands, head and goggles carry
/// momentum and settle with a slight overshoot — plus (2) layered procedural
/// motion (breath bob, sway oscillators, gaze saccades, blinks) and (3) the
/// engine's mood-change boop spring, so switching states lands with a physical
/// bounce. The figure floats (levitation 0.2) over its contact shadow.
final class AxoMascot {

    /// The loaded model root (`MascotForge_Root`).
    let root: SCNNode

    /// Current mood. A change kicks the boop spring and retargets the pose
    /// springs, so every state transition moves like something was nudged.
    var mood: MascotMood = .idle {
        didSet {
            guard oldValue != mood else { return }
            boopVelocity += 0.22 * springStiffness  // engine's boop()
        }
    }

    // Named pivots from the export (the same ones the engine animates).
    private var bodyRoot: SCNNode?
    private var headPivot: SCNNode?
    private var gogglesPivot: SCNNode?
    private var goggleAssembly: SCNNode?   // the goggle frame + lenses
    private var goggleBaseZ: Float = 0.90
    private var leftArmPivot: SCNNode?
    private var rightArmPivot: SCNNode?
    private var eyesGroup: SCNNode?

    // MARK: Spring state (semi-implicit, substepped for stability)

    private struct Spring {
        var value: Float
        var velocity: Float = 0
    }

    private var goggleSpring = Spring(value: 0)
    private var armLeftSpring = Spring(value: 0)
    private var armRightSpring = Spring(value: 0)
    private var headYawSpring = Spring(value: 0)
    private var headPitchSpring = Spring(value: 0)
    private var headRollSpring = Spring(value: 0)

    /// Engine mood-change bounce (baked config: springStiffness 0.5).
    private let springStiffness: Double = 0.5
    private var boopOffset: Double = 0
    private var boopVelocity: Double = 0

    // MARK: Blink state (engine cadence, randomized with double-blink bursts)

    private var blinkTimer: Double = 0
    private var isBlinking = false
    private var blinkCountdown: Double = 3.6
    private var pendingDoubleBlink = false

    // MARK: Gaze saccades (the engine's cursor-tracking, re-pointed as curiosity)

    private var gazeTimer: Double = 0
    private var gazeYaw: Float = 0
    private var gazePitch: Float = 0

    // Baked config constants (BAKED_MASCOT_CONFIG).
    private let breathSpeed: Double = 2
    private let levitation: Double = 0.2

    init?(modelURL: URL?) {
        let url = modelURL ?? Self.modelFileURL()
        guard let loaded = try? GLBLoader.loadNodeTree(from: url) else { return nil }
        root = loaded
        root.name = "Axo"
        locatePivots()
    }

    /// Wraps a clone of the pipeline's one parsed tree. The clone shares the
    /// template's geometry and materials, so it also shares the compiled
    /// shaders — building a stage from this costs about a millisecond.
    init(template: SCNNode) {
        root = template.clone()
        root.name = "Axo"
        locatePivots()
    }

    /// The bundled GLB, with fallbacks for running unbundled (`swift run`, a
    /// repo checkout) where `Bundle.main` has no Resources directory.
    static func modelFileURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "axo", withExtension: "glb") {
            return bundled
        }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/axo.glb"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/axo.glb"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? URL(fileURLWithPath: "axo.glb")
    }

    private func locatePivots() {
        var byName: [String: SCNNode] = [:]
        root.enumerateHierarchy { node, _ in
            if let name = node.name { byName[name] = node }
        }
        bodyRoot = byName["bodyRoot"]
        headPivot = byName["headPivot"]
        gogglesPivot = byName["gogglesPivot"]
        leftArmPivot = byName["leftArmPivot"]
        rightArmPivot = byName["rightArmPivot"]
        // The eyes group exports unnamed: the headPivot's unnamed child with
        // exactly two holders (one per eye).
        eyesGroup = headPivot?.childNodes.first { $0.name == nil && $0.childNodes.count == 2 }
        // The goggle frame/bridge/lenses live in the one group under gogglesPivot.
        goggleAssembly = gogglesPivot?.childNodes.first
        goggleBaseZ = goggleAssembly.map { Float($0.position.z) } ?? 0.90
    }

    /// Bounds of the whole figure, for camera framing.
    var framing: (center: SCNVector3, radius: CGFloat) {
        let (minBound, maxBound) = root.boundingBox
        let center = SCNVector3(
            (minBound.x + maxBound.x) / 2,
            (minBound.y + maxBound.y) / 2,
            (minBound.z + maxBound.z) / 2
        )
        let span = SCNVector3(maxBound.x - minBound.x, maxBound.y - minBound.y, maxBound.z - minBound.z)
        let radius = max(span.x, max(span.y, span.z)) / 2
        return (center, radius)
    }

    /// Lowest point of the figure (the feet), for the contact shadow.
    var groundY: CGFloat { root.boundingBox.0.y }

    func setMood(_ mood: MascotMood) { self.mood = mood }

    // MARK: - Diagnostics (used by the offscreen wiring/health tests)

    /// Current pivot/eye state as a parseable string.
    func animationDebugState() -> String {
        func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
        let g = gogglesPivot.map { fmt(Float($0.eulerAngles.x)) } ?? "nil"
        let e = eyesGroup.map { fmt($0.simdScale.y) } ?? "nil"
        let y = bodyRoot.map { fmt(Float($0.position.y)) } ?? "nil"
        let al = leftArmPivot.map { fmt(Float($0.eulerAngles.z)) } ?? "nil"
        let ar = rightArmPivot.map { fmt(Float($0.eulerAngles.x)) } ?? "nil"
        let hy = headPivot.map { fmt(Float($0.eulerAngles.y)) } ?? "nil"
        return "gogglesRotX=\(g) eyesScaleY=\(e) bodyY=\(y) armLZ=\(al) armRX=\(ar) headYaw=\(hy) boop=\(fmt(Float(boopOffset)))"
    }

    /// True when every animated pivot holds a finite, sane transform.
    /// Catches the class of bug where a NaN orientation makes a part vanish.
    func pivotsFinite() -> Bool {
        let nodes = [bodyRoot, headPivot, gogglesPivot, goggleAssembly,
                     leftArmPivot, rightArmPivot, eyesGroup].compactMap { $0 }
        for node in nodes {
            let p = node.position, e = node.eulerAngles, s = node.simdScale
            for v in [p.x, p.y, p.z, e.x, e.y, e.z, CGFloat(s.x), CGFloat(s.y), CGFloat(s.z)] where !v.isFinite {
                return false
            }
            if abs(s.x) < 0.01 || abs(s.y) < 0.01 || abs(s.z) < 0.01 { return false }
        }
        return true
    }

    // MARK: - Tick

    func tick(delta: TimeInterval, elapsed: TimeInterval) {
        let dt = Float(min(delta, 0.1))
        let speed = breathSpeed
        let lev = levitation

        // --- Mood-change boop spring (engine tick, verbatim) ---
        boopOffset += boopVelocity * Double(dt)
        boopVelocity -= boopOffset * 18.0 * Double(dt)
        boopVelocity *= Double(1.0 - 0.14 * dt * 60)  // frame-rate aware 0.86 damp

        // --- Pose targets per mood (engine poses + the think pose) ---
        var targetGoggle: Float = 0
        var targetArmL: Float = 0
        var targetArmR: Float = 0
        var targetYaw: Float = 0
        var targetPitch: Float = 0
        var targetRoll: Float = 0
        var gazeFollow = false

        switch mood {
        case .idle:
            break
        case .working:
            targetGoggle = 0.44        // goggles drop onto the eyes
            targetArmL = 0.18
            targetArmR = -0.48
            targetPitch = 0.06         // slight focused lean-in
        case .celebrate:
            targetArmL = -0.62         // OUTWARD wave — positive tucks into the torso
            targetArmR = -0.85
            targetPitch = -0.05
        case .think:
            targetArmR = -0.78         // hand up at the chin
            targetRoll = -0.15         // pondering head tilt
            targetYaw = 0.22           // looking aside
            gazeFollow = true
        case .sleep:
            targetPitch = 0.15         // head nodded
        }

        // Springs: underdamped enough to overshoot a touch (physical feel).
        let h: Float = 1.0 / 120.0
        step(&goggleSpring, toward: targetGoggle, stiffness: 120, damping: 15, dt: dt, h: h)
        step(&armLeftSpring, toward: targetArmL, stiffness: 90, damping: 12, dt: dt, h: h)
        step(&armRightSpring, toward: targetArmR, stiffness: 90, damping: 12, dt: dt, h: h)
        step(&headYawSpring, toward: targetYaw, stiffness: 70, damping: 11, dt: dt, h: h)
        step(&headPitchSpring, toward: targetPitch, stiffness: 70, damping: 11, dt: dt, h: h)
        step(&headRollSpring, toward: targetRoll, stiffness: 70, damping: 11, dt: dt, h: h)

        // --- Gaze saccades: idle/think glance around in held fixations ---
        gazeTimer -= Double(dt)
        if gazeTimer <= 0 {
            gazeTimer = Double.random(in: 1.6...4.0)
            gazeYaw = Float.random(in: -0.14...0.14)
            gazePitch = Float.random(in: -0.05...0.05)
        }
        let gazeY: Float = gazeFollow ? gazeYaw : 0
        let gazeP: Float = gazeFollow ? gazePitch : 0

        // --- Blink: engine cadence with randomness and occasional double-blink ---
        blinkTimer += Double(dt)
        if isBlinking, blinkTimer >= 0.12 {
            isBlinking = false
            blinkTimer = 0
            if pendingDoubleBlink {
                pendingDoubleBlink = false
                blinkCountdown = Double.random(in: 0.40...0.75)
            } else {
                blinkCountdown = Double.random(in: 2.8...5.4)
            }
        } else if !isBlinking {
            blinkCountdown -= Double(dt)
            if blinkCountdown <= 0 {
                isBlinking = true
                blinkTimer = 0
                pendingDoubleBlink = Bool.random() && Bool.random()  // ~25%
            }
        }
        if let eyes = eyesGroup {
            let eyeTarget: Float = (isBlinking || mood == .sleep) ? 0.08 : 1.0
            eyes.simdScale.y = lerp(eyes.simdScale.y, eyeTarget, dt * 24)
        }

        // --- Compose body: levitation + mood bob + boop impulse ---
        let bob: Double
        let bodyRoll: Double
        let breathScale: Float
        switch mood {
        case .idle:
            bob = sin(elapsed * 2.2 * speed) * 0.04
            bodyRoll = sin(elapsed * 1.1 * speed) * 0.015
            breathScale = Float(sin(elapsed * 2.2 * speed) * 0.006)
        case .working:
            bob = sin(elapsed * 4.0 * speed) * 0.03
            bodyRoll = 0
            breathScale = Float(sin(elapsed * 4.0 * speed) * 0.005)
        case .celebrate:
            bob = abs(sin(elapsed * 5.8 * speed)) * 0.16
            bodyRoll = sin(elapsed * 5.8 * speed) * 0.06
            breathScale = Float(sin(elapsed * 5.8 * speed) * 0.008)
        case .think:
            bob = sin(elapsed * 2.6 * speed) * 0.04
            bodyRoll = 0
            breathScale = Float(sin(elapsed * 2.6 * speed) * 0.006)
        case .sleep:
            bob = sin(elapsed * 0.9) * 0.012
            bodyRoll = 0
            breathScale = Float(sin(elapsed * 0.9) * 0.004)
        }
        if let body = bodyRoot {
            body.position.y = CGFloat(lev + bob + boopOffset)
            body.eulerAngles.z = CGFloat(bodyRoll)
            body.simdScale = simd_float3(1, 1 + breathScale, 1)
        }

        // --- Compose head: spring pose + mood oscillators + gaze ---
        let yawOsc: Float
        let rollOsc: Float
        switch mood {
        case .idle:
            yawOsc = Float(sin(elapsed * 0.9 * speed) * 0.10)
            rollOsc = Float(cos(elapsed * 1.3 * speed) * 0.03)
        case .working:
            yawOsc = Float(sin(elapsed * 2.5 * speed) * 0.24)
            rollOsc = 0
        case .celebrate:
            yawOsc = Float(sin(elapsed * 3.8 * speed) * 0.18)
            rollOsc = 0
        case .think:
            yawOsc = Float(sin(elapsed * 1.8 * speed) * 0.05)
            rollOsc = Float(sin(elapsed * 1.8 * speed) * 0.04)
        case .sleep:
            yawOsc = 0
            rollOsc = 0
        }
        if let head = headPivot {
            head.eulerAngles = SCNVector3(
                headPitchSpring.value + gazeP,
                headYawSpring.value + yawOsc + gazeY,
                headRollSpring.value + rollOsc
            )
        }

        // --- Compose arms: spring pose + mood oscillators ---
        let armLOsc: Float
        let armROsc: Float
        switch mood {
        case .idle:
            armLOsc = Float(sin(elapsed * 2.2 * speed) * 0.06)
            armROsc = 0
        case .working:
            armLOsc = Float(sin(elapsed * 5.0 * speed) * 0.08)
            armROsc = 0
        case .celebrate:
            armLOsc = Float(sin(elapsed * 10.0 * speed) * 0.16)
            armROsc = Float(cos(elapsed * 8.0 * speed) * 0.18)
        case .think, .sleep:
            armLOsc = 0
            armROsc = 0
        }
        leftArmPivot?.eulerAngles = SCNVector3(0, 0, armLeftSpring.value + armLOsc)
        rightArmPivot?.eulerAngles = SCNVector3(armRightSpring.value + armROsc, 0, 0)

        // --- Compose goggles: spring rotation + arc lift over the forehead ---
        if let goggles = gogglesPivot {
            goggles.eulerAngles = SCNVector3(goggleSpring.value, 0, 0)
        }
        if let assembly = goggleAssembly {
            // Lift the frame outward at mid-sweep so it rides OVER the head
            // dome instead of clipping through it while travelling.
            let progress = min(max(goggleSpring.value / 0.44, 0), 1)
            let lift = Float(sin(Double(progress) * Double.pi)) * 0.16
            assembly.position.z = CGFloat(goggleBaseZ + lift)
        }
    }

    // MARK: - Physics helpers

    /// Semi-implicit Euler spring: a = k·(target − value) − d·velocity,
    /// substepped at a fixed rate so high stiffness stays stable.
    private func step(_ s: inout Spring, toward target: Float,
                      stiffness k: Float, damping d: Float, dt: Float, h: Float) {
        var remaining = dt
        while remaining > 0 {
            let stepSize = min(h, remaining)
            let a = (target - s.value) * k - s.velocity * d
            s.velocity += a * stepSize
            s.value += s.velocity * stepSize
            remaining -= stepSize
        }
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * min(max(t, 0), 1)
    }
}

// MARK: - Stage scene

/// Builds the scene Axo performs in: figure, contact shadow, camera, lights.
///
/// Deliberately *not* a member of `AxoStageView`. An `NSViewRepresentable` is
/// `@MainActor` by conformance, which would make scene building main-actor
/// isolated — and the whole point of `MascotPipeline` is to build and compile
/// a stage on a background queue during launch.
enum AxoStage {

    /// The stage camera, by name, so the warm-up renderer can point at it.
    static let cameraName = "axoStageCamera"

    /// The complete stage: figure, shadow, camera, warm softbox rig, and the
    /// image-based lighting environment the PBR materials reflect.
    static func buildScene(mascot: AxoMascot) -> SCNScene {
        build(mascot: mascot, full: true)
    }

    /// The same stage without image-based lighting and without the rim and
    /// bounce lights: what a window gets when it arrives before warm-up is done.
    static func buildLiteScene(mascot: AxoMascot) -> SCNScene {
        build(mascot: mascot, full: false)
    }

    private static func build(mascot: AxoMascot, full: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        if full {
            scene.lightingEnvironment.contents = StudioEnvironment.image
            scene.lightingEnvironment.intensity = 1.35
        }

        // Stage pivot: the figure's bounds center moves to the origin.
        let (center, radius) = mascot.framing
        let stage = SCNNode()
        stage.position = SCNVector3(-center.x, -center.y, -center.z)
        stage.addChildNode(mascot.root)
        scene.rootNode.addChildNode(stage)

        // Soft contact shadow just under the floating feet.
        let shadow = SCNNode(geometry: ShadowDeck.geometry)
        shadow.position = SCNVector3(0, mascot.groundY - center.y - 0.04, 0)
        shadow.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        scene.rootNode.addChildNode(shadow)

        // Camera: fov 44 per the baked config, whole figure in frame. The
        // margin also covers the levitation float plus the celebrate hop so
        // the head can never clip the top edge.
        let cam = SCNNode()
        cam.name = cameraName
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 44
        let distance = radius / CGFloat(tan((44.0 / 2) * Double.pi / 180)) * 1.34
        cam.position = SCNVector3(distance * 0.10, distance * 0.06, distance)
        cam.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cam)

        // Warm softbox rig (lightRig "warm"): cream key, amber rim, orange bounce.
        addLight(type: .omni,
                 color: NSColor(red: 1.0, green: 0.96, blue: 0.90, alpha: 1),
                 intensity: 1250, position: SCNVector3(2.2, 3.0, 3.5), to: scene)

        // The lite rig keeps the key so the figure is recognisably lit from the
        // first frame; the rim, bounce and ambient below are what it is missing.
        guard full else { return scene }

        addLight(type: .directional,
                 color: NSColor(red: 0.98, green: 0.75, blue: 0.14, alpha: 1),
                 intensity: 420, position: SCNVector3(-3.0, 2.5, -2.5),
                 looksAtOrigin: true, to: scene)

        addLight(type: .omni,
                 color: NSColor(red: 0.99, green: 0.73, blue: 0.46, alpha: 1),
                 intensity: 260, position: SCNVector3(0, -2.5, 2.0), to: scene)

        addLight(type: .ambient,
                 color: NSColor(white: 0.6, alpha: 1),
                 intensity: 170, position: SCNVector3(0, 0, 0), to: scene)

        return scene
    }

    private static func addLight(type: SCNLight.LightType, color: NSColor,
                                 intensity: CGFloat, position: SCNVector3,
                                 looksAtOrigin: Bool = false, to scene: SCNScene) {
        let node = SCNNode()
        let light = SCNLight()
        light.type = type
        light.color = color
        light.intensity = intensity
        node.light = light
        node.position = position
        if looksAtOrigin { node.look(at: SCNVector3(0, 0, 0)) }
        scene.rootNode.addChildNode(node)
    }
}

// MARK: - Stage view

/// SwiftUI stage for Axo in the debrief corner: transparent background, warm
/// softbox rig (lightRig "warm" from the baked config), soft contact shadow,
/// camera framed on the whole floating figure. Ticks every frame.
struct AxoStageView: NSViewRepresentable {

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isJitteringEnabled = false
        view.delegate = context.coordinator
        // Never blocks: a finished stage is adopted outright, otherwise the
        // cheap rig goes up now and is replaced the moment warm-up lands.
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        coordinator.retire(into: MascotPipeline.shared)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private(set) var stage: MascotPipeline.Stage?
        private var lastTime: TimeInterval?
        private var isInvalidated = false

        var mascot: AxoMascot? { stage?.mascot }

        /// Puts a stage on screen. A finished one is used as-is; otherwise the
        /// lite rig appears immediately and upgrades itself once warm-up has
        /// compiled the full rig.
        @MainActor
        func attach(to view: SCNView) {
            let pipeline = MascotPipeline.shared

            if let stage = pipeline.takeStage() {
                install(stage, to: view)
                return
            }

            if let lite = pipeline.makeLiteStage() {
                install(lite, to: view)
            }

            pipeline.whenWarmupFinished { [weak self, weak view] in
                guard let self, let view, !self.isInvalidated else { return }
                // Already on the full rig — another window took the pool first,
                // or this one got there before warm-up did.
                guard self.stage?.isFull != true else { return }
                guard let stage = pipeline.takeStage() else { return }
                self.install(stage, to: view)
            }
        }

        @MainActor
        private func install(_ stage: MascotPipeline.Stage, to view: SCNView) {
            if let previous = self.stage { MascotSession.shared.unregister(previous.mascot) }
            self.stage = stage
            MascotSession.shared.register(stage.mascot)
            view.scene = stage.scene
            lastTime = nil
        }

        /// Hands the stage back for reuse so the next window opens on a scene
        /// whose shaders are already compiled.
        @MainActor
        func retire(into pipeline: MascotPipeline) {
            isInvalidated = true
            guard let stage else { return }
            MascotSession.shared.unregister(stage.mascot)
            self.stage = nil
            pipeline.recycle(stage)
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let mascot = stage?.mascot else { return }
            if lastTime == nil { lastTime = time }
            let delta = max(0, min(time - (lastTime ?? time), 0.2))
            lastTime = time
            mascot.tick(delta: delta, elapsed: time)
        }
    }
}

// MARK: - Procedural studio dressing (shared)

/// Warm gradient used as the PBR lighting environment, approximating the
/// engine's PMREM softbox rig (cream key, amber rim, orange bounce).
///
/// Drawn with CoreGraphics rather than `NSImage.lockFocus`: the warm-up builds
/// it on a background thread, and the old path cost ~130 ms the first time it
/// ran during a layout pass.
enum StudioEnvironment {
    static let image: NSImage = {
        let width = 16, height = 128
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: NSSize(width: width, height: height)) }

        let colors = [
            NSColor(red: 1.0, green: 0.93, blue: 0.84, alpha: 1).cgColor,
            NSColor(red: 0.18, green: 0.20, blue: 0.27, alpha: 1).cgColor,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors, locations: [0, 1])!
        // CGContext's origin is bottom-left, so this runs cream at the feet up
        // to charcoal over the head — the same direction NSGradient's 90° gave.
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: CGFloat(height)),
                                   options: [])
        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }()
}

/// The soft elliptical contact shadow under the floating figure: an unlit
/// transparent plane with a radial-gradient stain (the engine's canvas shadow).
enum ShadowDeck {
    static let geometry: SCNGeometry = {
        let plane = SCNPlane(width: 2.1, height: 0.85)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        material.diffuse.contents = radialImage
        material.transparencyMode = .aOne
        material.writesToDepthBuffer = false
        plane.materials = [material]
        return plane
    }()

    private static let radialImage: NSImage = {
        let width = 256, height = 106
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: NSSize(width: width, height: height)) }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        let radius = CGFloat(width) / 2

        // One smooth falloff instead of the old stack of four flat ellipses:
        // denser at the feet, gone by the edge, no visible banding.
        let colors = [
            NSColor(white: 0, alpha: 0.58).cgColor,
            NSColor(white: 0, alpha: 0.30).cgColor,
            NSColor(white: 0, alpha: 0.08).cgColor,
            NSColor(white: 0, alpha: 0.0).cgColor,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors,
                                  locations: [0, 0.4, 0.72, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }()
}
