import SwiftUI
import WebKit

@main
struct SleepypodApp: App {
    @State private var deviceManager: DeviceManager
    @State private var scheduleManager: ScheduleManager
    @State private var metricsManager: MetricsManager
    @State private var statusManager: StatusManager
    @State private var settingsManager: SettingsManager
    @State private var updateChecker = UpdateChecker()
    @State private var podDiscovery = PodDiscovery()
    @State private var userProfile = UserProfile()
    @State private var sensorStream = SensorStreamService()
    @State private var notificationRelay = NotificationRelay()
    @State private var healthSync: HealthSyncService
    @State private var stageModels: StageModelStore
    @State private var watchMotion = WatchMotionReceiver()
    @State private var snoreCapture = SnoreCaptureService()

    init() {
        let client = APIBackend.current.createClient()
        let device = DeviceManager(api: client)
        let schedule = ScheduleManager(api: client)
        let metrics = MetricsManager(api: client)
        let status = StatusManager(api: client)
        let settings = SettingsManager(api: client)

        _deviceManager = State(initialValue: device)
        _scheduleManager = State(initialValue: schedule)
        _metricsManager = State(initialValue: metrics)
        _statusManager = State(initialValue: status)
        _settingsManager = State(initialValue: settings)
        // Wired here, not in a view task: a background-refresh launch syncs Health before any window appears,
        // and the receipt signature must already know which model stages the nights.
        let models = StageModelStore()
        let health = HealthSyncService()
        health.stageModels = models
        _stageModels = State(initialValue: models)
        _healthSync = State(initialValue: health)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(deviceManager)
                .environment(scheduleManager)
                .environment(metricsManager)
                .environment(statusManager)
                .environment(settingsManager)
                .environment(updateChecker)
                .environment(podDiscovery)
                .environment(userProfile)
                .environment(sensorStream)
                .environment(notificationRelay)
                .environment(healthSync)
                .environment(stageModels)
                .environment(watchMotion)
                .environment(snoreCapture)
                .preferredColorScheme(userProfile.appearance.colorScheme)
                .foregroundStyle(Theme.text1)
                .tint(Theme.text1)
                .task {
                    sensorStream.notificationRelay = notificationRelay
                    watchMotion.activate()
                }
                .task(id: deviceManager.isConnected) {
                    // Keep first-install setup focused on local network access.
                    if deviceManager.isConnected && !APIBackend.current.isDemo && !DebugRoute.marketingCapture {
                        await notificationRelay.requestPermission()
                    }
                }
        }
        .backgroundTask(.appRefresh(HealthSyncService.backgroundTaskID)) { [healthSync] in
            // Queue the next wake-up first so a sync that runs out of time doesn't end the chain.
            HealthSyncService.scheduleBackgroundSync()
            await healthSync.syncInBackground()
        }
    }
}

