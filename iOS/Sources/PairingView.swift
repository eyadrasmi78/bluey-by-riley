import SwiftUI

/// Shown until the phone finds the Mac: a sleepy blob and how to wake him up.
/// Once the link is encrypted, a found-but-unpaired Mac asks for the code from its menu bar instead.
struct PairingView: View {
    @ObservedObject var link: MacLink
    var onPlay: () -> Void
    @State private var code = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 56) {
            SleepyBlob()
                .frame(width: 220, height: 190)

            VStack(alignment: .leading, spacing: 14) {
                if let mac = link.needsPairingFor {
                    // Found the Mac, but we have no key for it: the menu code opens the door.
                    Text("Pair with \(mac)")
                        .font(.fredoka(32))
                        .foregroundStyle(Color(hex: 0xF4F1FA))
                    Text("On the Mac, open Bluey in the menu bar and choose “Pair a Phone…”. "
                         + "It shows a 10-character code. This keeps everything between the devices encrypted.")
                        .font(.plexSans(16))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                        .frame(maxWidth: 400, alignment: .leading)
                    HStack(spacing: 12) {
                        TextField("ABCDE-FGHJK", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.plexMono(24))
                            .multilineTextAlignment(.center)
                            .focused($typing)
                            .foregroundStyle(Color(hex: 0xF4F1FA))
                            .frame(width: 230, height: 52)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .onChange(of: code) { _, new in
                                code = GooglySecurity.formatPairingCode(new)
                                if GooglySecurity.normalizePairingCode(code).count == GooglySecurity.pairingCodeLength { pair() }
                            }
                        Button { pair() } label: {
                            Text("Pair")
                                .font(.plexSans(16).weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 24)
                                .frame(minHeight: 52)
                                .background(Color(hex: Palette.berry1), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(code.count != 6)
                    }
                    if link.pairingFailed {
                        Text("That code didn't work — the window may have closed. Check the Mac's menu for a fresh one.")
                            .font(.plexSans(14))
                            .foregroundStyle(Color(hex: 0xFF9AD0))
                    }
                } else {
                    Text("Wake me up from your Mac")
                        .font(.fredoka(32))
                        .foregroundStyle(Color(hex: 0xF4F1FA))
                    Text("Open Bluey in your Mac's menu bar. Keep both on the same Wi-Fi and I'll find it.")
                        .font(.plexSans(16))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                        .frame(maxWidth: 380, alignment: .leading)
                    HStack(spacing: 10) {
                        ProgressView().tint(Color(hex: Palette.berry1))
                        Text("Looking for your Mac")
                            .font(.plexMono(13))
                            .foregroundStyle(Color(hex: Palette.inkSoft))
                    }
                    .padding(.top, 4)
                    Button(action: onPlay) {
                        Text("Play without the Mac")
                            .font(.plexSans(15).weight(.semibold))
                            .foregroundStyle(Color(hex: 0xF4F1FA))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { if link.needsPairingFor != nil { typing = true } }
        .onChange(of: link.needsPairingFor) { _, mac in if mac != nil { typing = true } }
    }

    private func pair() {
        guard GooglySecurity.normalizePairingCode(code).count == GooglySecurity.pairingCodeLength, let mac = link.needsPairingFor else { return }
        typing = false
        link.pair(mac: mac, code: code)
        code = ""
    }
}

private struct SleepyBlob: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                BlobShape()
                    .fill(BlobShape.linear)
                    .overlay(BlobShape().fill(RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0)],
                                                             center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: 80)))
                    .opacity(0.9)
                HStack(spacing: 26) {
                    Capsule().fill(Color(hex: Palette.ink)).frame(width: 46, height: 7)
                    Capsule().fill(Color(hex: Palette.ink)).frame(width: 46, height: 7)
                }
                .offset(y: -18)
                Ellipse().fill(Color(hex: Palette.nose)).frame(width: 18, height: 12).offset(x: 4, y: 21)
                Text("z").font(.fredoka(26)).foregroundStyle(Color(hex: Palette.berry3))
                    .offset(x: 110, y: -95 - 4 * sin(t * 1.5))
                Text("z").font(.fredoka(18)).foregroundStyle(Color(hex: Palette.berry4))
                    .offset(x: 128, y: -122 - 4 * sin(t * 1.5 + 1))
            }
            .scaleEffect(1 + 0.02 * sin(t * 1.1), anchor: .bottom)
        }
    }
}
