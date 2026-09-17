import SwiftUI

// MARK: - Create

struct CreateWalletView: View {
    @ObservedObject var store: WalletStore
    /// Extra close step after a successful commit (the add-wallet sheet closes itself).
    var onCommitted: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    enum Step { case form, seed, verify }
    @State private var step: Step = .form
    @State private var name: String
    @State private var phrase: [String] = []
    @State private var error: String?
    @State private var screenshotWarning = false

    init(store: WalletStore, onCommitted: (() -> Void)? = nil) {
        self.store = store
        self.onCommitted = onCommitted
        _name = State(initialValue: store.suggestedWalletName())
    }

    private var stepIndex: Int { step == .form ? 0 : (step == .seed ? 1 : 2) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                HStack {
                    if step != .form {
                        Button { withAnimation { step = (step == .verify ? .seed : .form); error = nil } } label: {
                            Label(Loc("上一步"), systemImage: "chevron.left")
                        }.font(.callout)
                    }
                    Spacer()
                    PearlBadge(text: Loc("步骤 %@ / 3", "\(stepIndex + 1)"), systemImage: "sparkles", tint: Pearl.violet)
                }

                PearlHero(gradient: Pearl.brandVivid, minHeight: 0) {
                    HStack(spacing: Pearl.Space.md) {
                        PearlMark(size: 52)
                        VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                            Text(Loc("创建钱包")).font(.title3.bold()).foregroundStyle(.white)
                            Text(Loc("生成助记词并安全备份")).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer(minLength: 0)
                    }
                }

                ProgressView(value: Double(stepIndex + 1), total: 3)
                    .tint(Pearl.indigo)

                switch step {
                case .form:   formStep
                case .seed:   seedStep
                case .verify: VerifyStep(words: phrase) { commit() }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.octagon")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .animation(.snappy, value: step)
        }
        .navigationTitle(Loc("创建钱包"))
    }

    private var formStep: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.lg) {
            VStack(alignment: .leading, spacing: Pearl.Space.md) {
                PearlSectionHeader(Loc("钱包名称"), systemImage: "wallet.pass")
                TextField("Pearl Wallet", text: $name).textFieldStyle(.roundedBorder)
                Label(Loc("下一步会生成 12 个助记词。请离线抄写，任何人拿到它都能转走你的资产。"),
                      systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .pearlCard()
            Button {
                guard let m = store.newMnemonic() else { error = Loc("助记词生成失败（框架未就绪）"); return }
                phrase = m.split(separator: " ").map(String.init)
                error = nil; withAnimation { step = .seed }
            } label: { Label(Loc("生成助记词"), systemImage: "key.horizontal") }
                .buttonStyle(.pearl)
                .disabled(!store.frameworkOK)
        }
    }

    private var seedStep: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.lg) {
            VStack(alignment: .leading, spacing: Pearl.Space.md) {
                PearlSectionHeader(Loc("你的助记词"), systemImage: "key.horizontal", subtitle: Loc("请按顺序离线抄写"))
                // No copy button by design — the seed must never reach the clipboard.
                // Screen-capture protection: hard-blocked on macOS, redacted while
                // recording on iOS, and a screenshot triggers a warning.
                #if os(iOS)
                // Hard block too: host the seed in a secure-text-entry canvas so iOS blanks
                // it in screenshots AND the app-switcher snapshot — the same protection the
                // Settings "查看助记词" screen uses. (Display-only here, so the non-interactive
                // secure canvas is fine.) The recording-redaction + screenshot warning stays.
                CaptureProtected { SeedGrid(words: phrase) }
                    .fixedSize(horizontal: false, vertical: true)
                    .screenCaptureProtected(active: true) { withAnimation { screenshotWarning = true } }
                #else
                SeedGrid(words: phrase)
                    .screenCaptureProtected(active: true) { withAnimation { screenshotWarning = true } }
                #endif
            }
            .pearlCard()

            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                if screenshotWarning {
                    Label(Loc("检测到截图！助记词进入相册/云相册极易泄露，请删除截图并改为离线手抄。"),
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.callout).foregroundStyle(.red)
                }
                Label(Loc("请离线手抄，切勿截图、拍照或复制——任何人拿到它都能转走你的资产。"),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Label(Loc("写下来并妥善保管后再继续。"), systemImage: "pencil.and.list.clipboard")
                    .font(.callout).foregroundStyle(.orange)
            }

            Button { withAnimation { step = .verify } } label: { Text(Loc("我已安全备份")) }
                .buttonStyle(.pearl)
        }
    }

    private func commit() {
        if store.commitWallet(name: name, mnemonic: phrase.joined(separator: " ")) {
            // Phase flips to .unlocked, swapping the NavigationStack root to the
            // dashboard. Pop this pushed onboarding view too, or it stays orphaned
            // on top of the new root and the UI freezes until the app is relaunched.
            dismiss()
            onCommitted?()
        } else {
            error = store.lastError ?? Loc("创建失败")
            step = .seed
        }
    }
}

