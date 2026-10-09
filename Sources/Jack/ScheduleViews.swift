import JackCore
import SwiftUI

/// The clock in the composer: leaves the written message to be sent at a chosen time, and lists those already waiting.
struct ScheduleMessageButton: View {
    @ObservedObject var schedules: ScheduleCenter
    let conversationID: UUID
    let canSchedule: Bool
    let onSchedule: (Date) -> Void
    @State private var showing = false
    @State private var date = Date().addingTimeInterval(3600)

    private var pending: [ScheduledMessage] { schedules.messages(for: conversationID) }

    var body: some View {
        Button {
            date = max(date, Date().addingTimeInterval(300))
            showing.toggle()
        } label: {
            Image(systemName: pending.isEmpty ? "clock" : "clock.badge.checkmark").font(.system(size: 12.5, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(pending.isEmpty ? JackPalette.muted : JackPalette.accent)
        .help("Programar el mensaje para enviarlo a una hora concreta")
        .accessibilityLabel("Programar mensaje")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Programar mensaje").font(.system(size: 12, weight: .semibold)).foregroundStyle(JackPalette.muted)
                DatePicker("Enviar", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical).labelsHidden()
                HStack(spacing: 6) {
                    quick("En 1 h", 3600)
                    quick("Esta noche", nil, hour: 21)
                    quick("Mañana 9:00", nil, hour: 9, tomorrow: true)
                }
                Button {
                    onSchedule(date); showing = false
                } label: {
                    Text(canSchedule ? "Programar para \(date.formatted(date: .abbreviated, time: .shortened))" : "Escribe un mensaje primero")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(!canSchedule || date <= Date())
                if !pending.isEmpty {
                    Divider()
                    Text("Programados").font(.system(size: 11, weight: .semibold)).foregroundStyle(JackPalette.muted)
                    ForEach(pending) { message in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(message.text.isEmpty ? "Archivos adjuntos" : message.text).font(.system(size: 12)).lineLimit(2)
                                Text(message.fireAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10.5)).foregroundStyle(JackPalette.faint)
                            }
                            Spacer(minLength: 6)
                            Button { schedules.cancelMessage(message.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(JackPalette.muted).help("Cancelar")
                        }
                    }
                }
            }
            .padding(12).frame(width: 290)
        }
    }

    private func quick(_ title: String, _ seconds: TimeInterval?, hour: Int? = nil, tomorrow: Bool = false) -> some View {
        Button(title) {
            if let seconds { date = Date().addingTimeInterval(seconds); return }
            let calendar = Calendar.current
            var target = calendar.date(bySettingHour: hour ?? 9, minute: 0, second: 0, of: Date()) ?? Date()
            if tomorrow || target <= Date() { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }
            date = target
        }
        .controlSize(.small).font(.system(size: 10.5))
    }
}
