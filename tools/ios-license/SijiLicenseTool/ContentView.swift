import SwiftUI
import UIKit

struct ContentView: View {
    @State private var deviceCodeInput = ""
    @State private var expiryDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var parsedInfo: DeviceInfo?
    @State private var activationCode = ""
    @State private var errorMessage = ""
    @State private var toastMessage = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("设备码")
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

                    VStack(alignment: .leading, spacing: 8) {
                        Text("到期日期")
                            .font(.headline)
                        DatePicker("", selection: $expiryDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }

                    HStack(spacing: 12) {
                        Button(action: decodeDeviceCode) {
                            Label("解析", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: generateActivation) {
                            Label("生成卡密", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
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
            .navigationTitle("SEC 授权工具")
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
            Text("中邮司机帮 · 本地发卡")
                .font(.subheadline.weight(.semibold))
            Text("粘贴司机发来的 DC1- 设备码，选择到期日后生成 AK1- 激活卡密。算法与 gen_license.py 完全一致，可离线使用。")
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
            row("设备", info.deviceId)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("激活卡密")
                    .font(.headline)
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
            Text("到期 \(LicenseCore.formatYmd(LicenseCore.ymd(from: expiryDate)))")
                .font(.caption)
                .foregroundColor(.secondary)
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

    private func decodeDeviceCode() {
        errorMessage = ""
        activationCode = ""
        do {
            parsedInfo = try LicenseCore.parseDeviceCode(deviceCodeInput)
            showToast("解析成功")
        } catch {
            parsedInfo = nil
            errorMessage = error.localizedDescription
        }
    }

    private func generateActivation() {
        errorMessage = ""
        do {
            let info = try LicenseCore.parseDeviceCode(deviceCodeInput)
            parsedInfo = info
            activationCode = LicenseCore.buildActivation(
                name: info.name,
                plate: info.plate,
                deviceId: info.deviceId,
                expiry: expiryDate
            )
            showToast("卡密已生成")
        } catch {
            parsedInfo = nil
            activationCode = ""
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