/// 抽 3 个位置验证用户确实记下了助记词；干扰项取自助记词自身的其他词。
private struct VerifyStep: View {
    let words: [String]
    let onDone: () -> Void
    @State private var quiz: [(index: Int, options: [String])] = []
    @State private var picked: [Int: String] = [:]
    @State private var wrong = false
    @State private var shot = false

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.lg) {
            PearlSectionHeader(Loc("验证助记词"), systemImage: "checkmark.shield", subtitle: Loc("确认你已正确记录"))
            // The options are the user's REAL seed words, so the same capture protection as
            // the seed step: redacted while recording/mirroring, with a screenshot warning.
            // (Buttons must stay tappable, so the non-interactive secure-canvas can't wrap them.)
            if shot {
                Label(Loc("检测到截图！助记词极易因此泄露，请勿截图。"), systemImage: "exclamationmark.octagon.fill")
                    .font(.footnote).foregroundStyle(.red)
            }
            ForEach(quiz, id: \.index) { q in
                VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                    Text(Loc("第 %@ 个词", "\(q.index + 1)")).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: Pearl.Space.sm) {
                        ForEach(q.options, id: \.self) { opt in
                            let isPicked = picked[q.index] == opt
                            Button {
                                withAnimation { picked[q.index] = opt; wrong = false }
                            } label: {
                                Text(opt).fontWeight(isPicked ? .bold : .regular)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(isPicked ? .accentColor : .secondary)
                            .frame(minHeight: 44)
                            .accessibilityAddTraits(isPicked ? .isSelected : [])
                        }
                    }
                }
                .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
            }
            if wrong {
                Label(Loc("选择有误，请重试"), systemImage: "xmark.circle")
                    .font(.footnote).foregroundStyle(.red)
            }
            Button {
                if quiz.allSatisfy({ picked[$0.index] == words[$0.index] }) { onDone() } else { wrong = true }
            } label: { Text(Loc("确认并创建")) }
                .buttonStyle(.pearl(Pearl.positive))
                .disabled(picked.count < quiz.count)
        }
        .screenCaptureProtected(active: true) { withAnimation { shot = true } }
        .onAppear(perform: build)
    }

    private func build() {
        guard quiz.isEmpty, words.count >= 4 else { return }
        let positions = Array(0..<words.count).shuffled().prefix(3).sorted()
        quiz = positions.map { idx in
            var opts = Set([words[idx]])
            var guardCount = 0
            while opts.count < 3 && guardCount < 100 {   // guard against low-diversity phrases
                opts.insert(words.randomElement() ?? words[idx]); guardCount += 1
            }
            return (idx, Array(opts).shuffled())
        }
    }
}

// MARK: - Import

struct ImportWalletView: View {
    @ObservedObject var store: WalletStore
    /// Extra close step after a successful commit (the add-wallet sheet closes itself).
    var onCommitted: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text = ""
    @State private var error: String?
    @State private var working = false
    @State private var shot = false
    @FocusState private var focusedField: Field?
    private enum Field { case name, phrase }

    init(store: WalletStore, onCommitted: (() -> Void)? = nil) {
        self.store = store
        self.onCommitted = onCommitted
        _name = State(initialValue: store.suggestedWalletName())
    }

