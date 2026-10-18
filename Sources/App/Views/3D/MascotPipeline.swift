import AppKit
import Foundation
import Metal
import SceneKit

/// Pays Axo's startup cost once, ahead of the first view that needs him.
///
/// Measured on `Resources/axo.glb` (1.4 MB, 60k triangles) on this machine:
///
/// | step                                 | cost           |
/// |--------------------------------------|----------------|
/// | read + parse the GLB                 | 30–70 ms cold  |
/// | SceneKit's first full frame          | 365–640 ms     |
/// | a later frame of the same scene      | ~2 ms          |
/// | a fresh full scene, shaders cached   | ~130 ms        |
/// | a fresh lite scene (no IBL / rim)    | ~2–17 ms       |
///
/// The 365–640 ms is not the model — parsing is cheap. It is shader compilation
/// for the 26 PBR materials *plus* the image-based lighting environment *plus*
/// the warm four-light rig, all deferred by SceneKit until the view first
/// draws. That is why Axo used to pop into an empty frame about a second after
/// the window appeared.
///
/// So the cost is paid once, off the main thread, started from `App.init`:
///
///  1. build the procedural stage imagery (CoreGraphics, so it is thread-safe),
///  2. parse the GLB once and keep the node tree as a reusable template,
///  3. build one complete stage and render a single 64-px frame offscreen,
///     which compiles every pipeline state and bakes the lighting environment,
///  4. keep that finished scene in a pool.
///
/// A stage asked for afterwards either pops the pool — no work at all — or,
/// while warm-up is still running, is built on the deliberately cheap lite rig
/// so there is never an empty box, and is upgraded in place the moment the
/// finished stage lands.
final class MascotPipeline: @unchecked Sendable {

    static let shared = MascotPipeline()

    /// A stage a view can adopt as-is: the figure and the scene it lives in.
    struct Stage {
        let mascot: AxoMascot
        let scene: SCNScene
        /// A finished warm rig (pooled and reused) or the cheap lite rig
        /// (shown only until the warm one is ready, then discarded).
        let isFull: Bool
    }

    // MARK: State

    private let lock = NSLock()
    private var template: SCNNode?
    private var pool: [Stage] = []
    private var isFinished = false
    private var didStart = false

    /// The pending `whenWarmupFinished` observers, boxed so the hand-off to the
    /// main thread is a send of a `Sendable` value. Every access stays inside
    /// `lock`.
    private final class Observers: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [@MainActor () -> Void] = []

        func append(_ block: @escaping @MainActor () -> Void) {
            lock.lock()
            items.append(block)
            lock.unlock()
        }