struct ContentView: View {
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodDiscovery.self) private var podDiscovery
    @Environment(SensorStreamService.self) private var sensorStream
    @Environment(ScheduleManager.self) private var scheduleManager
    @Environment(MetricsManager.self) private var metricsManager
    @Environment(StatusManager.self) private var statusManager
    @Environment(HealthSyncService.self) private var healthSync
    @Environment(UserProfile.self) private var profile
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = Self.initialTab
    @State private var showWelcome = false

    private static var initialTab: String {
        switch DebugRoute.current {
        case "schedule": "podschedule"
        case "sleep", "week", "weektrend", "month", "watch", "stages": "sleep"
        default: "temp"
        }
    }

    /// Outline glyphs in both states, as drawn in the source tab bar.
    private func tabLabel(_ title: String, _ symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).environment(\.symbolVariants, .none) }
    }

    private var isConnected: Bool {
        deviceManager.isConnected
    }

    private var isDemo: Bool {
        APIBackend.current.isDemo
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(value: "temp") {
                    TempScreen()
                } label: { tabLabel("Temp", "thermometer.medium") }
                Tab(value: "podschedule") {
                    if isConnected { PodPageTab(path: "/en/schedule") }
                    else { NavigationStack { DisconnectedTabView(tab: "Schedule", selectedTab: $selectedTab).settingsToolbar() } }
                } label: { tabLabel("Schedule", "calendar") }
                Tab(value: "sleep") {
                    if isConnected { SleepScreen() }
                    else { NavigationStack { DisconnectedTabView(tab: "Sleep", selectedTab: $selectedTab).settingsToolbar() } }
                } label: { tabLabel("Sleep", "moon") }
                Tab(value: "tonight") {
                    if isConnected { PodPageTab(path: "/en/tonight") }
                    else { NavigationStack { DisconnectedTabView(tab: "Tonight", selectedTab: $selectedTab).settingsToolbar() } }
                } label: { tabLabel("Tonight", "bed.double") }
                // The Pod's Base page: the base's position and the white noise its speaker plays.
                // It took the place of the app's own schedule screen ("Classic"); the Pod's Schedule tab replaced that.
                Tab(value: "base") {
                    if isConnected { PodPageTab(path: "/en/base") }
                    else { NavigationStack { DisconnectedTabView(tab: "Base", selectedTab: $selectedTab).settingsToolbar() } }
                } label: { Label { Text("Base") } icon: { Image(uiImage: BaseTabIcon.image) } }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .onChange(of: selectedTab) {
                Haptics.tap()
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToTempTab)) { notification in
                if let side = notification.object as? SideSelection {
                    deviceManager.selectedSide = side
                }
                selectedTab = "temp"
            }
            .onReceive(NotificationCenter.default.publisher(for: .leaveDemoMode)) { _ in leaveDemoMode() }

        }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeScreen(onConnect: {
                profile.onboardingComplete = true
                showWelcome = false
                deviceManager.startPolling()
            }, onDemo: {
                enterDemoMode()
            })
        }
        .task {
            deviceManager.selectSide(profile.defaultSide == .left ? .left : .right)
            scheduleManager.selectedSide = profile.defaultSide == .left ? .left : .right
            metricsManager.selectedSide = profile.defaultSide
            // Run setup until both onboarding steps are complete.
            if !profile.onboardingComplete && !isDemo {
                showWelcome = true
                return
            }

            // Demo mode — just fetch mock status, skip mDNS
            // Sensor demo stream starts automatically when Sensors tab is visited
            // via BedSensorScreen.onAppear -> connect() -> startDemoStream()
            if isDemo {
                await deviceManager.fetchStatus()
                deviceManager.startPolling()
                return
            }

            // Fetch once via startConnection, then hand off to polling. startPolling
            // detects the populated deviceStatus and skips its redundant first tick.
            await startConnection()
            deviceManager.startPolling()
        }
        .task(id: "\(scenePhase)-\(profile.defaultSide.rawValue)-\(healthSync.enabled)-\(healthSync.preferences.signature)-\(isConnected)-\(settingsManager.podIP)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if deviceManager.isConnected {
                    await healthSync.syncRecent(api: APIBackend.current.createClient(), podID: settingsManager.podID,
                                                side: profile.defaultSide, demo: isDemo)
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background && healthSync.enabled && !isDemo {
                HealthSyncService.scheduleBackgroundSync()
            }
        }
        .onChange(of: deviceManager.isConnected) {
            if deviceManager.isConnected {
                podDiscovery.status = .idle
                // Auto-dismiss welcome screen when connection succeeds
                sensorStream.connect()
            }
        }
        .onChange(of: sensorStream.latestDeviceStatus?.ts) { _, _ in
            if !isDemo, let status = sensorStream.latestDeviceStatus, sensorStream.isCurrentPod {
                deviceManager.applyWebSocketStatus(status)
                deviceManager.isReceivingWebSocket = true
            }
        }
        .onChange(of: sensorStream.isConnected) { _, connected in
            if !connected {
                deviceManager.isReceivingWebSocket = false
            }
        }
    }

    // MARK: - Connection Flow

    private func startConnection() async {
        // Probe the saved address alongside discovery so a DHCP change doesn't
        // cost a full request timeout before we can find the pod again.
        _ = await podDiscovery.autoConnect(settingsManager: settingsManager, deviceManager: deviceManager)
    }

    /// Back to the real backend and the setup flow, so the pod can be found again.
    private func leaveDemoMode() {
        APIBackend.current = .sleepypodCore
        let client = APIBackend.current.createClient()
        sensorStream.disconnect()
        deviceManager.switchBackend(client)
        settingsManager.switchBackend(client)
        scheduleManager.switchBackend(client)
        metricsManager.switchBackend(client)
        statusManager.switchBackend(client)
        profile.onboardingComplete = false
        showWelcome = true
    }

    private func enterDemoMode() {
        APIBackend.current = .demo
        let client = APIBackend.demo.createClient()
        deviceManager.switchBackend(client)
        settingsManager.switchBackend(client)
        scheduleManager.switchBackend(client)
        metricsManager.switchBackend(client)
        statusManager.switchBackend(client)
        sensorStream.disconnect()
        sensorStream.connect()
    }
}

