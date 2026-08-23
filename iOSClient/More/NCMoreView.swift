// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine
import NextcloudKit

/// SwiftUI implementation of the More tab content.
///
/// `NCMoreView` renders the sections provided by `NCMoreModel` using a native
/// `.insetGrouped` list. Navigation is delegated to the model through
/// `Destination`, because the view is hosted inside the UIKit-based
/// `NCMoreNavigationController`.
struct NCMoreView: View {
    @StateObject private var model: NCMoreModel
    @State private var autoUploadCounter = NCAutoUploadCounter()
    @State private var showAccountSettings = false
    @ObservedObject private var maintenanceMonitor = SouveraMaintenanceMonitor.shared
    private let loadItemsOnAppear: Bool

    init(account: String, controller: NCMainTabBarController?) {
        _model = StateObject(
            wrappedValue: NCMoreModel(
                controller: controller
            )
        )
        loadItemsOnAppear = true
    }

    init(model: NCMoreModel) {
        _model = StateObject(wrappedValue: model)
        loadItemsOnAppear = false
    }

    @MainActor
    func perform(_ destination: NCMoreModel.Destination) {
        model.perform(destination)
    }

    var body: some View {
        List {
            if maintenanceMonitor.isMaintenance {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text(NSLocalizedString("_maintenance_info_", comment: ""))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.orange.opacity(0.12))
            }

            Section {
                accountHeader
            }

            if let appsSection = model.sections.first(where: { $0.type == .moreApps }) {
                Section {
                    moreAppsRow(items: appsSection.items)
                }
            }

            Section {
                autoUploadRow
            }

            ForEach(model.sections.filter { $0.type == .regular }) { section in
                Section {
                    ForEach(section.items, id: \.identifier) { item in
                        menuRow(item)
                    }
                }
            }

            Section {
                quotaRows
            }

            Section {
                Text(SouveraBuildInfo.label)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .tint(Color.Souvera.brandPrimaryDeep)
        .sheet(isPresented: $showAccountSettings) {
            NCAccountSettingsView(model: NCAccountSettingsModel(controller: model.tabBarController, delegate: nil))
        }
        .task {
            guard loadItemsOnAppear else { return }
            await model.loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(NCGlobal.shared.notificationCenterChangeUser))) { _ in
            Task { await model.loadItems() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(NCGlobal.shared.notificationCenterServerDidUpdate))) { _ in
            Task { await model.loadItems() }
        }
        .onAppear {
            updateAutoUploadCounter()
        }
        .onDisappear {
            autoUploadCounter.stop()
        }
        .onChange(of: model.autoUploadStart) {
            updateAutoUploadCounter()
        }
    }

    private func updateAutoUploadCounter() {
        let session = model.session

        autoUploadCounter.start(account: session.account,
                                urlBase: session.urlBase,
                                userId: session.userId,
                                autoUploadStart: model.autoUploadStart)
    }

    // MARK: - Account header

