import SwiftUI

private final class ReportSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ProblemReportView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("report.title") private var title = ""
    @AppStorage("report.description") private var details = ""
    @AppStorage("report.payload") private var savedPayload = ""
    @State private var includeDetails = true
    @State private var sending = false
    @State private var message = ""
    @State private var issue: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "exclamationmark.bubble").font(.system(size: 32)).accessibilityHidden(true)
                    Text("Help us make PairIt better.").font(.title2.weight(.semibold))
                    Text("Reports are public on GitHub. Do not include personal information, passwords or pairing codes.").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Short summary", text: $title).textFieldStyle(.roundedBorder)
                        .onChange(of: title) { _, value in if value.count > 100 { title = String(value.prefix(100)) } }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What happened? What did you expect?").font(.subheadline.weight(.medium))
                        TextEditor(text: $details).frame(minHeight: 140).padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Problem description and steps to reproduce")
                            .onChange(of: details) { _, value in if value.count > 4000 { details = String(value.prefix(4000)) } }
                    }
                    Toggle("Include app version and iOS version", isOn: $includeDetails).font(.subheadline)
                    if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    if let issue {
                        Link(destination: issue) { Text("View issue ↗").frame(maxWidth: .infinity).padding(16) }.buttonStyle(.borderedProminent)
                    } else {
                        Button { Task { await submit() } } label: {
                            HStack { if sending { ProgressView().tint(.white) }; Text(sending ? "Sending…" : "Submit public report") }.frame(maxWidth: .infinity).padding(12)
                        }.buttonStyle(.borderedProminent).disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || details.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                    }
                }.padding(24).disabled(sending)
            }.background(Color(white: 0.96)).foregroundStyle(.black).tint(.black)
                .navigationTitle("Report a problem").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.light)
    }

    @MainActor private func submit() async {
        sending = true
        defer { sending = false }
        do {
            var context: [String: String] = [:]
            if includeDetails {
                let info = Bundle.main.infoDictionary ?? [:]
                context = ["version": "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))", "os": "iOS \(UIDevice.current.systemVersion)"]
            }
            var payload: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "description": details.trimmingCharacters(in: .whitespacesAndNewlines), "platform": "iOS", "context": context]
            var identifier = UUID().uuidString.lowercased()
            if let oldData = savedPayload.data(using: .utf8), var old = try JSONSerialization.jsonObject(with: oldData) as? [String: Any], let oldID = old.removeValue(forKey: "id") as? String,
               NSDictionary(dictionary: old).isEqual(to: payload) { identifier = oldID }
            payload["id"] = identifier
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            savedPayload = String(decoding: data, as: UTF8.self)
            var request = URLRequest(url: URL(string: "https://reports.pairit.kartikey.xyz/v1/reports")!)
            request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 25
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration, delegate: ReportSessionDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (body, response) = try await session.data(for: request)
            guard body.count <= 8192, let result = try JSONSerialization.jsonObject(with: body) as? [String: Any], let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if [200, 201].contains(http.statusCode), let value = result["url"] as? String,
               value.range(of: #"^https://github\.com/Json604/pairIt-download/issues/[1-9][0-9]*$"#, options: .regularExpression) != nil, let url = URL(string: value) {
                issue = url; message = "Report sent. Thank you for helping improve PairIt."; title = ""; details = ""
            } else { message = result["message"] as? String ?? "Could not confirm submission. Your draft is kept. Retry safely." }
        } catch { message = "Could not confirm submission. Your draft is kept. Check your connection and retry safely." }
    }
}
