import SwiftUI

struct BlockedSitesView: View {
    @ObservedObject var settings: AppSettings
    @State private var newDomain = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Domain entry
            HStack(spacing: 6) {
                TextField("Add domain (e.g. x.com)", text: $newDomain)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.08))
                    .cornerRadius(6)
                    .onSubmit { addDomain() }

                Button(action: addDomain) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            let missingPreset = SiteBlocker.newsAndEntertainment.filter { !settings.blockedSites.contains($0) }
            if !missingPreset.isEmpty {
                Button("Add news & entertainment (\(missingPreset.count))") {
                    settings.blockedSites += missingPreset
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Domain list
            if !settings.blockedSites.isEmpty {
                VStack(spacing: 0) {
                    ForEach(settings.blockedSites, id: \.self) { domain in
                        HStack {
                            Text(domain)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                settings.blockedSites.removeAll { $0 == domain }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
                .background(.secondary.opacity(0.04))
                .cornerRadius(6)
            }
        }
    }

    private func addDomain() {
        let domain = SiteBlocker.cleanDomain(newDomain)
        guard !domain.isEmpty, !settings.blockedSites.contains(domain) else {
            newDomain = ""
            return
        }
        settings.blockedSites.append(domain)
        newDomain = ""
    }
}
