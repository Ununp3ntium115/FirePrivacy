import SwiftUI
import Charts
import UniformTypeIdentifiers
import FirePrivacyCore

struct UsageTimelineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedApp = ""
    @State private var showImporter = false
    @State private var importReportID: UUID?
    @State private var showClearConfirmation = false
    @State private var editing: AppUsageReference?
    @State private var editorReportID: UUID?
    @State private var showEditor = false
    @State private var includeOtherReferences = false
    @State private var activityPage = 0
    private let pageSize = 50

    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "A cross-section, with source boundaries", title: "Activity versus app use.", subtitle: "Compare imported record timing with app-use information you provide. The app does not automatically read Screen Time or another app’s foreground state.")
            FireCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("App-use inputs are unverified. Timing alone does not prove misuse, background state or what was transmitted.").font(.subheadline).foregroundStyle(FireStyle.muted)
                    DisclosureGroup("Source and coverage limits") {
                        TextListCard(title: "What this comparison can tell you", strings: ["This compares report records with supplied app-use information. It does not reveal transmitted contents or independently verify foreground/background state.", "Activity outside supplied windows can reflect legitimate background work, incomplete usage records or unrecorded foreground use. It does not prove misuse or that a platform report is false.", "No matching record does not establish no activity, no transmission or no retained data. Both the privacy export and the supplied usage information can be incomplete."])
                    }.tint(FireStyle.ember)
                }
            }
            FireCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Supply your context", detail: "A recollection, a manual transcription or an imported log remains unverified. Aggregate Screen Time durations never become invented session timestamps.")
                    PrimaryButton(title: "Import app-use JSON or event log", symbol: "square.and.arrow.down") {
                        importReportID = model.report?.id
                        showImporter = true
                    }.disabled(model.report == nil || model.isDemo || model.isWorking).accessibilityIdentifier("usage-import-button")
                    if let report = model.report, !report.apps.isEmpty {
                        Picker("App identifier from this import", selection: $selectedApp) {
                            Text("Choose an app identifier").tag("")
                            ForEach(report.apps) { app in Text(verbatim: app.bundleID).tag(app.bundleID) }
                        }.pickerStyle(.menu)
                        QuietButton(title: "Enter my app-use information", symbol: "pencil") {
                            editing = nil
                            editorReportID = model.report?.id
                            showEditor = true
                        }.disabled(selectedApp.isEmpty || model.isDemo || model.isWorking)
                        Text("Identifiers come from the displayed export, not an installed-app inventory. Choose a real imported report to save your own usage information.").font(.footnote).foregroundStyle(FireStyle.muted)
                    } else {
                        Text("Import an App Privacy Report to select app identifiers and compare recorded evidence.").foregroundStyle(FireStyle.muted)
                        QuietButton(title: "Import privacy report", symbol: "doc.badge.arrow.up") { model.requestImport() }
                    }
                    DisclosureGroup("Before supplying a file") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Choose Fire Privacy reference JSON or its coverage-header opened/closed event-log format. Arbitrary logs and Apple Screen Time exports are not automatically converted.")
                            Text("Files providers can download the file you select under their own policies. Importing a log does not authenticate its origin or grant access to Apple usage APIs.")
                            Text("An imported same-device claim is compared only with the privacy report selected when the claim is explicitly bound. It does not identify or authenticate the physical device, and it cannot silently authorize comparisons with later reports.")
                        }.font(.footnote).foregroundStyle(FireStyle.muted).padding(.top, 8)
                    }.tint(FireStyle.ember)
                    if model.isDemo {
                        Text("The displayed privacy report is fictional. Choose a real report before entering or importing your own app-use information.").foregroundStyle(FireStyle.gold)
                        QuietButton(title: "Import a real privacy report", symbol: "doc.badge.arrow.up") { model.requestImport() }
                    }
                }
            }
            comparisonContent
            DisclosureGroup("Inspect supplied references (\(model.usageTimeline.references.count))") { suppliedReferences }.tint(FireStyle.ember)
            if !model.usageTimeline.references.isEmpty {
                Button("Clear all supplied app-use information", role: .destructive) { showClearConfirmation = true }.frame(minHeight: 44).disabled(model.isWorking)
            }
        }.navigationTitle("Activity versus app use").accessibilityIdentifier("usage-timeline-screen")
        .onAppear { if selectedApp.isEmpty { selectedApp = model.report?.apps.first?.bundleID ?? "" } }
        .onChange(of: selectedApp) { _, _ in activityPage = 0 }
        .onChange(of: model.usageComparison?.timelineDigest) { _, _ in activityPage = 0 }
        .onChange(of: model.report?.id) { _, _ in selectedApp = model.report?.apps.first?.bundleID ?? ""; activityPage = 0 }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText, UTType("com.firesoftwaresolutions.FirePrivacy.ndjson") ?? .plainText], allowsMultipleSelection: false) { result in
            let expectedReportID = importReportID
            importReportID = nil
            Task { await model.handleUsageTimelineImport(result, expectedReportID: expectedReportID) }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { UsageReferenceEditor(bundleID: editing?.bundleID ?? selectedApp, reference: editing, expectedReportID: editorReportID) }
        }
        .confirmationDialog("Clear supplied app-use information?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear app-use information", role: .destructive) { Task { _ = await model.clearUsageTimeline() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes supplied usage references from encrypted local storage. Imported privacy reports, originals in Files and external copies remain.") }
    }

    private var suppliedReferences: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Supplied references", detail: "These are your dated inputs, separate from Apple’s exported observations.")
            Toggle("Show references for other app identifiers", isOn: $includeOtherReferences).tint(FireStyle.ember)
            if model.usageTimeline.references.isEmpty { EmptyState(symbol: "calendar.badge.clock", title: "No app-use information supplied", message: "Usage comparison remains unknown until you provide coverage and timing information. No foreground sessions are inferred from a contact count.") }
            let references = model.usageTimeline.references.filter { includeOtherReferences || selectedApp.isEmpty || $0.bundleID == selectedApp }
            if references.isEmpty && !model.usageTimeline.references.isEmpty { Text("No supplied reference matches the selected app identifier. Enable the other-identifiers option to inspect your remaining inputs.").foregroundStyle(FireStyle.muted) }
            ForEach(references) { reference in
                FireCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: reference.bundleID).font(.headline).foregroundStyle(FireStyle.text)
                        DetailRow(label: "Source", value: usageProvenanceTitle(reference.provenance))
                        DetailRow(label: "Device scope", value: usageDeviceScopeTitle(reference.deviceScope))
                        DetailRow(label: "Privacy report binding", value: usageReportBinding(reference.comparisonReportID, currentReportID: model.report?.id))
                        if let reportID = reference.comparisonReportID, reportID != model.report?.id { Text("This claim is bound to another import; its comparison remains unknown here.").font(.footnote).foregroundStyle(FireStyle.gold) }
                        if let label = reference.sourceLabel { DetailRow(label: "Supplied source label", value: label) }
                        DetailRow(label: "Reporting period starts", value: reference.coverage.startTimestampText ?? usageDate(reference.coverage.start))
                        DetailRow(label: "Reporting period ends", value: reference.coverage.endTimestampText ?? usageDate(reference.coverage.end))
                        DetailRow(label: "Foreground windows supplied", value: reference.foregroundWindows.count.formatted())
                        DetailRow(label: "Declared complete window coverage", value: reference.claimsCompleteForegroundWindows ? "Claimed by supplier; unverified" : "Not claimed")
                        if let seconds = reference.aggregateForegroundSeconds { DetailRow(label: "Supplied aggregate foreground duration", value: String(seconds) + " seconds; no exact sessions inferred") }
                        DetailRow(label: "Supplied date · source claim", value: usageDate(reference.suppliedAt))
                        if !reference.foregroundWindows.isEmpty {
                            DisclosureGroup("Inspect supplied foreground windows") {
                                ForEach(Array(reference.foregroundWindows.enumerated()), id: \.offset) { _, window in
                                    VStack(alignment: .leading, spacing: 8) {
                                        DetailRow(label: "Start", value: window.startTimestampText ?? usageDate(window.start))
                                        DetailRow(label: "End", value: window.endTimestampText ?? usageDate(window.end))
                                    }.padding(.vertical, 8)
                                }
                            }.tint(FireStyle.ember)
                        }
                        if reference.provenance != .importedUsageLog {
                            QuietButton(title: "Edit my reference", symbol: "pencil") {
                                editing = reference
                                editorReportID = model.report?.id
                                showEditor = true
                            }.disabled(model.isWorking || model.isDemo)
                                .accessibilityLabel("Edit usage reference for " + reference.bundleID + ", " + usageProvenanceTitle(reference.provenance) + ", reporting period beginning " + usageDate(reference.coverage.start))
                        }
                        Button("Remove this reference", role: .destructive) { removeReference(reference.id) }.frame(minHeight: 44).disabled(model.isWorking)
                            .accessibilityLabel("Remove usage reference for " + reference.bundleID + ", " + usageProvenanceTitle(reference.provenance) + ", reporting period beginning " + usageDate(reference.coverage.start))
                    }
                }
            }
        }
    }

    @ViewBuilder private var comparisonContent: some View {
        if let report = model.report, let comparison = model.usageComparison {
            FireCard {
                VStack(spacing: 12) {
                    DetailRow(label: "Evidence groups compared across this import", value: comparison.comparedActivityCount.formatted())
                    DetailRow(label: "Evidence groups omitted by bounds", value: comparison.omittedActivityCount.formatted())
                    DetailRow(label: "Analysis limit reached", value: comparison.reachedLimit ? "Yes; comparison incomplete" : "No")
                }
            }
            if comparison.reachedLimit { TextListCard(title: "Bounded comparison is incomplete", strings: ["\(comparison.omittedActivityCount) evidence groups were omitted after the analysis limit was reached. Missing rows are not evidence of inactivity."], symbol: "exclamationmark.triangle") }
            DisclosureGroup("Inspect comparison limits") { TextListCard(title: "Comparison limits", strings: comparison.limitations) }.tint(FireStyle.ember)
            if let app = comparison.apps.first(where: { $0.bundleID == selectedApp }) {
                SectionHeading(title: "Recorded cross-section", detail: "Classification is relative to supplied references and their claimed coverage, not a system-verified app state.")
                FireCard {
                    VStack(spacing: 14) {
                        DetailRow(label: "App identifier", value: app.bundleID)
                        DetailRow(label: "Compared evidence groups", value: app.activities.count.formatted())
                        DetailRow(label: "Rows with a timestamp outside claimed windows", value: app.outsideClaimedWindowActivities.formatted())
                        DetailRow(label: "Rows during a supplied zero-foreground period", value: app.zeroReportedUsageActivities.formatted())
                        DetailRow(label: "Rows with conflicting references", value: app.conflictingActivities.formatted())
                        DetailRow(label: "Unknown comparison rows", value: app.unknownActivities.formatted())
                        Text("These are evidence-group counts, not background contacts, access sessions or transmitted bytes.").font(.footnote).foregroundStyle(FireStyle.muted)
                    }
                }
                UsageTimelineChart(references: model.usageTimeline.references.filter { $0.bundleID == selectedApp }, activities: app.activities, reportID: report.id)
                let lower = min(activityPage * pageSize, app.activities.count)
                let upper = min(lower + pageSize, app.activities.count)
                ViewThatFits(in: .horizontal) {
                    HStack { pageControls(total: app.activities.count, lower: lower, upper: upper) }
                    VStack(alignment: .leading, spacing: 12) { pageControls(total: app.activities.count, lower: lower, upper: upper) }
                }
                LazyVStack(spacing: 14) {
                    ForEach(Array(app.activities[lower..<upper]), id: \.id) { activity in
                        UsageActivityCard(activity: activity, report: report)
                    }
                }
            } else { EmptyState(symbol: "clock", title: "No matching activity in this import", message: "Select an app identifier present in the export. Missing records do not establish no activity or no transmission.") }
        }
    }

    private func removeReference(_ id: UUID) {
        do {
            let updated = try AppUsageTimeline(references: model.usageTimeline.references.filter { $0.id != id })
            Task { _ = await model.saveUsageTimeline(updated) }
        } catch { model.notice = AppNotice(title: "Usage reference could not be changed", message: error.localizedDescription) }
    }
    @ViewBuilder private func pageControls(total: Int, lower: Int, upper: Int) -> some View {
        Button("Previous 50 rows") { activityPage = max(0, activityPage - 1) }.frame(minHeight: 44).disabled(lower == 0)
        Text(total == 0 ? "No evidence rows" : "Rows \(lower + 1)–\(upper) of \(total)").font(.subheadline).foregroundStyle(FireStyle.muted).accessibilityAddTraits(.updatesFrequently)
        Button("Next 50 rows") { activityPage += 1 }.frame(minHeight: 44).disabled(upper >= total)
    }
}

