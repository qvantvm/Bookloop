import SwiftUI
import WebKit

@MainActor
final class ChatPanelModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draftMessage = ""
    @Published var pageContext = PageChatContext(pageKey: "unknown", chapterID: "")
    @Published var healthStatus: LocalAPIStatus = .unknown
    @Published var submissionMessage: String?
    @Published var submissionIsError = false
    @Published var chatError: String?
    @Published var isSending = false
    @Published var isSubmittingFeedback = false

    private var sessions: [String: [ChatMessage]] = [:]
    private let openAIClient = OpenAIClient()
    private let feedbackClient = FeedbackAPIClient()

    var canSendMessage: Bool {
        !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var canSubmitFeedback: Bool {
        !messages.isEmpty
            && !pageContext.chapterID.isEmpty
            && healthStatus == .online
            && !isSubmittingFeedback
    }

    func reset() {
        messages = []
        draftMessage = ""
        pageContext = PageChatContext(pageKey: "unknown", chapterID: "")
        healthStatus = .unknown
        submissionMessage = nil
        submissionIsError = false
        chatError = nil
        sessions = [:]
    }

    func updatePageContext(chapterID: String?, pageTitle: String?, pageURL: URL?) {
        let resolvedChapterID = chapterID ?? URLHelpers.inferChapterID(from: pageURL) ?? ""
        let pageKey = PageChatKey.make(chapterID: resolvedChapterID.isEmpty ? nil : resolvedChapterID, pageURL: pageURL)

        if pageContext.pageKey != pageKey {
            sessions[pageContext.pageKey] = messages
            messages = sessions[pageKey] ?? []
        }

        pageContext = PageChatContext(
            pageKey: pageKey,
            chapterID: resolvedChapterID,
            pageTitle: pageTitle,
            pageURL: pageURL?.absoluteString
        )
    }

    func checkHealth(baseURL: String) async {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            healthStatus = .notConfigured
            return
        }
        healthStatus = .checking
        do {
            let response = try await feedbackClient.checkHealth(baseURL: baseURL)
            healthStatus = response.status == "ok" ? .online : .offline(nil)
        } catch {
            healthStatus = .offline(error.localizedDescription)
        }
    }

    func sendMessage(webView: WKWebView?, settingsStore: AppSettingsStore) async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard settingsStore.hasAPIKey else {
            chatError = OpenAIError.missingAPIKey.errorDescription
            return
        }

        isSending = true
        chatError = nil
        draftMessage = ""

        let userMessage = ChatMessage(role: .user, content: text)
        appendMessage(userMessage)

        do {
            let pageContent = await WebView.extractPageContent(in: webView)
            let openAIMessages = buildOpenAIMessages(pageContent: pageContent, latestUserMessage: text)
            let reply = try await openAIClient.sendChat(
                apiKey: settingsStore.apiKey,
                model: settingsStore.openAIModel,
                messages: openAIMessages
            )
            appendMessage(ChatMessage(role: .assistant, content: reply))
        } catch {
            chatError = error.localizedDescription
        }

        isSending = false
    }

    func submitFeedback(book: BookConfig, chapters: [Chapter], currentURL: URL?) async {
        guard canSubmitFeedback else { return }

        isSubmittingFeedback = true
        submissionMessage = nil
        submissionIsError = false

        let resolvedChapter = ChapterResolver.feedbackAPIChapterID(
            pageContext.chapterID,
            book: book,
            chapters: chapters,
            currentURL: currentURL
        )

        let title = pageContext.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? messages.first(where: { $0.role == .user }).map { String($0.content.prefix(80)) }
            ?? "Chapter chat feedback"

        let body = formatFeedbackBody(resolvedChapter: resolvedChapter)

        let request = ReviewRequest(
            chapter: resolvedChapter,
            type: FeedbackType.question.rawValue,
            severity: FeedbackSeverity.medium.rawValue,
            title: title,
            body: body,
            section: pageContext.pageTitle,
            suggested_fix: nil
        )

        do {
            let response = try await feedbackClient.submitReview(baseURL: book.feedbackAPIBaseURL, request: request)
            submissionMessage = response.ok ? "Saved review: \(response.file)" : "The feedback API did not confirm success."
            submissionIsError = false
        } catch {
            submissionMessage = error.localizedDescription
            submissionIsError = true
        }

        isSubmittingFeedback = false
    }

    func clearCurrentChat() {
        messages = []
        sessions[pageContext.pageKey] = []
        chatError = nil
        submissionMessage = nil
        submissionIsError = false
    }

    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        sessions[pageContext.pageKey] = messages
    }

    private func buildOpenAIMessages(pageContent: String, latestUserMessage: String) -> [OpenAIChatMessage] {
        var result: [OpenAIChatMessage] = [
            OpenAIChatMessage(
                role: "system",
                content: """
                You are a reading assistant helping the user understand the current MkDocs book chapter. \
                Answer using the provided page content and the conversation so far. \
                If the answer is not in the page, say so clearly.
                """
            ),
            OpenAIChatMessage(
                role: "user",
                content: """
                Page title: \(pageContext.pageTitle ?? "Unknown")
                Chapter ID: \(pageContext.chapterID.isEmpty ? "Unknown" : pageContext.chapterID)
                Page URL: \(pageContext.pageURL ?? "Unknown")

                Page content:
                \(pageContent)
                """
            ),
            OpenAIChatMessage(role: "assistant", content: "Understood. I will answer based on this chapter content.")
        ]

        for message in messages where message.role != .system {
            if message.role == .user && message.content == latestUserMessage {
                continue
            }
            result.append(OpenAIChatMessage(role: message.role.rawValue, content: message.content))
        }

        result.append(OpenAIChatMessage(role: "user", content: latestUserMessage))
        return result
    }

    private func formatFeedbackBody(resolvedChapter: String) -> String {
        var lines = [
            "# Chat Feedback",
            "",
            "Page: \(pageContext.pageTitle ?? "Unknown")",
            "Chapter ID: \(resolvedChapter.isEmpty ? "Unknown" : resolvedChapter)",
            "URL: \(pageContext.pageURL ?? "Unknown")",
            "",
            "## Conversation",
            ""
        ]

        for message in messages where message.role != .system {
            let speaker = message.role == .user ? "User" : "Assistant"
            lines.append("### \(speaker)")
            lines.append(message.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

struct ChatPanelView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @ObservedObject var model: ChatPanelModel
    @ObservedObject var previewModel: BookPreviewModel
    @Binding var feedbackStatus: LocalAPIStatus

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !settingsStore.hasAPIKey {
                ContentUnavailableView {
                    Label("OpenAI Key Required", systemImage: "key.fill")
                } description: {
                    Text("Add your OpenAI API key in app settings (sidebar gear) to start chatting about the current page.")
                }
                .frame(maxHeight: .infinity)
            } else {
                messageList
            }

            Divider()
            composer
            footer
        }
        .onAppear {
            guard let book = library.selectedBook else { return }
            Task { await model.checkHealth(baseURL: book.feedbackAPIBaseURL) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Chapter Chat", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.headline)
                Spacer()
                StatusBadge(title: "Feedback API", status: model.healthStatus)
            }

            if let pageTitle = model.pageContext.pageTitle {
                Text(pageTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
            }

            if !model.pageContext.chapterID.isEmpty {
                Text("Chapter: \(model.pageContext.chapterID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        Text("Ask a question about the current chapter. The page content and chat history are sent to OpenAI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }

                    ForEach(model.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }

                    if model.isSending {
                        ProgressView("Thinking...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .onChange(of: model.messages.count) { _, _ in
                if let lastID = model.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this chapter...", text: $model.draftMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(!settingsStore.hasAPIKey || model.isSending)

            Button("Send") {
                Task {
                    await model.sendMessage(webView: previewModel.webView, settingsStore: settingsStore)
                }
            }
            .disabled(!model.canSendMessage || !settingsStore.hasAPIKey)
        }
        .padding()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.isSubmittingFeedback ? "Submitting..." : "Send as Feedback") {
                    guard let book = library.selectedBook else { return }
                    Task {
                        await model.submitFeedback(
                            book: book,
                            chapters: projectStore.chapters,
                            currentURL: previewModel.currentURL
                        )
                        if !model.submissionIsError {
                            reviewStore.refresh(book: book)
                        }
                    }
                }
                .disabled(!model.canSubmitFeedback || library.selectedBook == nil)

                Button("Clear Chat", action: model.clearCurrentChat)
                    .disabled(model.messages.isEmpty)

                Spacer()

                Button("Check API") {
                    guard let book = library.selectedBook else { return }
                    Task {
                        await model.checkHealth(baseURL: book.feedbackAPIBaseURL)
                        feedbackStatus = model.healthStatus
                    }
                }
            }

            if let chatError = model.chatError {
                Text(chatError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let submissionMessage = model.submissionMessage {
                Text(submissionMessage)
                    .font(.caption)
                    .foregroundStyle(model.submissionIsError ? .red : .green)
                    .textSelection(.enabled)
            }

            if case .offline = model.healthStatus {
                Text("Feedback API is offline. Start it with:\npython scripts/feedback_api.py --host 127.0.0.1 --port 8765")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom])
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 24) }

            Text(message.content)
                .font(.callout)
                .padding(10)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 280, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user { Spacer(minLength: 24) }
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.85)
        case .assistant:
            return Color.secondary.opacity(0.15)
        case .system:
            return Color.secondary.opacity(0.08)
        }
    }
}
