import PluginKitUI
import SwiftUI

/// A mindmap's "Style" tab in the right sidebar: its structure drawn as small maps to pick from, and its first-level
/// branches in their colours (a click shows one). Folding and fitting stay in the map's zoom bar.
struct MindmapInspector: View {
    let model: MindmapTabModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) {
            InspectorGroup("Structure") {
                InspectorTileGrid {
                    ForEach(MindmapLayoutMode.allCases, id: \.self) { mode in
                        InspectorTile(mode.title, isSelected: model.mode == mode, height: 80) {
                            model.setMode(mode)
                        } picture: {
                            StructureSketch(mode: mode)
                        }
                    }
                }
            }
            if let root = model.root, !root.children.isEmpty {
                InspectorGroup("Branches", accessory: "\(root.descendantCount) topics") {
                    InspectorCard {
                        ForEach(Array(root.children.enumerated()), id: \.element.id) { index, topic in
                            InspectorRow(
                                topic.text.isEmpty ? "Untitled" : topic.text,
                                dot: MindmapStyle.color(branch: index, accent: theme.accent),
                                count: topic.descendantCount,
                                isDimmed: model.folded.contains(topic.id)
                            ) {
                                model.select(topic.id)
                                model.zoomToSelection()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A tiny map in the shape of a layout: a central topic and its branches, drawn with the tile's colour.
private struct StructureSketch: View {
    let mode: MindmapLayoutMode

    var body: some View {
        Canvas { context, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let node = CGSize(width: 14, height: 6)
            let leaf = CGSize(width: 10, height: 3)
            var lines = Path()
            var leaves: [CGRect] = []
            var centre: CGRect
            switch mode {
            case .mindmap:
                centre = CGRect(x: mid.x - node.width / 2, y: mid.y - node.height / 2, width: node.width, height: node.height)
                for side in [-1.0, 1.0] {
                    for dy in [-9.0, 0, 9] {
                        let end = CGPoint(x: mid.x + side * 18, y: mid.y + dy)
                        lines.move(to: CGPoint(x: mid.x + side * node.width / 2, y: mid.y))
                        lines.addQuadCurve(to: end, control: CGPoint(x: mid.x + side * 14, y: mid.y))
                        leaves.append(CGRect(
                            x: side > 0 ? end.x : end.x - leaf.width, y: end.y - leaf.height / 2,
                            width: leaf.width, height: leaf.height
                        ))
                    }
                }
            case .logic:
                let start = CGPoint(x: mid.x - 20, y: mid.y)
                centre = CGRect(x: start.x - node.width / 2, y: mid.y - node.height / 2, width: node.width, height: node.height)
                for dy in [-10.0, -3.5, 3.5, 10] {
                    let end = CGPoint(x: mid.x + 6, y: mid.y + dy)
                    lines.move(to: CGPoint(x: centre.maxX, y: mid.y))
                    lines.addQuadCurve(to: end, control: CGPoint(x: centre.maxX + 8, y: end.y))
                    leaves.append(CGRect(x: end.x, y: end.y - leaf.height / 2, width: leaf.width + 6, height: leaf.height))
                }
            case .timeline:
                centre = CGRect(x: mid.x - 29, y: mid.y - node.height / 2, width: node.width, height: node.height)
                lines.move(to: CGPoint(x: centre.maxX, y: mid.y))
                lines.addLine(to: CGPoint(x: mid.x + 29, y: mid.y))
                for (index, x) in [mid.x - 6, mid.x + 7, mid.x + 20].enumerated() {
                    let up = index % 2 == 0
                    lines.move(to: CGPoint(x: x, y: mid.y))
                    lines.addLine(to: CGPoint(x: x, y: mid.y + (up ? -8 : 8)))
                    leaves.append(CGRect(
                        x: x - leaf.width / 2, y: mid.y + (up ? -12 : 9), width: leaf.width, height: leaf.height
                    ))
                }
            }
            let shading = GraphicsContext.Shading.foreground
            context.stroke(lines, with: shading, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            context.fill(Path(roundedRect: centre, cornerRadius: Corners.r(2.5)), with: shading)
            context.drawLayer { layer in
                layer.opacity = 0.45
                for rect in leaves { layer.fill(Path(roundedRect: rect, cornerRadius: Corners.r(1.5)), with: shading) }
            }
        }
        .frame(width: 62, height: 34)
        .accessibilityHidden(true)
    }
}