private struct UsageTimelineChart: View {
    let references: [AppUsageReference]
    let activities: [AppUsageActivityComparison]
    let reportID: UUID
    private var plottedActivities: [AppUsageActivityComparison] { Array(activities.prefix(200)) }
    private var timestampGroupCount: Int { plottedActivities.filter { !$0.timestampEvidence.isEmpty }.count }
    private var windowCount: Int { references.reduce(0) { $0 + $1.foregroundWindows.count } }

    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Times supplied, times recorded")
                DetailRow(label: "Evidence groups within plot limit", value: plottedActivities.count.formatted() + " of " + activities.count.formatted())
                DetailRow(label: "Groups with timestamps plotted", value: timestampGroupCount.formatted())
                DetailRow(label: "Supplied foreground windows", value: windowCount.formatted())
                if timestampGroupCount == 0 && windowCount == 0 {
                    Text("No supported timestamps or foreground windows in this plot selection. Timing remains unknown; an empty plot does not establish no activity.").foregroundStyle(FireStyle.muted)
                } else {
                    chart
                }
                Text("Bands are supplied foreground windows; device scope remains an unverified claim. Unmatched device/report inputs are not used for review flags. Dots are exported timestamps, including first/last bounds; they are not a reconstructed list of contacts. Dashed spans connect bounds only and do not mean continuous use. Aggregate-only durations produce no foreground bands. Only the first 200 compared evidence groups are considered for this plot; exact source timestamps remain inspectable in the paged rows.").font(.footnote).foregroundStyle(FireStyle.muted)
                Text("Time zone: " + TimeZone.current.identifier).font(.caption).foregroundStyle(FireStyle.muted)
            }
        }
    }

    // No contacts or sessions are interpolated between imported endpoints.
    private var chart: some View {
        Chart {
            ForEach(references) { reference in
                ForEach(Array(reference.foregroundWindows.enumerated()), id: \.offset) { _, window in
                    let matchedScope = reference.deviceScope == .sameDeviceAsReport && reference.comparisonReportID == reportID
                    RectangleMark(xStart: .value("Start", window.start), xEnd: .value("End", window.end), y: .value("Evidence", matchedScope ? "Supplied use" : "Unmatched scope"))
                        .foregroundStyle(matchedScope ? FireStyle.gold.opacity(0.3) : FireStyle.muted.opacity(0.2))
                }
            }
            ForEach(plottedActivities) { activity in
                if !activity.timestampEvidence.isEmpty {
                    let label = activity.category == .network ? "Network evidence" : "Sensor evidence"
                    if (activity.precision == .networkBounds || activity.precision == .sensorMatchedInterval), let start = activity.start, let end = activity.end, end != start {
                        RuleMark(xStart: .value("First bound", start), xEnd: .value("Last bound", end), y: .value("Evidence", label))
                            .foregroundStyle(activity.category == .network ? FireStyle.ember : FireStyle.gold)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                    ForEach(Array(activity.timestampEvidence.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Reported timestamp", point.timestamp), y: .value("Evidence", label)).foregroundStyle(activity.category == .network ? FireStyle.ember : FireStyle.gold)
                    }
                }
            }
        }
        .frame(height: 240)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour().minute()) } }
        .accessibilityLabel("Supplied app-use windows and recorded timestamps")
        .accessibilityValue("\(timestampGroupCount) evidence groups with timestamps and \(windowCount) supplied windows. Exact source timestamps and comparison details are available in the evidence rows.")
    }
}

