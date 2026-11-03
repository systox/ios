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
        case "schedule": "schedule"
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
                // The app's own schedule screen, kept until the web one above has replaced all of it.
                Tab(value: "schedule") {
                    if isConnected {
                        ScheduleScreen()
                    } else {
                        NavigationStack { DisconnectedTabView(tab: "Classic", selectedTab: $selectedTab).settingsToolbar() }
                    }
                } label: { tabLabel("Classic", "calendar.badge.clock") }
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // A new Pod address loads the page again; anything else keeps where the person is.
        if view.url?.host != url.host { view.load(URLRequest(url: url)) }
    }
}

/// White noise on or off from the Temp screen. Its settings live on the Tonight tab.
struct NoiseButton: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var on = false
    @State private var busy = false

    var body: some View {
        Button(on ? "Stop white noise" : "Play white noise", systemImage: on ? "speaker.wave.2.fill" : "speaker.slash") {
            Task { await toggle() }
        }
        .tint(on ? Theme.text1 : Theme.text2)
        .disabled(busy)
        .task(id: scenePhase) {
            // Noise can stop by itself or from the cover, so the button keeps checking while it's on screen.
            while !Task.isCancelled && scenePhase == .active {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func endpoint(_ procedure: String, query: String = "") -> URL? {
        URL(string: "http://\(settingsManager.podIP):3000/api/trpc/\(procedure)\(query)")
    }

    private func read(_ data: Data) -> Bool? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = body["result"] as? [String: Any],
              let payload = result["data"] as? [String: Any],
              let json = payload["json"] as? [String: Any] else { return nil }
        return json["on"] as? Bool
    }

    private func refresh() async {
        guard let url = endpoint("fork.noiseStatus", query: "?input=%7B%22json%22%3A%7B%7D%7D"),
              let response = try? await URLSession.shared.data(from: url),
              let state = read(response.0) else { return }
        on = state
    }

    private func toggle() async {
        guard let url = endpoint("fork.setNoise") else { return }
        busy = true
        defer { busy = false }
        // Act on what the Pod says now, not on what this button last saw.
        await refresh()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["json": ["on": !on]])
        if let response = try? await URLSession.shared.data(for: request), let state = read(response.0) {
            on = state
            Haptics.tap()
        }
    }
}
