import AppKit
import JackCore
import SwiftUI

/// The flowchart of the plan an agent put forward in plan mode. It observes the store only to find the
/// plan; the drawing is a separate view that redraws when the plan's text changes.
struct FlowPanel: View {
    @ObservedObject var store: ChatStore
    let conversationID: UUID

    var body: some View {
        PlanFlowView(plan: store.plan(for: conversationID)?.markdown)
            .equatable()
    }
}

private struct PlanFlowView: View, Equatable {
    let plan: String?

    var body: some View {
        if let plan, let flow = PlanFlow.parse(plan) {
            VStack(spacing: 0) {
                header(flow)
                ScrollView {
                    FlowChart(flow: flow)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "flowchart").font(.system(size: 26, weight: .light)).foregroundStyle(JackPalette.faint)
                Text(plan == nil ? "Sin plan todavía" : "El plan no tiene pasos que dibujar")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(JackPalette.muted)
                Text("Cuando un agente en modo Plan proponga un plan, su diagrama de flujo aparece aquí.")
                    .font(.system(size: 11.5)).foregroundStyle(JackPalette.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ flow: PlanFlow) -> some View {
        HStack(spacing: 8) {
            Text(flow.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text("\(flow.steps.count) pasos").font(.system(size: 11.5)).foregroundStyle(JackPalette.muted)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(flow.mermaid, forType: .string)
            } label: {
                Label("Copiar Mermaid", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copia el diagrama como `flowchart TD` de Mermaid")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(JackPalette.hairline).frame(height: 1) }
    }
}

private struct FlowChart: View {
    let flow: PlanFlow
    private let width: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            terminal(flow.title, symbol: "play.fill")
            ForEach(Array(flow.steps.enumerated()), id: \.element.id) { index, step in
                let previous = index > 0 ? flow.steps[index - 1] : nil
                if let phase = step.phase, phase != previous?.phase {
                    FlowArrow(label: nil)
                    phaseLabel(phase)
                    FlowArrow(label: nil)
                } else {
                    FlowArrow(label: previous?.isDecision == true ? "sí" : nil)
                }
                FlowNode(step: step)
            }
            FlowArrow(label: flow.steps.last?.isDecision == true ? "sí" : nil)
            terminal("Listo", symbol: "checkmark")
        }
        .frame(maxWidth: width)
    }

    private func terminal(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(JackPalette.secondaryText)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(JackPalette.panelStrong, in: Capsule())
    }

    private func phaseLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(JackPalette.muted).lineLimit(1)
            Rectangle().fill(JackPalette.hairline).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowNode: View {
    let step: PlanFlow.Step

    var body: some View {
        let tint = step.isDecision ? JackPalette.amber : JackPalette.accent
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if step.isDecision {
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.2)).frame(width: 18, height: 18).rotationEffect(.degrees(45))
                    Image(systemName: "questionmark").font(.system(size: 8, weight: .bold)).foregroundStyle(tint)
                } else {
                    Circle().fill(tint.opacity(0.18)).frame(width: 22, height: 22)
                    Text("\(step.id + 1)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(step.details.enumerated()), id: \.offset) { _, detail in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(JackPalette.faint)
                        Text(detail).foregroundStyle(JackPalette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11.5))
                }
                if !step.files.isEmpty {
                    FlowFiles(files: step.files)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JackPalette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(step.isDecision ? tint.opacity(0.5) : JackPalette.hairline, lineWidth: 1))
        .textSelection(.enabled)
        .contextMenu {
            Button("Copiar paso", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(([step.title] + step.details.map { "- " + $0 }).joined(separator: "\n"), forType: .string)
            }
        }
    }
}

private struct FlowFiles: View {
    let files: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(files.prefix(4), id: \.self) { file in
                Text(file.split(separator: "/").last.map(String.init) ?? file)
                    .font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: 4))
                    .help(file)
            }
            if files.count > 4 { Text("+\(files.count - 4)").font(.system(size: 10.5)).foregroundStyle(JackPalette.muted) }
        }
    }
}

/// The line between two nodes, ending in an arrowhead.
private struct FlowArrow: View {
    let label: String?

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: 16))
                path.move(to: CGPoint(x: -3.5, y: 12))
                path.addLine(to: CGPoint(x: 0.5, y: 17))
                path.addLine(to: CGPoint(x: 4.5, y: 12))
            }
            .stroke(JackPalette.faint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: 1, height: 18)
            if let label {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(JackPalette.muted)
                    .offset(x: 16)
            }
        }
        .frame(height: 18)
    }
}