private struct UsageActivityCard: View {
    let activity: AppUsageActivityComparison
    let report: PrivacyReport
    var body: some View {
        FireCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(activity.category == .network ? "Network evidence" : "Sensor evidence", systemImage: activity.category == .network ? "network" : "sensor").font(.headline).foregroundStyle(FireStyle.ember)
                if let domain = activity.domain { DetailRow(label: "Recorded domain", value: domain) }
                if let category = activity.sensorCategory { DetailRow(label: "Reported sensor category", value: category) }
                if let count = activity.reportedContactCount { DetailRow(label: "Reported contacts", value: count.formatted()) }
                if activity.sensorEventRecordCount > 0 { DetailRow(label: "Sensor event records", value: activity.sensorEventRecordCount.formatted()) }
                DetailRow(label: "Precision", value: usagePrecisionTitle(activity.precision))
                DetailRow(label: "Evidence-group comparison", value: usageAlignmentTitle(activity.alignment))
                if activity.reportedTimestampAlignment != activity.alignment { DetailRow(label: "Known timestamp comparison", value: usageAlignmentTitle(activity.reportedTimestampAlignment)) }
                if activity.reviewSuggested { Text("At least one exported timestamp provides review context under a supplied same-device claim. This does not establish verified background activity.").foregroundStyle(FireStyle.gold) }
                ForEach(Array(activity.timestampEvidence.enumerated()), id: \.offset) { _, point in DetailRow(label: usageTimestampRoleTitle(point.role), value: point.timestampText ?? usageDate(point.timestamp)) }
                if !activity.rawAPRContexts.isEmpty {
                    DisclosureGroup("Inspect reported APR context") { TextListCard(title: "Reported APR context", strings: activity.rawAPRContexts) }.tint(FireStyle.ember)
                }
                DisclosureGroup("Inspect evidence limits") { TextListCard(title: "Limitations", strings: activity.limitations) }.tint(FireStyle.ember)
                DisclosureGroup("How each supplied reference compares") {
                    if activity.sourceAssessments.isEmpty { Text("No supplied reference for this app. App use remains unknown.").foregroundStyle(FireStyle.muted) }
                    ForEach(activity.sourceAssessments, id: \.referenceID) { assessment in UsageSourceAssessmentView(assessment: assessment) }
                }.tint(FireStyle.ember)
                NavigationLink { UsageComparisonEvidenceView(report: report, evidenceIDs: activity.evidenceIDs) } label: { Label("Inspect supporting records", systemImage: "doc.text.magnifyingglass").foregroundStyle(FireStyle.ember).padding(.vertical, 8) }
            }
        }
    }
}

