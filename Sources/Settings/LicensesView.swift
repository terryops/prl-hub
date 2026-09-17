import SwiftUI

/// Open-source acknowledgements. The wallet core (OysterMobile.xcframework) is
/// gomobile-built from the public `pearl-research-labs/pearl` monorepo (ISC), so
/// we reproduce the upstream copyright/license notices here — both to credit the
/// projects and to satisfy the "retain the copyright notice" clause of the
/// permissive licenses (ISC / MIT / BSD-3 / Apache-2.0).
struct LicensesView: View {

    /// One credited component. `url` (if any) becomes a tappable source link.
    private struct Component: Identifiable {
        let id = UUID()
        let name: String
        let license: String
        let holder: String
        let url: String?
    }

    /// Code actually linked into the shipped app binary.
    private let bundled: [Component] = [
        Component(name: "Pearl Wallet Core (OysterMobile)",
                  license: "ISC",
                  holder: "© 2025–2026 Pearl Research Labs · © 2015–2016 The Decred developers",
                  url: "https://github.com/pearl-research-labs/pearl"),
        Component(name: "Go runtime & standard library",
                  license: "BSD-3-Clause",
                  holder: "© The Go Authors",
                  url: "https://go.dev"),
    ]

    /// The upstream Pearl monorepo's per-module licenses (from its LICENSE file).
    /// Listed for full attribution; the wallet core comes from the `wallet/` module.
    private let upstream: [Component] = [
        Component(name: "node/",            license: "ISC",               holder: "Pearl Research Labs", url: nil),
        Component(name: "wallet/",          license: "ISC",               holder: "Pearl Research Labs", url: nil),
        Component(name: "spv/",             license: "MIT",               holder: "Lightning Labs",      url: nil),
        Component(name: "dnsseeder/",       license: "Apache-2.0",        holder: "Pearl Research Labs", url: nil),
        Component(name: "plonky2/",         license: "MIT OR Apache-2.0", holder: "The Plonky2 Authors · Pearl Research Labs", url: nil),
        Component(name: "xmss/external/",   license: "CC0-1.0",           holder: "Public Domain",       url: nil),
        Component(name: "miner cutlass/",   license: "BSD-3-Clause",      holder: "NVIDIA",              url: nil),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(bundled) { row($0) }
            } header: {
                Text(Loc("本应用内置"))
            } footer: {
                Text(Loc("钱包核心由以下开源组件构建，在此一并致谢。"))
            }

            Section {
                ForEach(upstream) { row($0) }
            } header: {
                Text(Loc("上游开源项目"))
            } footer: {
                Link(destination: URL(string: "https://github.com/pearl-research-labs/pearl/blob/master/LICENSE")!) {
                    Text(Loc("钱包核心取自 Pearl 单仓的 wallet 模块；以下为该仓库各模块的许可声明。"))
                }
                .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .pearlListBackground()
        .navigationTitle(Loc("开源许可"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A component row: name + license badge, copyright line, and (if present) a
    /// link out to the source so the attribution is verifiable.
    @ViewBuilder private func row(_ c: Component) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Pearl.Space.xs) {
                Text(c.name).font(.body.weight(.medium))
                Spacer(minLength: Pearl.Space.xs)
                Text(c.license)
                    .font(.caption2.weight(.semibold).monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Pearl.indigo.opacity(0.14), in: Capsule())
                    .foregroundStyle(Pearl.indigo)
            }
            Text(c.holder)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = c.url, let link = URL(string: url) {
                Link(destination: link) {
                    Label(url.replacingOccurrences(of: "https://", with: ""), systemImage: "link")
                        .font(.caption2)
                }
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 2)
    }
}
