import SwiftUI
import SwiftData

struct LyricHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LyricSession.timestamp, order: .reverse) private var sessions: [LyricSession]
    
    @State private var selectedSession: LyricSession?
    @State private var searchText = ""
    @State private var showSummaryInspector = false
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSession) {
                if groupedSessions.isEmpty {
                   if !searchText.isEmpty {
                       ContentUnavailableView.search(text: searchText)
                   } else {
                       ContentUnavailableView(
                           "No Notes",
                           systemImage: "square.and.pencil",
                           description: Text("Recorded sessions will appear here.")
                       )
                   }
                } else {
                    ForEach(groupedSessions, id: \.0) { group, sessions in
                        Section(header: Text(group)) {
                            ForEach(sessions) { session in
                                NavigationLink(value: session) {
                                    SessionRow(session: session)
                                }
                            }
                            .onDelete { indexSet in
                                deleteSessions(at: indexSet, in: sessions)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, placement: .sidebar)
        } detail: {
            if let session = selectedSession {
                LyricSessionDetailView(session: session, showSummaryInspector: $showSummaryInspector) {
                     // Delete callback from detail view
                     modelContext.delete(session)
                     selectedSession = nil
                }
            } else {
                ContentUnavailableView(
                    "Select a Note",
                    systemImage: "doc.text",
                    description: Text("Select a session from the list to view details.")
                )
            }
        }
        .inspector(isPresented: $showSummaryInspector) {
            if let session = selectedSession {
                LyricSummaryView(session: session)
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
            } else {
                ContentUnavailableView("No Selection", systemImage: "doc.text")
            }
        }
    }
    
    // MARK: - Helpers
    
    private var filteredSessions: [LyricSession] {
        if searchText.isEmpty {
            return sessions
        } else {
            return sessions.filter { session in
                session.title.localizedCaseInsensitiveContains(searchText) ||
                session.transcriptSegments.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    private var groupedSessions: [(String, [LyricSession])] {
        let calendar = Calendar.current
        let now = Date()
        
        let grouped = Dictionary(grouping: filteredSessions) { session -> String in
            if calendar.isDateInToday(session.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(session.timestamp) {
                return "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: session.timestamp, to: now).day, days < 7 {
                return "Previous 7 Days"
            } else if let days = calendar.dateComponents([.day], from: session.timestamp, to: now).day, days < 30 {
                return "Previous 30 Days"
            } else {
                let year = calendar.component(.year, from: session.timestamp)
                let currentYear = calendar.component(.year, from: now)
                if year == currentYear {
                    let month = session.timestamp.formatted(.dateTime.month(.wide))
                    return month
                } else {
                    return String(year)
                }
            }
        }
        
        // Define order
        let order = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"]
        
        var result: [(String, [LyricSession])] = []
        
        // Add ordered groups
        for key in order {
            if let items = grouped[key] {
                result.append((key, items))
            }
        }
        
        // Add remaining groups (Months/Years) sorted descending
        let remainingKeys = grouped.keys.filter { !order.contains($0) }.sorted().reversed()
        for key in remainingKeys {
            if let items = grouped[key] {
                result.append((key, items))
            }
        }
        
        return result
    }
    
    private func deleteSessions(at offsets: IndexSet, in sessions: [LyricSession]) {
        for index in offsets {
            let session = sessions[index]
            modelContext.delete(session)
            if selectedSession?.id == session.id {
                selectedSession = nil
            }
        }
    }
}

// MARK: - Subviews

struct SessionRow: View {
    let session: LyricSession
    
    @State private var isRenaming = false
    @State private var editedTitle = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isRenaming {
                    TextField("Title", text: $editedTitle)
                        .font(.headline)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit {
                            saveTitle()
                        }
                        .onChange(of: isFocused) { _, focused in
                            if !focused {
                                saveTitle()
                            }
                        }
                } else {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            startRenaming()
                        }
                }
            }
            .frame(height: 22)
            
            HStack(spacing: 6) {
                Text(session.timestamp.formatted(date: .numeric, time: .omitted))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text(previewText)
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: {
                startRenaming()
            }) {
                Label("Rename", systemImage: "pencil")
            }
        }
    }
    
    private var previewText: String {
        if let first = session.transcriptSegments.first {
            return first
        }
        return "No text"
    }
    
    private func startRenaming() {
        editedTitle = session.title
        isRenaming = true
        isFocused = true
    }
    
    private func saveTitle() {
        if !editedTitle.isEmpty {
            session.title = editedTitle
        }
        isRenaming = false
    }
}

struct LyricSummaryView: View {
    let session: LyricSession
    @State private var isGenerating = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var currentModelName: String = ""
    
    // Dependencies
    private let settings = LyricModeSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Summary")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                if let summary = session.summary, !summary.isEmpty {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Summary")
                }
            }
            .padding(.top)
            
            if isGenerating {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding()
                    
                    Text("Summarizing with \(currentModelName)...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("This may take a moment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else if let summary = session.summary, !summary.isEmpty {
                ScrollView {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                
                Divider()
                
                // Re-generate Menu
                Menu {
                    if isLoadingModels {
                        Text("Loading models...")
                    } else if availableModels.isEmpty {
                        Text("No models found")
                    } else {
                        ForEach(availableModels, id: \.self) { model in
                            Button(model) {
                                generateSummary(model: model)
                            }
                        }
                    }
                } label: {
                    Label("Re-generate Summary", systemImage: "arrow.clockwise")
                }
                .padding(.bottom)
                
            } else {
                ContentUnavailableView {
                    Label("No Summary", systemImage: "text.alignleft")
                } description: {
                    Text("Generate a summary to see AI insights about this session.")
                } actions: {
                    // Generate Menu
                    Menu {
                        if isLoadingModels {
                            Text("Loading models...")
                        } else if availableModels.isEmpty {
                            Text("No models found")
                        } else {
                            ForEach(availableModels, id: \.self) { model in
                                Button(model) {
                                    generateSummary(model: model)
                                }
                            }
                        }
                    } label: {
                        Label("Generate Summary", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .onAppear {
            fetchModels()
        }
    }
    
    // ... fetchModels ... (same)
    private func fetchModels() {
        isLoadingModels = true
        
        // Check provider type from settings
        let provider = settings.aiProviderRaw.lowercased()
        
        if provider == "ollama" {
            let urlString = settings.ollamaBaseURL
            guard let url = URL(string: "\(urlString)/api/tags") else {
                isLoadingModels = false
                return
            }
            
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    // Decode Ollama response
                    struct OllamaResponse: Decodable {
                        let models: [OllamaModel]
                        struct OllamaModel: Decodable {
                            let name: String
                        }
                    }
                    let response = try JSONDecoder().decode(OllamaResponse.self, from: data)
                    await MainActor.run {
                        self.availableModels = response.models.map { $0.name }
                        self.isLoadingModels = false
                    }
                } catch {
                    print("Error fetching Ollama models: \(error)")
                    await MainActor.run {
                        self.availableModels = [] // Fallback or empty
                        self.isLoadingModels = false
                    }
                }
            }
        } else if provider == "openai" {
            // Static list for OpenAI (or fetch if API key present)
            availableModels = ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]
            isLoadingModels = false
        } else if provider == "anthropic" {
            availableModels = ["claude-3-opus-20240229", "claude-3-sonnet-20240229", "claude-3-haiku-20240307"]
            isLoadingModels = false
        } else {
             // Fallback
             availableModels = ["Default Model"]
             isLoadingModels = false
        }
    }
    
    private func generateSummary(model: String) {
        isGenerating = true
        currentModelName = model
        
        // Placeholder AI logic
        print("Generating summary with model: \(model)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                session.summary = "This is a generated summary using **\(model)** (Placeholder).\n\nKey points:\n• Discussed software architecture.\n• Reviewed SwiftData integration.\n• Updated UI components."
                isGenerating = false
            }
        }
    }
}

struct LyricSessionDetailView: View {
    let session: LyricSession
    @Binding var showSummaryInspector: Bool
    var onDelete: () -> Void
    
    @Environment(\.modelContext) private var modelContext
    @State private var fontSize: Double = 16
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var showTranslation = true // Default to showing both
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Date
                Text(session.timestamp.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                
                // Content
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(session.transcriptSegments.enumerated()), id: \.offset) { index, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment)
                                .font(.system(size: fontSize))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                            
                            if showTranslation,
                               index < session.translatedSegments.count,
                               !session.translatedSegments[index].isEmpty {
                                Text(session.translatedSegments[index])
                                    .font(.system(size: fontSize * 0.85))
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 8)
                                    .padding(.bottom, 4)
                                    .overlay(
                                        Rectangle()
                                            .fill(Color.blue.opacity(0.3))
                                            .frame(width: 2)
                                            .padding(.vertical, 2),
                                        alignment: .leading
                                    )
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 40)
        }
        .navigationTitle("") // Hide default Large Title to look cleaner
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // Language Toggle
                    Button(action: { showTranslation.toggle() }) {
                        Image(systemName: showTranslation ? "character.book.closed.fill" : "character.book.closed")
                            .foregroundColor(showTranslation ? .blue : .primary)
                    }
                    .help(showTranslation ? "Hide Translation" : "Show Translation")
                    
                    // Magic Button (Toggle Summary) - Replaces sidebar button
                    Button(action: {
                        withAnimation {
                            showSummaryInspector.toggle()
                        }
                    }) {
                        Image(systemName: "sparkles")
                            .symbolVariant(showSummaryInspector ? .fill : .none)
                            .foregroundColor(showSummaryInspector ? .blue : .primary)
                    }
                    .help("Toggle Summary")
                    
                    Menu {
                        Button(action: {
                            newName = session.title
                            isRenaming = true
                        }) {
                            Label("Rename", systemImage: "pencil")
                        }
                        
                        Button(action: {
                            let text: String
                            if showTranslation {
                                text = zip(session.transcriptSegments, session.translatedSegments + Array(repeating: "", count: max(0, session.transcriptSegments.count - session.translatedSegments.count)))
                                    .map { "\($0.0)\n\($0.1)" }
                                    .joined(separator: "\n\n")
                            } else {
                                text = session.transcriptSegments.joined(separator: "\n\n")
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }) {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive, action: {
                            onDelete()
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                session.title = newName
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}