private struct UsageReferenceEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bundleID: String
    let reference: AppUsageReference?
    let expectedReportID: UUID?
    @State private var provenance = AppUsageProvenance.userRecollection
    @State private var coverageStart = Calendar.current.startOfDay(for: Date())
    @State private var coverageEnd = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
    @State private var windowStart = Date()
    @State private var windowEnd = Date().addingTimeInterval(30 * 60)
    @State private var windows: [UsageTimeRange] = []
    @State private var aggregateOnly = false
    @State private var aggregateHours = 0
    @State private var aggregateMinutes = 0
    @State private var aggregateSeconds = 0.0
    @State private var deviceScope = AppUsageDeviceScope.unspecified
    @State private var complete = false
    @State private var sourceLabel = ""
    @State private var editingReportID: UUID?
    @State private var capturedReportContext = false

    private var reportContextIsCurrent: Bool {
        guard capturedReportContext, let editingReportID, let report = model.report else { return false }
        return report.id == editingReportID && !model.isDemo && report.apps.contains { $0.bundleID == bundleID }
    }

    var body: some View {
        FirePage {
            PageHeader(eyebrow: "Your dated statement", title: "Supply app-use context.", subtitle: bundleID)
            if capturedReportContext && !reportContextIsCurrent {
                TextListCard(title: "The selected privacy report changed", strings: ["This editor keeps the report selected when it opened. Cancel and reopen it from the intended real report before saving; a same-device claim cannot be silently moved to another import."], symbol: "exclamationmark.triangle")
            }
            FireCard {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    deviceSection
                    coverageSection
                    Toggle("I have an aggregate duration, not exact windows", isOn: $aggregateOnly).tint(FireStyle.ember)
                    if aggregateOnly { aggregateSection } else { windowSection }
                    saveSection
                }
            }
        }
        .navigationTitle("App-use reference")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear {
            guard !capturedReportContext else { return }
            capturedReportContext = true
            load()
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Source of my information", selection: $provenance) {
                Text("My recollection").tag(AppUsageProvenance.userRecollection)
                Text("Manually transcribed system usage").tag(AppUsageProvenance.userTranscribedSystemUsage)
            }.pickerStyle(.menu)
            Text("A transcription is still user-entered and cannot authenticate Apple origin. Screen Time totals or hourly aggregates are not exact session timestamps.").font(.footnote).foregroundStyle(FireStyle.muted)
            SettingsTextField(title: "Optional private source label", text: $sourceLabel)
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Device source", selection: $deviceScope) {
                Text("Not sure / unspecified").tag(AppUsageDeviceScope.unspecified)
                Text("I’m comparing the same device as this report").tag(AppUsageDeviceScope.sameDeviceAsReport)
                Text("Other device or combined devices").tag(AppUsageDeviceScope.otherDeviceOrCombined)
            }.pickerStyle(.menu)
            Text("Screen Time can combine devices when Share Across Devices is on. Comparison review flags require your explicit same-device claim; Fire Privacy cannot verify it. Other or unspecified device scope stays unknown.").font(.footnote).foregroundStyle(FireStyle.muted)
            if let reference, reference.deviceScope == .sameDeviceAsReport, reference.comparisonReportID != editingReportID {
                Text("This reference was not bound to the report selected for this editor. The device choice starts at ‘Not sure’ here. Choose the same-device option only if you intend to rebind this edited reference to that import; saving replaces its previous local declaration.").font(.footnote).foregroundStyle(FireStyle.gold)
            }
        }
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            DatePicker("Reporting period starts", selection: $coverageStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Reporting period ends", selection: $coverageEnd, displayedComponents: [.date, .hourAndMinute])
            Text("Time zone: " + TimeZone.current.identifier + ". Include dates for periods crossing midnight.").font(.footnote).foregroundStyle(FireStyle.muted)
            Text("The initial reporting-period suggestion follows the report’s import date, which can differ from its activity dates. Set the period from your actual source rather than treating that suggestion as verified coverage.").font(.footnote).foregroundStyle(FireStyle.muted)
        }
    }

    private var enteredAggregateSeconds: Double {
        Double(aggregateHours) * 3_600 + Double(aggregateMinutes) * 60 + aggregateSeconds
    }

    private var secondsFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.significantDigits(1...17))
    }

    private var aggregateSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Aggregate hours", value: $aggregateHours, format: IntegerFormatStyle<Int>.number)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityLabel("Aggregate hours")
            Stepper("Aggregate minutes: \(aggregateMinutes)", value: $aggregateMinutes, in: 0...59)
            TextField("Additional seconds", value: $aggregateSeconds, format: secondsFormat)
                .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel("Additional aggregate seconds")
            Text("Entered total: " + String(enteredAggregateSeconds) + " seconds").font(.footnote).foregroundStyle(FireStyle.muted)
            Text("A zero aggregate is a supplied claim for this reporting period. It can provide review context but cannot reveal exact sessions, verify no use, or prove that recorded background activity was improper.").font(.footnote).foregroundStyle(FireStyle.muted)
        }
    }

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            DatePicker("App-use window starts", selection: $windowStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("App-use window ends", selection: $windowEnd, displayedComponents: [.date, .hourAndMinute])
            QuietButton(title: "Add this foreground window", symbol: "plus") { addWindow() }.disabled(windowStart >= windowEnd || windows.count >= 128)
            ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                foregroundWindowRow(index: index, window: window)
            }
            Toggle("I supplied every foreground window for this app during this reporting period", isOn: $complete).tint(FireStyle.ember)
            Text("Completeness is your declaration and is not verified by Fire Privacy. Leave this off if the record is partial or you are unsure. Time outside the reporting period always remains unknown.").font(.footnote).foregroundStyle(FireStyle.muted)
        }
    }

    private func foregroundWindowRow(index: Int, window: UsageTimeRange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usageDate(window.start) + " → " + usageDate(window.end)).foregroundStyle(FireStyle.text)
            Button("Remove window", role: .destructive) { windows.remove(at: index) }.frame(minHeight: 44)
                .accessibilityLabel("Remove foreground window from " + usageDate(window.start) + " to " + usageDate(window.end))
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            PrimaryButton(title: "Save encrypted usage reference", symbol: "checkmark") { save() }
                .disabled(coverageStart >= coverageEnd || model.isWorking || !reportContextIsCurrent)
            Text("This is stored separately from imported report evidence in the encrypted workspace. It does not enable Screen Time access, create a network request or alter another app’s settings.").font(.footnote).foregroundStyle(FireStyle.muted)
        }
    }

    private func addWindow() {
        do { windows.append(try UsageTimeRange(start: windowStart, end: windowEnd)) }
        catch { model.notice = AppNotice(title: "Window needs attention", message: error.localizedDescription) }
    }
    private func save() {
        guard reportContextIsCurrent, !model.isWorking else {
            model.notice = AppNotice(title: "App-use reference needs its original report", message: "Cancel and reopen the editor from the intended real privacy report before saving.")
            return
        }
        do {
            let period = try UsageTimeRange(start: coverageStart, end: coverageEnd)
            let total = Double(aggregateHours) * 3_600 + Double(aggregateMinutes) * 60 + aggregateSeconds
            guard !aggregateOnly || (aggregateHours >= 0 && aggregateSeconds.isFinite && (0..<60).contains(aggregateSeconds)) else { throw AppUsageError.invalidReference }
            let value = try AppUsageReference(id: reference?.id ?? UUID(), bundleID: bundleID, provenance: provenance, coverage: period, claimsCompleteForegroundWindows: !aggregateOnly && complete, foregroundWindows: aggregateOnly ? [] : windows, aggregateForegroundSeconds: aggregateOnly ? total : nil, sourceLabel: sourceLabel.isEmpty ? nil : sourceLabel, deviceScope: deviceScope, comparisonReportID: deviceScope == .sameDeviceAsReport ? editingReportID : nil)
            let remaining = model.usageTimeline.references.filter { $0.id != value.id }
            let timeline = try AppUsageTimeline(references: remaining + [value])
            Task {
                guard reportContextIsCurrent, !model.isWorking else { return }
                if await model.saveUsageTimeline(timeline) { dismiss() }
            }
        } catch { model.notice = AppNotice(title: "Usage reference needs attention", message: error.localizedDescription) }
    }
    private func load() {
        editingReportID = expectedReportID
        if let reference {
            provenance = reference.provenance; coverageStart = reference.coverage.start; coverageEnd = reference.coverage.end
            windows = reference.foregroundWindows; complete = reference.claimsCompleteForegroundWindows; sourceLabel = reference.sourceLabel ?? ""
            aggregateOnly = reference.aggregateForegroundSeconds != nil
            let total = reference.aggregateForegroundSeconds ?? 0
            aggregateHours = Int(total / 3_600); aggregateMinutes = Int(total.truncatingRemainder(dividingBy: 3_600) / 60); aggregateSeconds = total.truncatingRemainder(dividingBy: 60)
            deviceScope = reference.deviceScope == .sameDeviceAsReport && reference.comparisonReportID != editingReportID ? .unspecified : reference.deviceScope
            if let first = windows.first { windowStart = first.start; windowEnd = first.end }
        } else if let report = model.report {
            coverageStart = Calendar.current.startOfDay(for: report.importedAt)
            coverageEnd = Calendar.current.date(byAdding: .day, value: 1, to: coverageStart) ?? coverageStart.addingTimeInterval(24 * 60 * 60)
            windowStart = coverageStart; windowEnd = coverageStart.addingTimeInterval(30 * 60)
        }
    }
}

