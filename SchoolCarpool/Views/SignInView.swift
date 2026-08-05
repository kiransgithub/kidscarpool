import SwiftUI

struct SignInView: View {
    @Environment(CarpoolStore.self) private var store
    @State private var phone = ""
    @State private var code = ""
    @State private var selectedParent = "Kiran"
    @State private var invitedParentName = ""
    @State private var inviteToken = ""
    @State private var inviteServerURL = ""
    @State private var codeSent = false
    @State private var joiningByInvite = false

    var body: some View {
        NavigationStack {
            ZStack {
                KCPTheme.heroGradient.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 32)
                        VStack(spacing: 12) {
                            Image("KCPLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 132, height: 132)
                                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                                .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
                            Text("KIDSCARPOOL")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Safe rides. Happy kids. Peace of mind.")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.86))
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 16) {
                            Picker("Onboarding", selection: $joiningByInvite) {
                                Text("Existing pilot profile").tag(false)
                                Text("I have an invitation").tag(true)
                            }
                            .pickerStyle(.segmented)

                            if joiningByInvite {
                                TextField("Invited parent name", text: $invitedParentName)
                                    .textContentType(.name)
                                    .padding(14)
                                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                TextField("Invitation code", text: $inviteToken)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .font(.body.monospaced())
                                    .padding(14)
                                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                TextField("Pilot server URL", text: $inviteServerURL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .padding(14)
                                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                Label("Use the Mac LAN URL included in the invitation, such as http://192.168.1.25:8090.", systemImage: "wifi")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Picker("Parent profile", selection: $selectedParent) {
                                    ForEach(store.parents.isEmpty ? CarpoolStore.seedParents : store.parents) { parent in
                                        Text("\(parent.name) — \(parent.childName)").tag(parent.name)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            TextField("Phone number", text: $phone)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                                .padding(14)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            if codeSent {
                                SecureField("6-digit code", text: $code)
                                    .keyboardType(.numberPad)
                                    .textContentType(.oneTimeCode)
                                    .padding(14)
                                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                Label("Pilot code: 123456", systemImage: "info.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                if codeSent {
                                    if joiningByInvite {
                                        Task {
                                            await store.signInInvited(
                                                phone: phone,
                                                code: code,
                                                parentName: invitedParentName,
                                                inviteToken: inviteToken,
                                                serverURL: inviteServerURL
                                            )
                                        }
                                    } else {
                                        store.signIn(phone: phone, code: code, parentName: selectedParent)
                                    }
                                } else {
                                    withAnimation { codeSent = true }
                                }
                            } label: {
                                Text(codeSent ? "Verify & Continue" : "Send Verification Code")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .foregroundStyle(.white)
                                    .background(KCPTheme.actionGradient, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .disabled(
                                joiningByInvite &&
                                (invitedParentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                 inviteToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                 inviteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            )
                        }
                        .kcpCard()

                        Label(
                            joiningByInvite
                                ? "The invitation binds your phone, parent profile and child to the private group."
                                : "Existing pilot parents can choose their profile and connect to the shared server.",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 22)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                let saved = store.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if inviteServerURL.isEmpty,
                   !saved.contains("127.0.0.1"),
                   !saved.contains("localhost") {
                    inviteServerURL = saved
                }
            }
        }
    }
}
