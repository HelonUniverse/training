import CoachCore
import SwiftUI

/// "AI match analysis" block inside the Session Summary: start button,
/// progress, errors, and a link to the finished analysis.
struct MatchAnalysisSection: View {
    @Environment(CoachModel.self) private var model
    let sessionID: UUID
    @State private var confirm = false

    var body: some View {
        let state = model.analysisState(for: sessionID)
        let existing = model.analysis(for: sessionID)
        Section {
            if let existing {
                NavigationLink {
                    MatchAnalysisView(analysis: existing)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ver análisis de la partida").font(.headline)
                        Text(existing.content.primary_improvement_area.title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            switch state {
            case .idle, .failed:
                if case .failed(let message) = state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button(existing == nil ? "Analyze match with AI" : "Analyze again") {
                    confirm = true
                }
                .disabled(!model.hasOpenAIKey || model.estimatedAnalysisFrames(for: sessionID) == 0)
            case .extracting(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Preparando fotogramas \(done)/\(total)")
                }
            case .analyzing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Analizando minuto \(done)/\(total)")
                }
            case .summarizing:
                ProgressView { Text("Escribiendo el análisis…") }
            }
        } header: {
            Text("AI match analysis")
        } footer: {
            if !model.hasOpenAIKey {
                Text("Add your OpenAI API key in Settings (gear icon on Home) to enable analysis.")
            } else {
                Text("Keep the app open while it runs (usually 1–3 minutes). Frames are sent to OpenAI (\(model.openAIModel)).")
            }
        }
        .confirmationDialog(
            "Send about \(model.estimatedAnalysisFrames(for: sessionID)) frames of this match to OpenAI (\(model.openAIModel)) for analysis?",
            isPresented: $confirm, titleVisibility: .visible
        ) {
            Button("Analyze") { model.analyze(sessionID) }
        } message: {
            Text("Only frames and session facts are sent; nothing else from your iPhone. Costs are billed to your OpenAI account.")
        }
    }
}

struct MatchAnalysisView: View {
    let analysis: MatchAnalysis

    var body: some View {
        let content = analysis.content
        List {
            Section("Resumen") {
                ForEach(content.overall_observations, id: \.self) { Text($0) }
            }
            Section("Tu mayor fortaleza") { InsightBlock(insight: content.top_strength) }
            Section("Lo que más conviene mejorar") { InsightBlock(insight: content.primary_improvement_area) }
            if !content.critical_moments.isEmpty {
                Section("Momentos clave") {
                    ForEach(content.critical_moments, id: \.self) { moment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(SessionTimeFormatter.clock(moment.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(moment.title).font(.headline)
                            }
                            OIRRows(observation: moment.observation, inference: moment.inference,
                                    recommendation: moment.recommendation, confidence: moment.confidence)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Por área") {
                ForEach(content.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.category).font(.headline)
                        OIRRows(observation: category.observation, inference: category.inference,
                                recommendation: category.recommendation, confidence: category.confidence)
                    }
                    .padding(.vertical, 4)
                }
            }
            if !content.repeated_patterns.isEmpty {
                Section("Patrones repetidos") { ForEach(content.repeated_patterns, id: \.self) { Text($0) } }
            }
            Section("Qué practicar la próxima vez") { Text(content.next_practice_focus) }
            if !content.limitations.isEmpty {
                Section("Límites de este análisis") {
                    ForEach(content.limitations, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
            Section {
                LabeledContent("Confianza general", value: String(format: "%.0f %%", content.confidence * 100))
                LabeledContent("Modelo", value: "\(analysis.provider) · \(analysis.model)")
                LabeledContent("Fotogramas", value: "\(analysis.framesAnalyzed) (\(analysis.framesFromVideo) de vídeo, \(analysis.framesFromKeyframes) keyframes)")
                LabeledContent("Tokens", value: "\(analysis.usage.inputTokens) entrada · \(analysis.usage.outputTokens) salida")
                LabeledContent("Fecha", value: analysis.generatedAt.formatted(date: .abbreviated, time: .shortened))
            } footer: {
                Text("La IA solo ve fotogramas sueltos (≈1 por segundo). Lo que aparece como inferencia es una interpretación, no un hecho.")
            }
        }
        .navigationTitle("Match Analysis")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InsightBlock: View {
    let insight: CoachingInsight
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(insight.title).font(.headline)
            OIRRows(observation: insight.observation, inference: insight.inference,
                    recommendation: insight.recommendation, confidence: insight.confidence)
        }
        .padding(.vertical, 4)
    }
}

private struct OIRRows: View {
    let observation: String
    let inference: String
    let recommendation: String
    let confidence: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Observación", observation, "eye")
            row("Inferencia", inference, "questionmark.circle")
            row("Recomendación", recommendation, "arrow.forward.circle")
            Text(String(format: "Confianza %.0f %%", confidence * 100)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ text: String, _ icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.callout)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }
}