        func drain() -> [@MainActor () -> Void] {
            lock.lock()
            defer { lock.unlock() }
            let taken = items
            items = []
            return taken
        }
    }

    private let observers = Observers()

    /// Populated only for `--mascot-bench`, so the timings can be read back.
    /// `pooledAtFinish` is the count at the instant warm-up landed, not at
    /// report time — a window may already have adopted the stage by then,
    /// which is the whole point of it being ready.
    private(set) var timings: (parseMS: Double, buildMS: Double, compileMS: Double,
                               totalMS: Double, pooledAtFinish: Int)?

    private init() {}

    // MARK: Warm-up

    /// Idempotent, and safe to call before any window or view exists.
    func startWarmup() {
        lock.lock()
        guard !didStart else { lock.unlock(); return }
        didStart = true
        lock.unlock()

        let warmupStart = CFAbsoluteTimeGetCurrent()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 1 — the procedural imagery every stage reads. Built here once so
            //     the main thread never pays for it during a layout pass.
            _ = StudioEnvironment.image
            _ = ShadowDeck.geometry

            // 2 — one parse for the life of the process. Every stage clones this
            //     tree, which shares its geometry and materials, so a stage built
            //     later still hits the shader cache the warm frame populated.
            let parseStart = CFAbsoluteTimeGetCurrent()
            guard let parsed = try? GLBLoader.loadNodeTree(from: AxoMascot.modelFileURL()) else {
                finish(parseMS: 0, buildMS: 0, compileMS: 0, stage: nil, since: warmupStart)
                return
            }
            let parseMS = (CFAbsoluteTimeGetCurrent() - parseStart) * 1000
            lock.lock()
            template = parsed
            lock.unlock()

            // 3 — the expensive frame, once, away from the main thread.
            let buildStart = CFAbsoluteTimeGetCurrent()
            let stage = Self.makeStage(from: parsed, full: true)
            let buildMS = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000

            let compileStart = CFAbsoluteTimeGetCurrent()
            Self.compile(stage.scene)
            let compileMS = (CFAbsoluteTimeGetCurrent() - compileStart) * 1000

            finish(parseMS: parseMS, buildMS: buildMS, compileMS: compileMS,
                   stage: stage, since: warmupStart)
        }
    }

    /// Runs `block` on the main thread once warm-up is over, whether it produced
    /// a stage or not. Always asynchronous, so a view that arms this while it
    /// still has work to do cannot be re-entered from inside itself.
    @MainActor
    func whenWarmupFinished(_ block: @escaping @MainActor () -> Void) {
        lock.lock()
        if isFinished {
            lock.unlock()
            Task { @MainActor in block() }
            return
        }
        // Appended while still holding `lock`, so a `finish()` landing between
        // the check and the append cannot drain past this observer.
        observers.append(block)
        lock.unlock()
    }

    private func finish(parseMS: Double, buildMS: Double, compileMS: Double,
                        stage: Stage?, since start: CFAbsoluteTime) {
        lock.lock()
        if let stage { pool.append(stage) }
        timings = (parseMS, buildMS, compileMS,
                   (CFAbsoluteTimeGetCurrent() - start) * 1000, pool.count)
        isFinished = true
        lock.unlock()

        let callbacks = observers.drain()
        Task { @MainActor in callbacks.forEach { $0() } }
    }

    // MARK: Stages

    /// A finished stage for a view that is about to appear, if one is free.
    /// Popping an already-compiled scene is the whole fast path: no parsing, no
    /// shader compilation, no lighting environment to bake.
    func takeStage() -> Stage? {
        lock.lock()
        defer { lock.unlock() }
        guard !pool.isEmpty else { return nil }
        return pool.removeLast()
    }

    /// The cheap rig, for the window that arrives while warm-up is still running.
    /// Same figure, camera, contact shadow and key light — no image-based
    /// lighting environment, no rim or bounce — so the first frame costs single
    /// digit milliseconds and the mascot is never absent from the screen.
    func makeLiteStage() -> Stage? {
        lock.lock()
        let template = self.template
        lock.unlock()
        guard let template else { return nil }
        return Self.makeStage(from: template, full: false)
    }

    /// Hands a stage back for reuse. Only the finished warm rig is worth
    /// keeping; the lite rig exists to be replaced.
    func recycle(_ stage: Stage) {
        guard stage.isFull else { return }
        lock.lock()
        pool.append(stage)
        lock.unlock()
    }

    private static func makeStage(from template: SCNNode, full: Bool) -> Stage {
        let mascot = AxoMascot(template: template)
        let scene = full ? AxoStage.buildScene(mascot: mascot)
                         : AxoStage.buildLiteScene(mascot: mascot)
        return Stage(mascot: mascot, scene: scene, isFull: full)
    }

    /// Renders one small frame of the finished stage offscreen. SceneKit
    /// compiles the pipeline states and bakes the lighting environment as a
    /// side effect, so the real view's first frame afterwards is ~2 ms.
    private static func compile(_ scene: SCNScene) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = SCNRenderer(device: device)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: AxoStage.cameraName,
                                                        recursively: true)
        _ = renderer.snapshot(atTime: 0,
                              with: CGSize(width: 64, height: 64),
                              antialiasingMode: .none)
    }

    // MARK: --mascot-bench

    /// The measured warm-up breakdown. Driven by `--mascot-bench`, which also
    /// suppresses window creation.
    func report() -> String {
        lock.lock()
        let timings = self.timings
        lock.unlock()

        guard let timings else { return "mascot warm-up never finished" }
        return """
        Axo warm-up (all off the main thread, started at App.init)
          parse GLB ................. \(String(format: "%.1f", timings.parseMS)) ms
          build full stage .......... \(String(format: "%.1f", timings.buildMS)) ms
          offscreen first frame ..... \(String(format: "%.1f", timings.compileMS)) ms  (shader + lighting compile)
          total ..................... \(String(format: "%.1f", timings.totalMS)) ms
          stages ready when done .... \(timings.pooledAtFinish)

        A stage asked for afterwards:
          takeStage() ............... \(String(format: "%.2f", poolPeekMS())) ms  (pool hit, nothing to build)
          makeLiteStage() ........... \(String(format: "%.1f", liteBuildMS())) ms  (on-demand fallback, if the pool were empty)
        """
    }

    /// Times a pool pop, then hands the stage straight back — the bench must
    /// not consume what it is reporting on.
    private func poolPeekMS() -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        if let stage = takeStage() { recycle(stage) }
        return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }

    /// Times building the cheap rig on demand. Only ever called by the bench:
    /// in the real app it runs at the moment a window needs it.
    private func liteBuildMS() -> Double {
        lock.lock()
        let template = self.template
        lock.unlock()
        guard let template else { return -1 }
        let t = CFAbsoluteTimeGetCurrent()
        _ = Self.makeStage(from: template, full: false)
        return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }
}