    private var accountHeader: some View {
        Menu {
            ForEach(model.accountList) { item in
                Button {
                    model.switchAccount(item.account)
                } label: {
                    if item.account == model.tabBarController?.account {
                        Label("\(item.name)\(item.host.isEmpty ? "" : " – \(item.host)")", systemImage: "checkmark")
                    } else {
                        Text("\(item.name)\(item.host.isEmpty ? "" : " – \(item.host)")")
                    }
                }
            }
            Button {
                showAccountSettings = true
            } label: {
                Label(NSLocalizedString("_account_settings_", comment: ""), systemImage: "gear")
            }
        } label: {
            HStack(spacing: SouveraTokens.Spacing.sm) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.activeAccountDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.activeAccountUser.isEmpty ? model.activeAccountHost : model.activeAccountUser)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatar = model.activeAvatar {
            Image(uiImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: SouveraTokens.Metrics.avatarSize, height: SouveraTokens.Metrics.avatarSize)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Color.Souvera.brandSurface)
                Image(systemName: "person.fill")
                    .foregroundStyle(Color.Souvera.brandPrimaryDeep)
            }
            .frame(width: SouveraTokens.Metrics.avatarSize, height: SouveraTokens.Metrics.avatarSize)
        }
    }

    // MARK: - Sections

    private func moreAppsRow(items: [NCMoreModel.Item]) -> some View {
        HStack(spacing: SouveraTokens.Spacing.sm) {
            ForEach(items, id: \.identifier) { item in
                Button {
                    model.perform(item.destination)
                } label: {
                    VStack(spacing: SouveraTokens.Spacing.xs) {
                        Image(systemName: item.image)
                            .font(.icon())
                            .foregroundStyle(Color.Souvera.brandPrimaryDeep)
                            .frame(width: SouveraTokens.Metrics.iconButtonSize,
                                   height: SouveraTokens.Metrics.iconButtonSize)
                            .background(Color.Souvera.brandSurface,
                                        in: RoundedRectangle(cornerRadius: SouveraTokens.Radius.small,
                                                             style: .continuous))
                        Text(NSLocalizedString(item.titleKey, comment: ""))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, SouveraTokens.Spacing.xs)
    }

    private var autoUploadRow: some View {
        Button {
            model.openAutoUpload(counter: autoUploadCounter)
        } label: {
            HStack(spacing: SouveraTokens.Spacing.md) {
                NCFocusedAutoUploadCloudAnimation(size: 44,
                                                  cloudColor: Color.Souvera.brandPrimaryDeep,
                                                  arrowColor: model.autoUploadStart
                                                      ? Color(UIColor.systemBackground)
                                                      : Color.Souvera.brandPrimaryDeep,
                                                  isAnimated: model.autoUploadStart)
                    .frame(width: 39)

                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("_settings_autoupload_", comment: ""))
                        .font(.body)
                        .foregroundStyle(.primary)

                    if model.autoUploadStart && autoUploadCounter.isLoaded {
                        Text(autoUploadCounter.itemsLeftSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func menuRow(_ item: NCMoreModel.Item) -> some View {
        Button {
            model.perform(item.destination)
        } label: {
            Label(NSLocalizedString(item.titleKey, comment: ""), systemImage: item.image)
        }
    }

    @ViewBuilder
    private var quotaRows: some View {
        if !model.quotaDescription.isEmpty {
            VStack(alignment: .leading, spacing: SouveraTokens.Spacing.xs) {
                Text(model.quotaDescription)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                quotaProgressView
            }
        }

        if !model.quotaExternalSiteTitle.isEmpty,
           let url = model.quotaExternalSiteUrl {
            Button {
                model.perform(
                    .browser(
                        url: url,
                        title: model.quotaExternalSiteTitle
                    )
                )
            } label: {
                Text(model.quotaExternalSiteTitle)
                    .font(.footnote)
                    .lineLimit(1)
            }
        }
    }

    private var normalizedQuotaProgress: Double {
        min(max(model.quotaProgress, 0), 1)
    }

    private var quotaProgressView: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = normalizedQuotaProgress
            let warningThreshold = 0.90
            let brandColor = Color.Souvera.brandPrimaryDeep

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))

                if model.quotaProgress >= 1 {
                    Capsule()
                        .fill(Color.red)
                        .frame(width: width)
                } else {
                    Capsule()
                        .fill(brandColor)
                        .frame(width: width * min(progress, warningThreshold))

                    if progress > warningThreshold {
                        Capsule()
                            .fill(Color.red)
                            .frame(width: width * (progress - warningThreshold))
                            .offset(x: width * warningThreshold)
                    }
                }
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Preview

extension NCMoreModel {
    static var preview: NCMoreModel {
        let model = NCMoreModel(controller: nil)

        model.sections = [
            Section(
                type: .moreApps,
                items: [
                    Item(
                        titleKey: "_souvera_mail_",
                        image: "envelope.fill",
                        destination: .mail
                    ),
                    Item(
                        titleKey: "_souvera_link_",
                        image: "bubble.left.and.bubble.right.fill",
                        destination: .link
                    ),
                    Item(
                        titleKey: "_souvera_notes_",
                        image: "note.text",
                        destination: .notes
                    )
                ]
            ),
            Section(
                type: .regular,
                items: [
                    Item(
                        titleKey: "_recent_",
                        image: "clock.arrow.circlepath",
                        destination: .none
                    ),
                    Item(
                        titleKey: "_list_shares_",
                        image: "person.badge.plus",
                        destination: .none
                    ),
                    Item(
                        titleKey: "_manage_file_offline_",
                        image: "icloud.and.arrow.down",
                        destination: .none
                    ),
                    Item(
                        titleKey: "_scanned_images_",
                        image: "doc.text.viewfinder",
                        destination: .none
                    ),
                    Item(
                        titleKey: "_trash_view_",
                        image: "trash",
                        destination: .none
                    )
                ]
            ),
            Section(
                type: .regular,
                items: [
                    Item(
                        titleKey: "_settings_",
                        image: "gear",
                        destination: .none
                    )
                ]
            )
        ]

        model.quotaDescription = "You are using 919,31 GB of Unlimited"
        model.quotaProgress = 0.42

        return model
    }
}

#Preview {
    NavigationStack {
        NCMoreView(model: .preview)
    }
}
