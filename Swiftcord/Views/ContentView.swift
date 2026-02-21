import SwiftUI
import os
import DiscordKit
import DiscordKitCore

struct ContentView: View {

    private static var insetOffset: CGFloat {
        if #available(macOS 13.0, *) { return 0 } else { return -13 }
    }

    @State private var loadingGuildID: Snowflake?
    @State private var presentingOnboarding = false
    @State private var presentingAddServer = false
    @State private var skipWhatsNew = false
    @State private var whatsNewMarkdown: String?

    @StateObject private var audioManager = AudioCenterManager()

    @EnvironmentObject var gateway: DiscordGateway
    @EnvironmentObject var state: UIState
    @EnvironmentObject var accountsManager: AccountSwitcher

    @AppStorage("local.seenOnboarding") private var seenOnboarding = false
    @AppStorage("local.previousBuild") private var prevBuild: String?

    private let log = Logger(category: "ContentView")
    
    private func makeDMGuild() -> PreloadedGuild {
        PreloadedGuild(
            channels: gateway.cache.dms,
            properties: Guild(
                id: "@me",
                name: "DMs",
                owner_id: "",
                afk_timeout: 0,
                verification_level: .none,
                default_message_notifications: .all,
                explicit_content_filter: .disabled,
                roles: [], emojis: [], features: [],
                mfa_level: .none,
                system_channel_flags: 0,
                channels: gateway.cache.dms,
                premium_tier: .none,
                preferred_locale: .englishUS,
                nsfw_level: .default,
                premium_progress_bar_enabled: false
            )
        )
    }

    private func loadLastSelectedGuild() {
        if let lGID = UserDefaults.standard.string(forKey: "lastSelectedGuild"),
           gateway.cache.guilds[lGID] != nil || lGID == "@me" {
            state.selectedGuildID = lGID
        } else {
            state.selectedGuildID = "@me"
        }
    }

    // MARK: Server list
    private var serverListItems: [ServerListItem] {

        let unsortedGuilds = gateway.cache.guilds.values
            .filter { guild in
                !gateway.guildFolders.contains { $0.guild_ids.contains(guild.id) }
            }
            .sorted { $0.joined_at > $1.joined_at }   // joined_at уже не optional
            .map { ServerListItem.guild($0) }

        return unsortedGuilds + gateway.guildFolders.compactMap { folder in

            if folder.id != nil {

                let guilds = folder.guild_ids.compactMap {
                    gateway.cache.guilds[$0]
                }

                let name = folder.name ??
                    guilds.map { $0.properties.name }.joined(separator: ", ")

                return .guildFolder(
                    ServerFolder.GuildFolder(
                        name: name,
                        guilds: guilds,
                        color: folder.color.flatMap { Color(hex: $0) } ?? .accentColor
                    )
                )

            } else if let guild = gateway.cache.guilds[folder.guild_ids.first ?? ""] {
                return .guild(guild)
            }

            return nil
        }
    }

    var body: some View {

        HStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {

                    ServerButton(
                        selected: state.selectedGuildID == "@me",
                        name: "Home",
                        assetIconName: "DiscordIcon"
                    ) {
                        state.selectedGuildID = "@me"
                    }
                    .padding(.top, 4)

                    HorizontalDividerView().frame(width: 32)

                    ForEach(serverListItems) { item in
                        switch item {

                        case .guild(let guild):

                            ServerButton(
                                selected: state.selectedGuildID == guild.id ||
                                          loadingGuildID == guild.id,
                                name: guild.properties.name,
                                serverIconURL: guild.properties.iconURL(),
                                isLoading: loadingGuildID == guild.id
                            ) {
                                state.selectedGuildID = guild.id
                            }

                        case .guildFolder(let folder):

                            ServerFolder(
                                folder: folder,
                                selectedGuildID: $state.selectedGuildID,
                                loadingGuildID: loadingGuildID
                            )
                        }
                    }

                    ServerButton(
                        selected: false,
                        name: "Add a Server",
                        systemIconName: "plus",
                        bgColor: .green,
                        noIndicator: true
                    ) {
                        presentingAddServer = true
                    }
                    .padding(.bottom, 4)
                }
                .padding(.bottom, 8)
                .frame(width: 72)
            }
            .padding(.top, Self.insetOffset)
            .background(
                Color.clear
                    .background(.regularMaterial)
            )
            .clipped()
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            // MARK: ServerView

            ServerView(
                guild: state.selectedGuildID == nil
                ? nil
                : (state.selectedGuildID == "@me"
                   ? makeDMGuild()
                   : gateway.cache.guilds[state.selectedGuildID!]),
                serverCtx: state.serverCtx
            )
        }
        .safeAreaInset(edge: .top) {
            Divider()
        }
        .environmentObject(audioManager)

        .onChange(of: state.selectedGuildID) { id in
            guard let id = id else { return }
            UserDefaults.standard.set(id.description, forKey: "lastSelectedGuild")
        }

        .onChange(of: state.loadingState) { newState in

            if newState == .gatewayConn {
                loadLastSelectedGuild()
            }

            if newState == .messageLoad,
               !seenOnboarding || prevBuild != Bundle.main.infoDictionary?["CFBundleVersion"] as? String {

                if !seenOnboarding {
                    presentingOnboarding = true
                }

                Task {
                    do {
                        whatsNewMarkdown = try await GitHubAPI
                            .getReleaseByTag(
                                org: "SwiftcordX",
                                repo: "Swiftcord",
                                tag: "v\(Bundle.main.infoDictionary!["CFBundleShortVersionString"] ?? "")"
                            )
                            .body
                    } catch {
                        skipWhatsNew = true
                        return
                    }

                    presentingOnboarding = true
                }
            }
        }

        .onAppear {

            if state.loadingState == .messageLoad {
                loadLastSelectedGuild()
            }

            _ = gateway.onEvent.addHandler { evt in
                switch evt {

                case .userReady(let payload):
                    state.loadingState = .gatewayConn
                    accountsManager.onSignedIn(with: payload.user)
                    fallthrough

                case .resumed:
                    gateway.send(
                        .voiceStateUpdate,
                        data: GatewayVoiceStateUpdate(
                            guild_id: nil,
                            channel_id: nil,
                            self_mute: state.selfMute,
                            self_deaf: state.selfDeaf,
                            self_video: false
                        )
                    )

                default:
                    break
                }
            }

            _ = gateway.socket?.onSessionInvalid.addHandler {
                state.loadingState = .initial
            }
        }

        .sheet(isPresented: $presentingOnboarding) {
            seenOnboarding = true
            prevBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        } content: {
            OnboardingView(
                skipOnboarding: seenOnboarding,
                skipWhatsNew: $skipWhatsNew,
                newMarkdown: $whatsNewMarkdown,
                presenting: $presentingOnboarding
            )
        }

        .sheet(isPresented: $presentingAddServer) {
            ServerJoinView(presented: $presentingAddServer)
        }
    }

    // MARK: Types
    private enum ServerListItem: Identifiable {
        case guild(PreloadedGuild)
        case guildFolder(ServerFolder.GuildFolder)

        var id: String {
            switch self {
            case .guild(let guild): return guild.id
            case .guildFolder(let folder): return folder.id
            }
        }
    }
}
