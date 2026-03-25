import SwiftUI
import UniformTypeIdentifiers
#if canImport(IdeaLibrarianCore)
import IdeaLibrarianCore
#endif

// MARK: - Pulsing Dots (processing indicator)

struct PulsingDots: View {
    @State private var phase = false
    private let cyan = Color(red: 0.0, green: 0.78, blue: 1.0)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(cyan.opacity(phase ? 0.85 : 0.2))
                    .frame(width: 7, height: 7)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .delay(Double(i) * 0.2)
                            .repeatForever(autoreverses: true),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}

// MARK: - Content View

struct ContentView: View {
    let engine: AtlasEngine
    @StateObject private var viewModel: ChatViewModel

    init(engine: AtlasEngine, userLibraryPath: String) {
        self.engine = engine
        self._viewModel = StateObject(wrappedValue: ChatViewModel(engine: engine, userLibraryPath: userLibraryPath))
    }

    // MARK: - Theme
    private let bgDark       = Color(red: 0.04,  green: 0.055, blue: 0.1)
    private let bgPanel      = Color(red: 0.055, green: 0.075, blue: 0.13)
    private let bgInput      = Color(red: 0.06,  green: 0.08,  blue: 0.15)
    private let msgUser      = Color(red: 0.09,  green: 0.125, blue: 0.22)
    private let msgAssistant = Color(red: 0.075, green: 0.1,   blue: 0.18)
    private let cyan         = Color(red: 0.0,   green: 0.78,  blue: 1.0)
    private let green        = Color(red: 0.2,   green: 0.9,   blue: 0.4)
    private let textPrimary  = Color(red: 0.9,   green: 0.925, blue: 0.96)
    private let textDim      = Color(red: 0.5,   green: 0.6,   blue: 0.72)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                sidePanel
                    .frame(width: 360)
                chatColumn
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewModel.isImportDropTargeted) { providers in
                        handleFolderDrop(providers)
                    }
                    .overlay {
                        if viewModel.isImportDropTargeted {
                            dropTargetOverlay
                        }
                    }
            }
        }
        .background(bgDark)
        .frame(minWidth: 1000, idealWidth: 1300, minHeight: 600, idealHeight: 780)
        .overlay {
            if viewModel.showIndexSheet {
                modalOverlay {
                    IndexStatusView(viewModel: viewModel)
                }
            }
        }
        .overlay {
            if viewModel.showCorpusSheet {
                modalOverlay {
                    CorpusView(viewModel: viewModel)
                }
            }
        }
        .overlay {
            if viewModel.showStatsSheet {
                modalOverlay {
                    StatsView(viewModel: viewModel)
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Logo + status
            HStack(spacing: 8) {
                HStack(spacing: -3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                }.foregroundColor(cyan)
                HStack(spacing: -3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                }.foregroundColor(cyan.opacity(0.3))

                Text("LIBRARIAN")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("//")
                    .font(.system(size: 17, weight: .light, design: .monospaced))
                    .foregroundColor(cyan)
                Text("LOCAL-FIRST")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(textDim)
                    .tracking(2)

                // Online badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(green)
                        .frame(width: 6, height: 6)
                        .shadow(color: green.opacity(0.7), radius: 4)
                    Text("ONLINE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(green)
                        .tracking(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(green.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(green.opacity(0.25), lineWidth: 0.5)
                )
                .cornerRadius(10)
            }
            .padding(.leading, 20)

            Spacer()

            // Nav tabs
            HStack(spacing: 26) {
                navTab("books.fill",     "CORPUS")        { viewModel.showCorpusSheet = true }
                navTab("internaldrive",  "INDEX CORPUS")   { viewModel.showIndexSheet = true }
                navTab("chart.bar.fill", "STATISTICS")     { viewModel.showStatsSheet = true }
            }
            .padding(.trailing, 24)
        }
        .frame(height: 48)
        .background(bgPanel)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, cyan.opacity(0.2), cyan.opacity(0.1), .clear],
                startPoint: .leading, endPoint: .trailing
            ).frame(height: 1)
        }
    }

    private func navTab(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(cyan.opacity(0.7))
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(textDim)
                    .tracking(0.5)
            }
        }.buttonStyle(.plain)
    }

    // MARK: - Chat Log Side Panel

    private var sidePanel: some View {
        ZStack {
            // Base gradient
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.09),
                    Color(red: 0.055, green: 0.075, blue: 0.14),
                    Color(red: 0.03, green: 0.04, blue: 0.09)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Central radial glow
            RadialGradient(
                colors: [
                    Color(red: 0.0, green: 0.3, blue: 0.5).opacity(0.2),
                    Color(red: 0.0, green: 0.15, blue: 0.35).opacity(0.06),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.4),
                startRadius: 0, endRadius: 190
            )

            // Geometric elements
            GeometryReader { geo in
                let cx = geo.size.width / 2
                let cy = geo.size.height * 0.4

                ZStack {
                    // Concentric rings
                    ForEach(0..<6) { i in
                        let r = Double(65 + i * 42)
                        Circle()
                            .stroke(cyan.opacity(max(0, 0.065 - Double(i) * 0.008)), lineWidth: 0.5)
                            .frame(width: r * 2, height: r * 2)
                            .position(x: cx, y: cy)
                    }

                    // Orbital ellipse 1
                    Ellipse()
                        .stroke(
                            LinearGradient(
                                colors: [.clear, cyan.opacity(0.2), cyan.opacity(0.38), cyan.opacity(0.1), .clear],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                        .frame(width: 270, height: 110)
                        .rotationEffect(.degrees(-18))
                        .position(x: cx, y: cy + 15)

                    // Orbital ellipse 2
                    Ellipse()
                        .stroke(
                            LinearGradient(
                                colors: [.clear, cyan.opacity(0.1), cyan.opacity(0.18), .clear],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.7
                        )
                        .frame(width: 180, height: 260)
                        .rotationEffect(.degrees(22))
                        .position(x: cx - 25, y: cy)

                    // Central glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.0, green: 0.65, blue: 0.95).opacity(0.4),
                                    Color(red: 0.0, green: 0.35, blue: 0.65).opacity(0.12),
                                    .clear
                                ],
                                center: .center, startRadius: 0, endRadius: 52
                            )
                        )
                        .frame(width: 104, height: 104)
                        .position(x: cx, y: cy)

                    // Core bright point
                    Circle()
                        .fill(Color(red: 0.15, green: 0.9, blue: 1.0))
                        .frame(width: 5, height: 5)
                        .shadow(color: cyan, radius: 10)
                        .shadow(color: cyan.opacity(0.4), radius: 22)
                        .position(x: cx, y: cy)

                    // Orbital accent dots
                    orbitDot(cx: cx, cy: cy, offset: CGPoint(x: 98, y: -42),  color: cyan, size: 4)
                    orbitDot(cx: cx, cy: cy, offset: CGPoint(x: -72, y: 108), color: Color(red: 0.85, green: 0.55, blue: 0.15), size: 5)
                    orbitDot(cx: cx, cy: cy, offset: CGPoint(x: -118, y: -48), color: cyan, size: 3)

                    // Floating particles
                    particle(cx: cx, cy: cy, offset: CGPoint(x: -88,  y: -58),  size: 2.2, alpha: 0.45)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: 68,   y: -78),  size: 1.7, alpha: 0.3)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: -128, y: 28),   size: 1.9, alpha: 0.25)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: 108,  y: 48),   size: 1.4, alpha: 0.2)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: 38,   y: -118), size: 1.1, alpha: 0.18)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: -58,  y: 98),   size: 1.8, alpha: 0.25)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: -138, y: -98),  size: 1.3, alpha: 0.15)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: 128,  y: -28),  size: 0.9, alpha: 0.18)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: 155,  y: 80),   size: 1.0, alpha: 0.12)
                    particle(cx: cx, cy: cy, offset: CGPoint(x: -155, y: 60),   size: 1.5, alpha: 0.2)
                }
            }

            // Bottom glow line
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, cyan.opacity(0.2), cyan.opacity(0.35), cyan.opacity(0.2), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 35)
                .padding(.bottom, 115)
            }

            sidebarContent
        }
        // Right edge glow
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [.clear, cyan.opacity(0.12), cyan.opacity(0.18), cyan.opacity(0.12), .clear],
                startPoint: .top, endPoint: .bottom
            ).frame(width: 1)
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("CHATS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(textDim)
                    .tracking(1)

                Spacer()

                Button(action: { viewModel.newConversation() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(cyan.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            List(selection: $viewModel.selectedConversationId) {
                ForEach(viewModel.conversations) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(textPrimary)
                            .lineLimit(2)

                        Text(Self.formatSidebarDate(conversation.updatedAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textDim.opacity(0.85))
                    }
                    .padding(.vertical, 6)
                    .tag(conversation.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onChange(of: viewModel.selectedConversationId) { newValue in
                viewModel.selectConversation(id: newValue)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.25),
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private static func formatSidebarDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func orbitDot(cx: CGFloat, cy: CGFloat, offset: CGPoint, color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(0.65))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.55), radius: size + 1)
            .position(x: cx + offset.x, y: cy + offset.y)
    }

    private func particle(cx: CGFloat, cy: CGFloat, offset: CGPoint, size: CGFloat, alpha: Double) -> some View {
        Circle()
            .fill(cyan.opacity(alpha))
            .frame(width: size, height: size)
            .shadow(color: cyan.opacity(alpha * 0.5), radius: size * 0.7)
            .position(x: cx + offset.x, y: cy + offset.y)
    }

    // MARK: - Chat Column

    private var chatColumn: some View {
        VStack(spacing: 0) {
            importStatusStrip

            // Micro toolbar
            HStack(spacing: 12) {
                Button(action: { viewModel.newConversation() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundColor(textDim)
                }.buttonStyle(.plain)

                Button(action: { viewModel.showContext.toggle() }) {
                    Image(systemName: viewModel.showContext ? "sidebar.right.fill" : "sidebar.right")
                        .font(.system(size: 13))
                        .foregroundColor(viewModel.currentContext != nil ? textDim : textDim.opacity(0.3))
                }.buttonStyle(.plain).disabled(viewModel.currentContext == nil)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(viewModel.messages) { message in
                            messageBubble(message)
                        }
                        if viewModel.isProcessing {
                            PulsingDots()
                                .padding(.leading, 50)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .onChange(of: viewModel.messages.count) { _ in
                        if let last = viewModel.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Suggestion pills (empty state only)
            if viewModel.messages.isEmpty && !viewModel.isProcessing {
                suggestionPills
            }

            // Input bar
            inputBar
        }
        .background(bgDark)
    }

    private var importStatusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isImportDropTargeted ? "tray.and.arrow.down.fill" : "folder.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(viewModel.isImportDropTargeted ? cyan : textDim)

                Text("Drop folders to import into UserLibrary: \(viewModel.importDestinationPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textDim)
                    .lineLimit(1)

                Spacer()
            }

            if let message = viewModel.importStatusMessage {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(viewModel.importStatusIsError ? Color(red: 1.0, green: 0.65, blue: 0.25) : green)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(viewModel.isImportDropTargeted ? cyan.opacity(0.08) : bgPanel.opacity(0.55))
        .overlay(
            Rectangle()
                .fill(cyan.opacity(viewModel.isImportDropTargeted ? 0.35 : 0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(cyan.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .padding(24)
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(cyan)
                    Text("Drop folders to import into UserLibrary")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(textPrimary)
                    Text(viewModel.importDestinationPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textDim)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(18)
                .background(bgPanel.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(cyan.opacity(0.35), lineWidth: 1)
                )
                .cornerRadius(8)
            )
            .allowsHitTesting(false)
    }

    // MARK: - Message Bubbles

    private func messageBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            return AnyView(
                HStack(alignment: .top, spacing: 10) {
                    // Avatar
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [cyan.opacity(0.55), Color(red: 0.1, green: 0.35, blue: 0.75)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                        )
                        .shadow(color: cyan.opacity(0.3), radius: 5)

                    Text(msg.content)
                        .font(.system(size: 14))
                        .foregroundColor(textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(msgUser)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    LinearGradient(
                                        colors: [cyan.opacity(0.5), cyan.opacity(0.12)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .cornerRadius(8)
                        .shadow(color: cyan.opacity(0.1), radius: 8)

                    Spacer()
                }
            )

        case .assistant, .system:
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text(msg.content)
                        .font(.system(size: 14))
                        .foregroundColor(textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(msgAssistant)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    LinearGradient(
                                        colors: [cyan.opacity(0.08), cyan.opacity(0.22), cyan.opacity(0.08)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .cornerRadius(8)
                        .shadow(color: cyan.opacity(0.07), radius: 5)
                        .padding(.leading, 38)

                    // CCR + source count
                    if let ccr = msg.ccrScore, !msg.sourceChunks.isEmpty {
                        HStack(spacing: 8) {
                            Text("CCR: \(String(format: "%.0f", ccr * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(ccr >= 0.9 ? green : Color(red: 1.0, green: 0.6, blue: 0.2))
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundColor(textDim.opacity(0.4))
                            Text("\(msg.sourceChunks.count) sources")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(textDim)
                        }
                        .padding(.leading, 38)
                    }
                }
            )
        }
    }

    // MARK: - Suggestion Pills

    private var suggestionPills: some View {
        HStack(spacing: 10) {
            pill("bubble.left.and.bubble.right.fill", "Let's discuss")
            pill("wand.and.sparkles",                 "Show possibilities")
            pill("play.rectangle.fill",               "Run analysis")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func pill(_ icon: String, _ text: String) -> some View {
        Button(action: {
            viewModel.queryInput = text
            Task { await viewModel.submitQuery() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(cyan.opacity(0.7))
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(red: 0.07, green: 0.1, blue: 0.19))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(cyan.opacity(0.2), lineWidth: 0.7)
            )
            .cornerRadius(18)
        }.buttonStyle(.plain)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Top glow line
            LinearGradient(
                colors: [.clear, cyan.opacity(0.12), .clear],
                startPoint: .leading, endPoint: .trailing
            ).frame(height: 1)

            HStack(spacing: 10) {
                // Text field with custom placeholder
                ZStack(alignment: .leading) {
                    if viewModel.queryInput.isEmpty {
                        Text("Type your question...")
                            .foregroundColor(textDim.opacity(0.45))
                            .font(.system(size: 14))
                    }
                    TextField("", text: $viewModel.queryInput, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundColor(textPrimary)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .onSubmit { Task { await viewModel.submitQuery() } }
                        .disabled(viewModel.isProcessing)
                }
                .frame(maxWidth: .infinity)

                // Action buttons
                HStack(spacing: 6) {
                    actionBtn("SEND",     filled: true)  { Task { await viewModel.submitQuery() } }
                    actionBtn("ANALYZE",  filled: false) { Task { await viewModel.submitQuery() } }
                    actionBtn("GENERATE", filled: false) { Task { await viewModel.submitQuery() } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(bgInput)
        }
    }

    // MARK: - Modal Overlay

    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { await viewModel.importDroppedFolders(from: providers) }
        return true
    }

    private func modalOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.showIndexSheet = false
                    viewModel.showCorpusSheet = false
                    viewModel.showStatsSheet = false
                }
            content()
                .shadow(color: cyan.opacity(0.2), radius: 20)
        }
    }

    private func actionBtn(_ label: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(filled ? .white : cyan.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(filled ? cyan.opacity(0.75) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(filled ? Color.clear : cyan.opacity(0.3), lineWidth: 0.7)
                )
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.queryInput.isEmpty || viewModel.isProcessing)
    }
}

// MARK: - Index Status Panel

struct IndexStatusView: View {
    @ObservedObject var viewModel: ChatViewModel

    private let bgDark      = Color(red: 0.04,  green: 0.055, blue: 0.1)
    private let bgTrack     = Color(red: 0.08,  green: 0.11,  blue: 0.2)
    private let cyan        = Color(red: 0.0,   green: 0.78,  blue: 1.0)
    private let textPrimary = Color(red: 0.9,   green: 0.925, blue: 0.96)
    private let textDim     = Color(red: 0.5,   green: 0.6,   blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header + close
            HStack {
                Text("INDEX KNOWLEDGE BASE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(cyan)
                    .tracking(1)
                Spacer()
                Button(action: { viewModel.showIndexSheet = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(textDim)
                }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("UserLibrary: \(viewModel.userLibraryPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textDim)
            }

            if viewModel.isIndexing {
                VStack(alignment: .leading, spacing: 10) {
                    // Custom progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Track
                            RoundedRectangle(cornerRadius: 3)
                                .fill(bgTrack)
                                .frame(height: 6)
                            // Fill
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [cyan.opacity(0.6), cyan],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * Double(viewModel.indexProgress?.progress ?? 0), height: 6)
                                .shadow(color: cyan.opacity(0.4), radius: 4)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text(viewModel.indexProgress?.currentFile ?? "Indexing...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textDim)
                            .lineLimit(1)
                        Spacer()
                        Text("\(viewModel.indexProgress?.indexed ?? 0) / \(viewModel.indexProgress?.total ?? 0)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(cyan.opacity(0.7))
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button("INDEX DOCUMENTS") { Task { await viewModel.startIndexing() } }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(cyan.opacity(0.7))
                        .cornerRadius(4)
                        .buttonStyle(.plain)

                    Button("GENERATE EMBEDDINGS") { Task { await viewModel.startEmbeddings() } }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(cyan.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(cyan.opacity(0.3), lineWidth: 0.7)
                        )
                        .cornerRadius(4)
                        .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 220)
        .background(bgDark)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cyan.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

// MARK: - Stats Sheet

struct StatsView: View {
    @ObservedObject var viewModel: ChatViewModel

    private let bgDark      = Color(red: 0.04,  green: 0.055, blue: 0.1)
    private let cyan        = Color(red: 0.0,   green: 0.78,  blue: 1.0)
    private let textPrimary = Color(red: 0.9,   green: 0.925, blue: 0.96)
    private let textDim     = Color(red: 0.5,   green: 0.6,   blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("DATABASE STATISTICS")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(cyan)
                    .tracking(1)
                Spacer()
                Button(action: { viewModel.showStatsSheet = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(textDim)
                }.buttonStyle(.plain)
            }

            if let stats = viewModel.stats {
                VStack(spacing: 0) {
                    statRow("Documents",   "\(stats.documentCount)")
                    statRow("Chunks",      "\(stats.chunkCount)")
                    statRow("Embeddings",  "\(stats.embeddingCount)")
                    statRow("Saved Notes", "\(stats.savedNoteCount)")
                    statRow("Concepts",    "\(stats.conceptCount)")
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(cyan.opacity(0.12), lineWidth: 1)
                )
            } else {
                Text("No data available")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textDim)
            }

            Button("REFRESH") { viewModel.refreshStats() }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(cyan.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(cyan.opacity(0.3), lineWidth: 0.7)
                )
                .cornerRadius(4)
                .buttonStyle(.plain)

            Spacer()
        }
        .padding(24)
        .frame(width: 340, height: 300)
        .background(bgDark)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cyan.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(8)
        .onAppear { viewModel.refreshStats() }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textDim)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(cyan.opacity(0.08))
                .frame(height: 1)
        }
    }
}

// MARK: - Corpus Browser Sheet

struct CorpusView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var selected: ChunkCorpusRow?

    private let bgDark      = Color(red: 0.04,  green: 0.055, blue: 0.1)
    private let bgPanel     = Color(red: 0.055, green: 0.075, blue: 0.13)
    private let bgRow       = Color(red: 0.06,  green: 0.08,  blue: 0.15)
    private let cyan        = Color(red: 0.0,   green: 0.78,  blue: 1.0)
    private let green       = Color(red: 0.2,   green: 0.9,   blue: 0.4)
    private let textPrimary = Color(red: 0.9,   green: 0.925, blue: 0.96)
    private let textDim     = Color(red: 0.5,   green: 0.6,   blue: 0.72)

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                header
                controls
                list
            }
            .padding(18)
            .frame(width: 980, height: 720)
            .background(bgDark)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(cyan.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(10)
            .onAppear {
                viewModel.startCorpusBrowsing()
            }
            .onDisappear {
                viewModel.stopCorpusBrowsing()
            }

            if let selected {
                detailOverlay(selected)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("CORPUS BROWSER")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(cyan)
                    .tracking(1)
                let pageCount = max(1, viewModel.corpusPageCount)
                let pageIndex = min(max(0, viewModel.corpusPageIndex), pageCount - 1)
                Text("\(viewModel.corpusRangeLabel)  ·  Page \(pageIndex + 1)/\(pageCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textDim)
            }

            Spacer()

            Button(action: { viewModel.showCorpusSheet = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(textDim)
            }
            .buttonStyle(.plain)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { viewModel.corpusFilter },
                set: { viewModel.setCorpusFilter($0) }
            )) {
                Text("ALL").tag(CorpusChunkFilter.all)
                Text("EMBEDDED").tag(CorpusChunkFilter.embeddedOnly)
                Text("UNEMBEDDED").tag(CorpusChunkFilter.withoutEmbeddings)
            }
            .pickerStyle(.segmented)
            .frame(width: 420)

            Menu {
                Button("500")  { viewModel.setCorpusPageSize(500) }
                Button("1000") { viewModel.setCorpusPageSize(1000) }
                Button("2000") { viewModel.setCorpusPageSize(2000) }
            } label: {
                HStack(spacing: 6) {
                    Text("PAGE \(viewModel.corpusPageSize)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(cyan.opacity(0.8))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(cyan.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(bgPanel)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(cyan.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            HStack(spacing: 8) {
                Button(action: { viewModel.goToFirstCorpusPage() }) {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cyan.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCorpusLoading || viewModel.corpusPageIndex <= 0)

                Button(action: { viewModel.goToPrevCorpusPage() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cyan.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCorpusLoading || viewModel.corpusPageIndex <= 0)

                Text(viewModel.corpusRangeLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(textDim)
                    .frame(minWidth: 120)

                Button(action: { viewModel.goToNextCorpusPage() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cyan.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCorpusLoading || viewModel.corpusPageIndex >= max(0, viewModel.corpusPageCount - 1))

                Button(action: { viewModel.goToLastCorpusPage() }) {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cyan.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCorpusLoading || viewModel.corpusPageIndex >= max(0, viewModel.corpusPageCount - 1))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(bgPanel.opacity(0.9))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(cyan.opacity(0.18), lineWidth: 1)
            )
            .cornerRadius(6)

            Button(action: { Task { await viewModel.reloadCorpus() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("REFRESH")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(cyan.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(cyan.opacity(0.25), lineWidth: 1)
                )
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCorpusLoading)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.corpusRows) { row in
                    Button(action: { selected = row }) {
                        corpusRow(row)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bgPanel.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cyan.opacity(0.12), lineWidth: 1)
        )
    }

    private func corpusRow(_ row: ChunkCorpusRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.hasEmbedding ? "E" : "-")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(row.hasEmbedding ? green : textDim.opacity(0.6))
                    .frame(width: 14)

                Text(row.contentType.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(cyan.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(cyan.opacity(0.08))
                    .cornerRadius(5)

                Text("TOK \(row.tokenCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textDim)

                Spacer()

                Text("\(row.documentId)  [\(row.chunkIndex)]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textDim.opacity(0.9))
                    .lineLimit(1)
            }

            Text(row.content.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(bgRow)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cyan.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private func detailOverlay(_ row: ChunkCorpusRow) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { selected = nil }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CHUNK DETAIL")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(cyan)
                        Text("\(row.documentId)  [\(row.chunkIndex)]  ·  \(row.contentType.rawValue)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textDim)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(action: { selected = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(textDim)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    Text(row.hasEmbedding ? "EMBEDDED" : "NOT EMBEDDED")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(row.hasEmbedding ? green : textDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((row.hasEmbedding ? green : textDim).opacity(0.08))
                        .cornerRadius(6)

                    if let model = row.embeddingModelName {
                        Text(model)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textDim)
                    }

                    Spacer()
                    Text("TOK \(row.tokenCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textDim)
                }

                ScrollView {
                    Text(row.content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(bgPanel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(cyan.opacity(0.12), lineWidth: 1)
                        )
                        .cornerRadius(8)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 820, height: 520)
            .background(bgDark)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(cyan.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(10)
            .shadow(color: cyan.opacity(0.25), radius: 20)
        }
    }
}
