import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = PhotoLibraryDeleter()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    warning
                    libraryCard
                    if showsProgress {
                        progressCard
                    }
                    if let photo = model.testDeletion, !model.isDeleting {
                        testResultCard(photo)
                    }
                    if let errorText = model.errorText {
                        errorCard(errorText)
                    }
                    actions
                    footnote
                }
                .padding(horizontalSizeClass == .compact ? 20 : 28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .alert("Delete this one photograph?", isPresented: $model.confirmTest) {
            Button("Delete This Photo", role: .destructive) {
                Task { await model.deletePendingTest() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(testAlertMessage)
        }
        .alert("Delete all local photos and videos?", isPresented: $model.confirmDeleteAll) {
            Button("Delete All", role: .destructive) {
                Task { await model.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(model.counts.total.formatted()) photographs, Live Photos, and videos stored on this device. Shared albums are not included.\n\nPhotoDelete does not contact iCloud. If iCloud Photos is on, iOS can still sync these deletions. This app cannot check that setting.\n\niOS will ask you to confirm \(model.batchChoice.confirmationPhrase).")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshOnForeground()
        }
    }

    private var showsProgress: Bool {
        model.isDeleting || (model.statusText != nil && model.testDeletion == nil)
    }

    private var testAlertMessage: String {
        let detail = model.pendingTest?.detail ?? "1 photograph"
        return "\(detail)\n\nNothing else is deleted. PhotoDelete does not contact iCloud. iOS will ask you to confirm."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PhotoDelete")
                .font(.largeTitle)
                .bold()
            Text("Deletes photographs and videos stored on this device.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local library only", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("PhotoDelete does not connect to iCloud. It does not download or upload photographs.")
            Text("It deletes only items already stored in this device’s Photos library. Shared albums are skipped.")
                .bold()
            Text("If iCloud Photos is still turned on, iOS can sync those deletions to iCloud and your other devices. This app cannot check that setting.")
            Text("Delete one photo first. If that photograph disappears from iCloud.com or your other devices, stop.")
                .bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On this device")
                .font(.headline)
            countRow("Photographs", value: model.counts.photographs, icon: "photo")
            countRow("Videos", value: model.counts.videos, icon: "video")
            if model.countsLoaded, model.counts.other > 0 {
                countRow("Other", value: model.counts.other, icon: "questionmark.square")
            }
            Divider()
            countRow("Total", value: model.counts.total, icon: "square.stack")
                .font(.title3)
            Text("Includes hidden items, Live Photos, and burst photos. Does not include shared albums.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.authorization != .authorized {
                Text("Counts appear after you allow Full Photo Access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isDeleting ? "Deleting" : "Status")
                .font(.headline)
            if model.isReading || (model.isDeleting && model.snapshotTotal == 0) {
                ProgressView()
            } else if model.snapshotTotal > 0 {
                ProgressView(value: Double(model.processed), total: Double(model.snapshotTotal))
                    .accessibilityLabel("Deletion progress")
                    .accessibilityValue("\(model.processed) processed, \(model.remaining) remaining")
                progressRow("Processed", model.processed)
                progressRow("Remaining", model.remaining)
                if model.failed > 0 {
                    progressRow("Failed", model.failed)
                }
            }
            if let statusText = model.statusText {
                Text(statusText)
                    .font(.body)
            }
            if model.isDeletingAll {
                Text("Keep this screen open. iOS confirms each batch with its own prompt. Stop waits until the current batch finishes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func testResultCard(_ photo: TestPhoto) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Check before deleting the rest", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("1 photograph was deleted from this device only. PhotoDelete did not contact iCloud.")
            Text(photo.detail)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("Look for that photograph on iCloud.com or another device. If it is still there, or it was never in iCloud, this deletion stayed on this device. If it disappeared there, stop. iCloud Photos is still syncing.")
                .bold()
            Text("The photograph is in Recently Deleted on this device until you remove it in the Photos app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .card(tint: Color.green.opacity(0.12))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Error", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .textSelection(.enabled)
        }
        .card(tint: Color.red.opacity(0.12))
    }

    @ViewBuilder
    private var actions: some View {
        if model.isDeleting {
            Button {
                model.stop()
            } label: {
                Text(model.stopRequested ? "Stopping…" : "Stop After This Batch")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(uiColor: .systemGray))
            .disabled(model.stopRequested)
            .font(.title3)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await model.requestTest() }
                } label: {
                    Text("Delete One Photo (Test)")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .disabled(actionsDisabled || (model.countsLoaded && model.counts.photographs == 0 && model.authorization == .authorized))
                .font(.title3)
                Text("Uses the same delete path as Delete All, but only the newest local photograph.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Batch size", selection: $model.batchChoice) {
                    ForEach(DeletionBatch.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(actionsDisabled)
                Text(model.batchChoice.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.requestDeleteAll() }
            } label: {
                Text("Delete All Photos & Videos")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(actionsDisabled || model.libraryIsEmpty)
            .font(.title3)

            if model.showsSettings {
                Button {
                    model.openSettings()
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .font(.title3)
            }

            Text("You will be asked to confirm before anything is deleted. Nothing is deleted when you open the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsDisabled: Bool {
        model.isPreparing || model.confirmTest || model.confirmDeleteAll
    }

    private var footnote: some View {
        Text("Deleted items stay in Recently Deleted and keep using storage until you remove them in the Photos app: Albums → Recently Deleted → Delete All. PhotoDelete does not empty Recently Deleted. Deleting library items may not free all storage Photos is using.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func countRow(_ title: String, value: Int, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(model.countsLoaded ? value.formatted() : "—")
                .monospacedDigit()
        }
        .font(.title3)
    }

    private func progressRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .monospacedDigit()
        }
        .font(.title3)
    }
}

private extension View {
    func card(tint: Color = Color(.secondarySystemGroupedBackground)) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