    // Normalize like commitWallet does — split on spaces, newlines AND tabs so a
    // phrase pasted one-word-per-line still counts correctly.
    private var words: [String] {
        text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }
    private var validCount: Bool { words.count == 12 || words.count == 24 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                PearlHero(gradient: Pearl.mint, minHeight: 0) {
                    HStack(spacing: Pearl.Space.md) {
                        PearlIconBadge(systemImage: "arrow.down.doc", gradient: Pearl.mint, size: 46)
                        VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                            Text(Loc("恢复钱包")).font(.title3.bold()).foregroundStyle(.white)
                            Text(Loc("粘贴或输入你的助记词")).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: Pearl.Space.md) {
                    PearlSectionHeader(Loc("钱包名称"), systemImage: "wallet.pass")
                    TextField("Pearl Wallet", text: $name).textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                }
                .pearlCard()

                VStack(alignment: .leading, spacing: Pearl.Space.md) {
                    HStack {
                        PearlSectionHeader(Loc("助记词（12 / 24 个词）"), systemImage: "key.horizontal")
                        Spacer()
                        Button(Loc("粘贴")) {
                            #if os(iOS)
                            if let s = UIPasteboard.general.string { text = s }
                            #else
                            if let s = NSPasteboard.general.string(forType: .string) { text = s }
                            #endif
                        }.font(.caption)
                    }
                    TextEditor(text: $text)
                        .focused($focusedField, equals: .phrase)
                        .frame(minHeight: 120)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(Pearl.Space.xs)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Pearl.Radius.xs))
                        .overlay(RoundedRectangle(cornerRadius: Pearl.Radius.xs).stroke(.secondary.opacity(0.3)))
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    Text(Loc("已输入 %@ 个词", "\(words.count)")).font(.caption)
                        .foregroundStyle(validCount ? Color.secondary : Color.orange)
                    if shot {
                        Label(Loc("检测到截图，助记词极易因此泄露，请勿截图。"), systemImage: "exclamationmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .pearlCard()
                // The phrase being recovered is just as sensitive as a freshly-created one:
                // redact it while recording/mirroring and warn on screenshot. (An editable
                // TextEditor must stay interactive, so the secure-canvas hard block can't wrap it.)
                .screenCaptureProtected(active: true) { withAnimation { shot = true } }

                if let error {
                    Label(error, systemImage: "exclamationmark.octagon")
                        .font(.footnote).foregroundStyle(.red)
                }
                Button {
                    working = true; error = nil
                    Task {
                        let m = words.joined(separator: " ")
                        guard store.isValidMnemonic(m) else { error = Loc("助记词无效（BIP39 校验失败）"); working = false; return }
                        if store.commitWallet(name: name, mnemonic: m) {
                            working = false
                            // Phase flips to .unlocked, swapping the NavigationStack
                            // root to the dashboard. Pop this pushed view too, or it
                            // stays orphaned on top of the new root and the UI freezes
                            // until the app is relaunched.
                            dismiss()
                            onCommitted?()
                        } else {
                            error = store.lastError ?? Loc("恢复失败")
                            working = false
                        }
                    }
                } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        if working { ProgressView().controlSize(.small).tint(.white) }
                        Label(working ? Loc("恢复中…") : Loc("恢复钱包"), systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.pearl)
                .disabled(working || !validCount)
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .animation(.snappy, value: working)
        }
        .navigationTitle(Loc("恢复钱包"))
        #if os(iOS)
        // 助记词用 TextEditor，回车是换行而非收起键盘——给一个「完成」按钮 + 下拉收起。
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(Loc("完成")) { focusedField = nil }.fontWeight(.semibold)
            }
        }
        #endif
    }
}

// MARK: - Seed grid

struct SeedGrid: View {
    let words: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Pearl.Space.sm)], spacing: Pearl.Space.sm) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: Pearl.Space.xs) {
                    Text("\(i + 1)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(Pearl.indigo)
                        .frame(width: 22, alignment: .trailing)
                    // 完整显示整词：单行、必要时等比缩小（不截断长单词）。
                    Text(w).font(.body.monospaced())
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .pearlCard(padding: Pearl.Space.sm, radius: Pearl.Radius.sm)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Loc("第 %@ 个词，%@", "\(i + 1)", w))
            }
        }
    }
}