private struct UsageComparisonEvidenceView: View {
    let report: PrivacyReport
    let evidenceIDs: [UUID]
    var body: some View {
        FirePage {
            ReportStatusBanner()
            PageHeader(eyebrow: "Imported evidence, unchanged", title: "Inspect the record.", subtitle: "The supplied usage reference never changes these observations. Exported timestamps, contexts and counts remain the source of the comparison.")
            let selected = Set(evidenceIDs)
            ForEach(report.observations.filter { selected.contains($0.id) }) { record in ObservationCard(observation: record) }
        }.navigationTitle("Comparison evidence")
    }
}

private struct UsageSourceAssessmentView: View {
    @EnvironmentObject private var model: AppModel
    let assessment: AppUsageReferenceAssessment
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(FireStyle.gold.opacity(0.12))
            DetailRow(label: "Source", value: usageProvenanceTitle(assessment.provenance))
            DetailRow(label: "Device scope", value: usageDeviceScopeTitle(assessment.deviceScope))
            DetailRow(label: "Privacy report binding", value: usageReportBinding(assessment.comparisonReportID, currentReportID: model.report?.id))
            if let label = assessment.sourceLabel { DetailRow(label: "Supplied label", value: label) }
            DetailRow(label: "Coverage start", value: assessment.coverage.startTimestampText ?? usageDate(assessment.coverage.start))
            DetailRow(label: "Coverage end", value: assessment.coverage.endTimestampText ?? usageDate(assessment.coverage.end))
            DetailRow(label: "Complete foreground windows", value: assessment.claimsCompleteForegroundWindows ? "Claimed by supplier; unverified" : "Not claimed")
            if let seconds = assessment.aggregateForegroundSeconds { DetailRow(label: "Aggregate foreground duration", value: String(seconds) + " seconds; no session locations") }
            DetailRow(label: "Timestamp summary", value: usageAlignmentTitle(assessment.alignment))
            ForEach(Array(assessment.timestamps.enumerated()), id: \.offset) { _, point in
                VStack(alignment: .leading, spacing: 6) {
                    DetailRow(label: usageTimestampRoleTitle(point.timestamp.role), value: point.timestamp.timestampText ?? usageDate(point.timestamp.timestamp))
                    Text(usageAlignmentTitle(point.alignment)).font(.caption).foregroundStyle(FireStyle.muted)
                }
            }
            ForEach(Array(assessment.limitations.enumerated()), id: \.offset) { _, limitation in Text(verbatim: limitation).font(.footnote).foregroundStyle(FireStyle.muted) }
        }.padding(.vertical, 12)
    }
}

