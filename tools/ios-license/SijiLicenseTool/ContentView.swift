import SwiftUI
import UIKit

struct ContentView: View {
    @State private var deviceCodeInput = ""
    @State private var parsedInfo: DeviceInfo?
    @State private var activationCode = ""
    @State private var generatedPlan: LicenseCore.CardPlan?
    @State private var generatedExpiryYmd = 0
    @State private var errorMessage = ""
    @State private var toastMessage = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("设备码 DC1")
                            .font(.headline)
                        TextEditor(text: $deviceCodeInput)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("卡密类型")
                            .font(.headline)
                        HStack(spacing: 10) {
                            ForEach(LicenseCore.CardPlan.allCases) { plan in
                                Button {
                                    generateActivation(plan: plan)
                                } label: {
                                    Text(plan.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(planTint(plan))
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button(action: pasteFromClipboard) {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: decodeDeviceCode) {
                            Label("解析", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let info = parsedInfo {
                        infoCard(info)
                    }

                    if !activationCode.isEmpty {
                        activationCard
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(10)
                    }
                }
                .padding()
            }
            .navigationTitle("司机帮发码")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if !toastMessage.isEmpty {
                    Text(toastMessage)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("中邮司机帮 Android · 本地发卡")
                .font(.subheadline.weight(.semibold))
            Text("司机在安卓 SEC 面板点「复制设备码」，粘贴 DC1 后发月卡/季卡/年卡。卡密绑定姓名+车牌+核心密钥，换机可继续用。指纹 \(LicenseCore.coreKeyPrefixHex)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("密钥指纹 \(LicenseCore.coreKeyPrefixHex)")
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func infoCard(_ info: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("解析结果")
                .font(.headline)
            row("姓名", info.name)
            row("车牌", info.plate)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("激活卡密 AK1")
                    .font(.headline)
                if let plan = generatedPlan {
                    Text(plan.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                }
                Spacer()
                Button("复制") {
                    UIPasteboard.general.string = activationCode
                    showToast("已复制到剪贴板")
                }
                .font(.subheadline.weight(.semibold))
            }
            Text(activationCode)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            if generatedExpiryYmd > 0 {
                Text("到期 \(LicenseCore.formatYmd(generatedExpiryYmd))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .cornerRadius(12)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
        }
    }

    private func planTint(_ plan: LicenseCore.CardPlan) -> Color {
        switch plan {
        case .month: return Color(red: 0.13, green: 0.59, blue: 0.95)
        case .quarter: return Color(red: 0.96, green: 0.49, blue: 0.0)
        case .year: return Color(red: 0.18, green: 0.63, blue: 0.33)
        }
    }

    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string {
            deviceCodeInput = text
            showToast("已粘贴")
        }
    }

    private func decodeDeviceCode() {
        errorMessage = ""
        activationCode = ""
        generatedPlan = nil
        generatedExpiryYmd = 0
        do {
            parsedInfo = try LicenseCore.parseDeviceCode(deviceCodeInput)
            showToast("解析成功")
        } catch {
            parsedInfo = nil
            errorMessage = error.localizedDescription
        }
    }

    private func generateActivation(plan: LicenseCore.CardPlan) {
        errorMessage = ""
        do {
            let info = try LicenseCore.parseDeviceCode(deviceCodeInput)
            parsedInfo = info
            let result = LicenseCore.generateActivation(info: info, plan: plan)
            generatedPlan = plan
            generatedExpiryYmd = result.expiryYmd
            activationCode = result.code
            showToast("\(plan.rawValue)已生成")
        } catch {
            parsedInfo = nil
            activationCode = ""
            generatedPlan = nil
            generatedExpiryYmd = 0
            errorMessage = error.localizedDescription
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation {
                toastMessage = ""
            }
        }
    }
}

#Preview {
    ContentView()
}