/// A page from the Pod's own web app in a tab. It loads from the same server
/// the app talks to, so a change to the page needs no app update.
struct PodPageTab: View {
    @Environment(SettingsManager.self) private var settingsManager
    let path: String

    var body: some View {
        if let url = URL(string: "http://\(settingsManager.podIP):3000\(path)") {
            PodWebView(url: url)
        }
    }
}

struct PodWebView: UIViewRepresentable {
    let url: URL

    /// The web app's own tab bar would sit above the app's, so it's hidden here.
    private static let hideWebTabBar = WKUserScript(
        source: "var s=document.createElement('style');s.textContent='nav[aria-label=\"Main\"]{display:none!important}';(document.head||document.documentElement).appendChild(s);",
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(Self.hideWebTabBar)
        let view = FullPageWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // A new Pod address loads the page again; anything else keeps where the person is.
        if view.url?.host != url.host { view.load(URLRequest(url: url)) }
    }
}

/// A Pod page that also offers the whole scrolling page, as a PDF, under
/// Full Page in the screenshot editor, as Safari does. Choosing it is up to the person.
final class FullPageWebView: WKWebView, UIScreenshotServiceDelegate {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The page on screen answers; a tab out of view has no window and offers nothing.
        if let service = window?.windowScene?.screenshotService { service.delegate = self }
    }

    func screenshotService(
        _ screenshotService: UIScreenshotService,
        generatePDFRepresentationWithCompletion completionHandler: @escaping (Data?, Int, CGRect) -> Void
    ) {
        guard window != nil else { return completionHandler(nil, 0, .zero) }
        // Where the screen sits in the page, so the editor opens there. A PDF counts up from the bottom.
        let page = scrollView.contentSize.height
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let shown = CGRect(x: 0, y: max(0, page - top - bounds.height), width: bounds.width, height: bounds.height)
        createPDF(configuration: WKPDFConfiguration()) { result in
            completionHandler(try? result.get(), 0, shown)
        }
    }
}

/// "IN BED" or "NOT IN BED" as the Pod's presence detector has it: the one Smart start
/// and white noise act on, so the label says what the Pod believes. Until the Pod answers,
/// or on a Pod without the fork, it falls back to the live stream's guess.
struct InBedLabel: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var presence = PodPresence.shared
    let place: String
    let sides: [Side]
    let streamGuess: Bool

    var body: some View {
        let inBed = presence.inBed(sides) ?? streamGuess
        if inBed { StatusDot() }
        Eyebrow("\(place) · \(inBed ? "IN BED" : "NOT IN BED")")
            .task(id: scenePhase) {
                while !Task.isCancelled && scenePhase == .active {
                    await presence.refresh(podIP: settingsManager.podIP)
                    try? await Task.sleep(for: .seconds(20))
                }
            }
    }
}