private func usageDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .standard)
}

private func usageProvenanceTitle(_ provenance: AppUsageProvenance) -> String {
    switch provenance {
    case .userRecollection: "Declared recollection · unverified"
    case .userTranscribedSystemUsage: "Declared manual system-usage transcription · unverified"
    case .importedUsageLog: "Declared imported usage log · unverified"
    }
}

private func usageDeviceScopeTitle(_ scope: AppUsageDeviceScope) -> String {
    switch scope {
    case .sameDeviceAsReport: "Same device as report · supplier’s unverified claim"
    case .otherDeviceOrCombined: "Another device or combined devices · no review comparison"
    case .unspecified: "Unspecified device · comparison unknown"
    }
}

private func usageReportBinding(_ boundID: UUID?, currentReportID: UUID?) -> String {
    guard let boundID else { return "Unbound; comparison unknown" }
    return boundID == currentReportID ? "This report · supplier’s claim" : "Another import; comparison unknown here"
}

private func usageAlignmentTitle(_ alignment: AppUsageAlignment) -> String {
    switch alignment {
    case .outsideClaimedWindows: "At least one recorded timestamp outside claimed windows"
    case .overlapsSuppliedWindows: "At least one recorded timestamp overlaps supplied windows"
    case .mixedReportedTimestamps: "Recorded timestamps both inside and outside claimed windows"
    case .unknown: "Unknown from supplied coverage and evidence"
    case .conflictingReferences: "Supplied references disagree about a recorded timestamp"
    case .activityDuringZeroReportedForegroundUsage: "Recorded timestamp during a supplied zero-foreground period"
    }
}

private func usagePrecisionTitle(_ precision: AppActivityPrecision) -> String {
    switch precision {
    case .timestampPoint: "Exported timestamp point"
    case .networkBounds: "Exported network bounds; individual hit times unknown"
    case .sensorMatchedInterval: "Candidate sensor begin/end pair; continuous access unverified"
    case .incompleteTimestamp: "One reported network bound; remaining contact timing unknown"
    case .incompleteSensorInterval: "Unpaired sensor begin/end; interval extent unknown"
    case .unknown: "No supported timing information"
    }
}

private func usageTimestampRoleTitle(_ role: AppActivityTimestamp.Role) -> String {
    switch role {
    case .event: "Exported event timestamp"
    case .firstContact: "First recorded contact bound"
    case .lastContact: "Last recorded contact bound"
    case .sensorBegin: "Sensor begin record"
    case .sensorEnd: "Sensor end record"
    }
}
