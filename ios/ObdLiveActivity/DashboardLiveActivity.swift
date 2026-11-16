import ActivityKit
import SwiftUI
import WidgetKit

/// KEEP IN SYNC with the copy in ios/Runner/AppDelegate.swift: iOS matches the
/// app and this extension by the type's name and its Codable layout.
struct DashboardAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    struct Item: Codable, Hashable {
      var label: String
      var value: String
      var unit: String
      var fraction: Double
    }

    var items: [Item]
    var alert: String
    var critical: Bool
  }

  var vehicle: String
}

private let accent = Color(red: 0.18, green: 0.83, blue: 0.75)

/// One live value: number, unit, a bar showing where it sits in its range, label.
private struct ValueCell: View {
  let item: DashboardAttributes.ContentState.Item
  var compact: Bool = false

  var body: some View {
    VStack(spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(item.value)
          .font(.system(size: compact ? 19 : 24, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(item.unit)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      ProgressView(value: min(max(item.fraction, 0), 1))
        .progressViewStyle(.linear)
        .tint(accent)
      Text(item.label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct AlertRow: View {
  let text: String
  let critical: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
      Text(text)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Spacer(minLength: 0)
    }
    .foregroundStyle(critical ? Color.red : Color.orange)
  }
}

/// The Lock Screen banner (medium) and the CarPlay / Apple Watch view (small).
private struct DashboardView: View {
  @Environment(\.activityFamily) private var family
  let context: ActivityViewContext<DashboardAttributes>

  private var isSmall: Bool { family == .small }

  private var hasAlert: Bool { !context.state.alert.isEmpty }

  /// The small view has room for four values, or two plus an alert line.
  private var items: [DashboardAttributes.ContentState.Item] {
    Array(context.state.items.prefix(isSmall && hasAlert ? 2 : 4))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: isSmall ? 4 : 8) {
      if hasAlert {
        AlertRow(text: context.state.alert, critical: context.state.critical)
      } else if !isSmall {
        Text(context.attributes.vehicle)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
      }

      if context.isStale || items.isEmpty {
        Text(context.isStale ? "Waiting for live data" : "Connecting…")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if isSmall {
        HStack(spacing: 8) {
          ForEach(Array(items.prefix(2)), id: \.self) { item in
            ValueCell(item: item, compact: true)
          }
        }
        if items.count > 2 {
          HStack(spacing: 8) {
            ForEach(Array(items.dropFirst(2)), id: \.self) { item in
              ValueCell(item: item, compact: true)
            }
          }
        }
      } else {
        HStack(spacing: 12) {
          ForEach(items, id: \.self) { item in
            ValueCell(item: item)
          }
        }
      }
    }
    .padding(isSmall ? 8 : 14)
  }
}

struct DashboardLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DashboardAttributes.self) { context in
      DashboardView(context: context)
        .activityBackgroundTint(Color.black.opacity(0.8))
        .activitySystemActionForegroundColor(Color.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          if let first = context.state.items.first {
            ValueCell(item: first, compact: true)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          if context.state.items.count > 1 {
            ValueCell(item: context.state.items[1], compact: true)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if !context.state.alert.isEmpty {
            AlertRow(text: context.state.alert, critical: context.state.critical)
          } else {
            HStack(spacing: 12) {
              ForEach(Array(context.state.items.dropFirst(2).prefix(2)), id: \.self) { item in
                ValueCell(item: item, compact: true)
              }
            }
          }
        }
      } compactLeading: {
        Text(context.state.items.first?.value ?? "–")
          .monospacedDigit()
      } compactTrailing: {
        Text(context.state.items.count > 1 ? context.state.items[1].value : "")
          .monospacedDigit()
      } minimal: {
        Image(systemName: context.state.alert.isEmpty ? "speedometer" : "exclamationmark.triangle.fill")
      }
    }
    // The small family is what CarPlay (iOS 26+) and Apple Watch display.
    .supplementalActivityFamilies([.small, .medium])
  }
}
