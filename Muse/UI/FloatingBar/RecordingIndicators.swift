import SwiftUI

// MARK: - Recording Indicators

struct PreparingDot: View {

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(TF.recording.opacity(0.16), lineWidth: 1.6)
                .frame(width: 16, height: 16)

            Circle()
                .trim(from: 0.16, to: 0.76)
                .stroke(
                    TF.recording,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 26, height: 26)
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

struct AnimatedRecordingIndicatorCluster<Content: View>: View {

    let audioLevel: AudioLevelMeter
    let recordingStartDate: Date?
    let content: (_ activity: CGFloat, _ time: TimeInterval, _ flow: CGFloat) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = max(
                0,
                timeline.date.timeIntervalSinceReferenceDate
                - (recordingStartDate?.timeIntervalSinceReferenceDate ?? timeline.date.timeIntervalSinceReferenceDate)
            )
            let flow = CGFloat((time * 0.72 + 0.5).truncatingRemainder(dividingBy: 1.0))
            let rawLevel = CGFloat(max(0.0, min(1.0, audioLevel.current)))
            let activity = 0.26 + pow(rawLevel, 0.72) * 0.74

            content(activity, time, flow)
        }
    }
}

/// Blue-green flowing waveform badge. Keeps the original "voice input" semantics
/// while replacing the old red palette with a softer liquid gradient.
struct RecordingDot: View {

    let time: Double
    let activity: CGFloat
    let flow: CGFloat

    var body: some View {
        ZStack {
            WaveSoftGlow(activity: activity, flow: flow)
                .frame(width: 30.0, height: 20.0)

            FlowingWaveStripes(time: time, activity: activity, flow: flow)
                .frame(width: 24.0, height: 14.2)
        }
        .frame(width: 44, height: 44)
    }
}

struct RecordingGlassInnerGlow: View {

    let activity: CGFloat
    let time: Double

    var body: some View {
        GeometryReader { geometry in
            let source = CGPoint(x: 22, y: geometry.size.height * 0.5)
            let phase = time * 0.74
            let corePulse = 0.82 + 0.18 * sin(phase)
            let fieldPulse = 0.84 + 0.16 * sin(phase * 0.76 + 0.9)
            let intensity = 0.55 + activity * 0.45
            let innerDrift = CGPoint(
                x: 1.4 * cos(phase * 0.38 + 0.3),
                y: 0.9 * sin(phase * 0.34 + 0.6)
            )
            let fieldDrift = CGPoint(
                x: 2.2 * cos(phase * 0.22 + 0.8),
                y: 1.6 * sin(phase * 0.26 + 0.1)
            )

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.10, green: 0.80, blue: 1.0).opacity(0.16 * Double(intensity) * corePulse),
                                Color(red: 0.10, green: 0.96, blue: 0.92).opacity(0.09 * Double(intensity) * corePulse),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 18
                        )
                    )
                    .frame(width: 28, height: 28)
                    .blur(radius: 6)
                    .position(x: source.x + innerDrift.x, y: source.y + innerDrift.y)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.10, green: 0.78, blue: 1.0).opacity(0.08 * Double(intensity) * fieldPulse),
                                Color(red: 0.10, green: 0.96, blue: 0.92).opacity(0.05 * Double(intensity) * fieldPulse),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: 40, height: 40)
                    .blur(radius: 11)
                    .position(
                        x: source.x + fieldDrift.x,
                        y: source.y + fieldDrift.y
                    )

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.10, green: 0.82, blue: 1.0).opacity(0.07 * Double(intensity) * fieldPulse),
                                Color(red: 0.10, green: 0.96, blue: 0.92).opacity(0.04 * Double(intensity) * fieldPulse),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 28
                        )
                    )
                    .frame(width: 52, height: 36)
                    .blur(radius: 14)
                    .rotationEffect(.degrees(-14 + sin(phase * 0.21) * 6))
                    .position(
                        x: source.x + 3.2 + 2.8 * cos(phase * 0.18 + 1.0),
                        y: source.y + 0.4 + 1.8 * sin(phase * 0.24 + 0.7)
                    )

                diffuseBlob(source: source, size: 19, radiusX: 7, radiusY: 6, angle: phase * 0.44 + 2.5, blue: 0.08, aqua: 0.03, blur: 7, intensity: intensity)
                diffuseBlob(source: source, size: 17, radiusX: 6, radiusY: 8, angle: phase * 0.38 + 4.0, blue: 0.04, aqua: 0.05, blur: 7, intensity: intensity)
                diffuseBlob(source: source, size: 22, radiusX: 10, radiusY: 7, angle: phase * 0.30 + 5.2, blue: 0.03, aqua: 0.07, blur: 9, intensity: intensity)
                diffuseBlob(source: source, size: 18, radiusX: 9, radiusY: 8, angle: phase * 0.34 + 0.8, blue: 0.03, aqua: 0.05, blur: 8, intensity: intensity)
                diffuseBlob(source: source, size: 15, radiusX: 12, radiusY: 5, angle: phase * 0.26 + 0.2, blue: 0.02, aqua: 0.04, blur: 6, intensity: intensity)
            }
            .blendMode(.screen)
            .opacity(0.92)
        }
        .allowsHitTesting(false)
    }

    private func diffuseBlob(
        source: CGPoint,
        size: CGFloat,
        radiusX: CGFloat,
        radiusY: CGFloat,
        angle: Double,
        blue: Double,
        aqua: Double,
        blur: CGFloat,
        intensity: CGFloat
    ) -> some View {
        let position = CGPoint(
            x: source.x + radiusX * CGFloat(cos(angle)),
            y: source.y + radiusY * CGFloat(sin(angle))
        )

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.12, green: 0.76, blue: 1.0).opacity(blue * Double(intensity)),
                        Color(red: 0.10, green: 0.94, blue: 0.92).opacity(aqua * Double(intensity)),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.5
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .position(position)
    }
}