/// Each side's in-bed state from the Pod's `fork.overview`, shared by every label.
@MainActor @Observable
final class PodPresence {
    static let shared = PodPresence()
    private var occupied: [Side: Bool] = [:]
    @ObservationIgnored private var lastAsked = Date.distantPast
    @ObservationIgnored private var failures = 0

    /// In bed when any of the sides is; nil while any of them is unknown.
    func inBed(_ sides: [Side]) -> Bool? {
        let known = sides.compactMap { occupied[$0] }
        return known.count == sides.count ? known.contains(true) : nil
    }

    /// Asks the Pod at most every 15 seconds, however many labels are on screen.
    func refresh(podIP: String) async {
        guard !APIBackend.current.isDemo else { return }
        guard Date().timeIntervalSince(lastAsked) >= 15 else { return }
        lastAsked = Date()
        guard let overview = await fetch(podIP: podIP) else {
            // One dropped request keeps the last answer; a Pod that stays silent leaves it to the guess.
            failures += 1
            if failures >= 2 { occupied = [:] }
            return
        }
        failures = 0
        // Readings that have stopped leave presence frozen at its last call, so they count as unknown.
        guard (overview["health"] as? [String: Any])?["sensorsFresh"] as? Bool == true else {
            occupied = [:]
            return
        }
        var next: [Side: Bool] = [:]
        for side in Side.allCases {
            let view = overview[side.rawValue] as? [String: Any]
            // The whole bed as Smart start counts it (either half on one big side); older Pods send only the side's own.
            let presence = (view?["bedPresence"] ?? view?["presence"]) as? [String: Any]
            if let value = presence?["occupied"] as? Bool { next[side] = value }
        }
        occupied = next
    }

    private func fetch(podIP: String) async -> [String: Any]? {
        guard let url = URL(string: "http://\(podIP):3000/api/trpc/fork.overview?input=%7B%22json%22%3A%7B%7D%7D"),
              let response = try? await URLSession.shared.data(from: url),
              let body = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let result = body["result"] as? [String: Any],
              let payload = result["data"] as? [String: Any] else { return nil }
        return payload["json"] as? [String: Any]
    }
}

/// The Base tab's icon: an adjustable base with its head raised, a slash, and a speaker,
/// for the base and the white noise its speaker plays. Drawn once as a template image.
enum BaseTabIcon {
    @MainActor static let image: UIImage = {
        let renderer = ImageRenderer(content: Glyph().frame(width: 46, height: 22))
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage(systemName: "bed.double") ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }()

    private struct Glyph: View {
        var body: some View {
            Lines().stroke(.black, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
    }

    /// In a 46 by 22 box: the base's deck and frame, the slash, then the speaker and its two waves.
    private struct Lines: Shape {
        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 46, sy = rect.height / 22
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
            var path = Path()
            path.addLines([p(2, 5), p(8, 13), p(16, 13), p(19, 11), p(22, 13)])
            path.addLines([p(3, 16), p(22, 16)])
            path.addLines([p(6, 16), p(6, 19)])
            path.addLines([p(19, 16), p(19, 19)])
            path.addLines([p(26, 19), p(30, 3)])
            path.addLines([p(34, 9), p(36.5, 9), p(40, 6), p(40, 16), p(36.5, 13), p(34, 13)])
            path.closeSubpath()
            path.move(to: p(42.2, 8.5))
            path.addQuadCurve(to: p(42.2, 13.5), control: p(43.7, 11))
            path.move(to: p(44, 6.8))
            path.addQuadCurve(to: p(44, 15.2), control: p(46.6, 11))
            return path
        }
    }
}