private struct WaveSoftGlow: View {

    let activity: CGFloat
    let flow: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let leadOffset = width * (0.16 + flow * 0.18) - width * 0.5
            let trailOffset = width * (0.54 + flow * 0.12) - width * 0.5

            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.76, blue: 1.0).opacity(0.08 + Double(activity) * 0.06),
                                Color(red: 0.12, green: 0.94, blue: 0.92).opacity(0.10 + Double(activity) * 0.07),
                                Color(red: 0.30, green: 1.0, blue: 0.74).opacity(0.06 + Double(activity) * 0.05),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.96, height: height * 0.54)
                    .blur(radius: 8)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.18, green: 0.80, blue: 1.0).opacity(0.08 + Double(activity) * 0.06),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: width * 0.34
                        )
                    )
                    .frame(width: width * 0.48, height: height * 0.92)
                    .blur(radius: 5)
                    .offset(x: leadOffset, y: -height * 0.02)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.22, green: 1.0, blue: 0.78).opacity(0.07 + Double(activity) * 0.05),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: width * 0.30
                        )
                    )
                    .frame(width: width * 0.42, height: height * 0.82)
                    .blur(radius: 5)
                    .offset(x: trailOffset, y: height * 0.06)
            }
            .blendMode(.screen)
            .frame(width: width, height: height)
        }
        .allowsHitTesting(false)
    }
}

private struct FlowingWaveStripes: View {

    let time: Double
    let activity: CGFloat
    let flow: CGFloat

    private let baseHeights: [CGFloat] = [0.52, 0.82, 0.68, 0.90, 0.60]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let barWidth = width / 11.0
            let gap = barWidth * 0.55
            let bars = HStack(alignment: .center, spacing: gap) {
                ForEach(Array(baseHeights.enumerated()), id: \.offset) { index, ratio in
                    let pulse = 0.88 + CGFloat(sin(time * 2.2 + Double(index) * 0.55)) * 0.08
                    let levelLift = 0.78 + activity * 0.30

                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: stripeColors(for: index),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: height * ratio * pulse * levelLift)
                        .shadow(color: stripeGlow(for: index), radius: 3.8, x: 0, y: 0)
                }
            }

            ZStack {
                bars

                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.32),
                        Color(red: 0.34, green: 1.0, blue: 0.80).opacity(0.22),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width * 0.24, height: height * 1.4)
                .rotationEffect(.degrees(-12))
                .position(x: width * (0.20 + flow * 0.60), y: height * 0.5)
                .blendMode(.screen)
                .blur(radius: 3.2)
                .mask { bars }
            }
            .frame(width: width, height: height)
        }
    }

    private func stripeColors(for index: Int) -> [Color] {
        let blue = Color(red: 0.12, green: 0.72, blue: 1.0)
        let aqua = Color(red: 0.08, green: 0.90, blue: 0.94)
        let mint = Color(red: 0.22, green: 1.0, blue: 0.72)
        let lime = Color(red: 0.42, green: 1.0, blue: 0.66)
        let drift = Double(flow) * 0.18 + Double(index) * 0.03

        return [
            blue.opacity(0.90 - drift * 0.20),
            aqua.opacity(1.0),
            (index >= 3 ? lime : mint).opacity(0.92 + drift * 0.06),
        ]
    }

    private func stripeGlow(for index: Int) -> Color {
        let distance = abs(CGFloat(index) - (flow * 4.0))
        let emphasis = max(0.16, 0.31 - Double(distance) * 0.045)
        return Color(red: 0.18, green: 0.96, blue: 0.84).opacity(emphasis)
    }
}
