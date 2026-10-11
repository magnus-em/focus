import Foundation

enum SiteBlocker {

    private static let helperPath = "/usr/local/bin/focustimer-blocker"
    private static let sudoersPath = "/etc/sudoers.d/focustimer"
    private static let domainFilePath = "/tmp/focustimer_domains.txt"
    private static let pfRulesPath = "/tmp/focustimer_pf.rules"
    private static let pfAnchor = "com.focustimer"
    private static let marker = "# FocusTimer"
    private static let helperVersion = "v2" // bump to force-reinstall outdated helper

    // Well-known DNS-over-HTTPS server IPs.
    // Blocking port 443 to these forces Chrome to use system DNS (which reads /etc/hosts).
    private static let dohServers = [
        "8.8.8.8", "8.8.4.4",             // Google
        "1.1.1.1", "1.0.0.1",             // Cloudflare
        "9.9.9.9", "149.112.112.112",     // Quad9
        "208.67.222.222", "208.67.220.220", // OpenDNS
        "185.228.168.168", "185.228.169.168", // CleanBrowsing
        "45.90.28.0", "45.90.30.0",       // NextDNS
        "94.140.14.14", "94.140.15.15",   // AdGuard
    ]

    // MARK: - Setup

    static var isSetUp: Bool {
        guard FileManager.default.fileExists(atPath: helperPath),
              FileManager.default.fileExists(atPath: sudoersPath) else { return false }
        // Also check that the installed helper matches the current version
        let installed = (try? String(contentsOfFile: helperPath, encoding: .utf8)) ?? ""
        return installed.contains("# \(helperVersion)")
    }

    @discardableResult
    static func setUp() -> Bool {
        try? helperScriptContent().write(
            toFile: "/tmp/focustimer_helper.sh", atomically: true, encoding: .utf8)
        try? "%admin ALL=(ALL) NOPASSWD: \(helperPath)\n".write(
            toFile: "/tmp/focustimer_sudoers", atomically: true, encoding: .utf8)

        let commands = [
            "mkdir -p /usr/local/bin",
            "mv /tmp/focustimer_helper.sh \(helperPath)",
            "chmod 755 \(helperPath)",
            "chown root:wheel \(helperPath)",
            "mv /tmp/focustimer_sudoers \(sudoersPath)",
            "chmod 440 \(sudoersPath)",
            "chown root:wheel \(sudoersPath)",
        ].joined(separator: " && ")

        runWithAdmin(commands)
        return isSetUp
    }

    // MARK: - Public API

    static func block(domains: [String]) {
        guard !domains.isEmpty else { return }
        if !isSetUp { guard setUp() else { return } }

        let cleanDomains = domains.compactMap { d -> String? in
            let c = cleanDomain(d)
            return c.isEmpty ? nil : c
        }
        guard !cleanDomains.isEmpty else { return }

        var allDomains = cleanDomains
        for rd in expandRelatedDomains(cleanDomains) where !allDomains.contains(rd) {
            allDomains.append(rd)
        }

        // Write domain list for helper script
        try? allDomains.joined(separator: "\n").write(
            toFile: domainFilePath, atomically: true, encoding: .utf8)

        // Generate pf rules: block DoH servers + resolved IPs of blocked domains
        let pfRules = generatePFRules()
        try? pfRules.write(toFile: pfRulesPath, atomically: true, encoding: .utf8)

        runHelper("block")
        setChromePolicy(blocking: true)
    }

    static func unblockAll() {
        if isSetUp {
            runHelper("unblock")
        } else {
            fallbackUnblock()
        }
        setChromePolicy(blocking: false)
    }

    static func hasStaleEntries() -> Bool {
        if let contents = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8),
           contents.contains(marker) {
            return true
        }
        if FileManager.default.fileExists(atPath: pfRulesPath) {
            return true
        }
        return false
    }

    static func cleanupIfNeeded() {
        if hasStaleEntries() {
            unblockAll()
        }
    }

    // MARK: - pf Rules

    /// Blocks DNS-over-HTTPS servers so browsers fall back to system DNS, which reads /etc/hosts.
    /// Blocked domains' own IPs are not firewalled: news and video sites sit on shared CDN
    /// IPs (Fastly, Cloudflare, Akamai, Google), so that would take down unrelated sites.
    private static func generatePFRules() -> String {
        var lines: [String] = []

        // Block DoH servers on port 443 — this disables DNS-over-HTTPS
        // so Chrome must use system DNS which respects /etc/hosts
        for ip in dohServers {
            lines.append("block drop quick proto tcp from any to \(ip) port 443")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helper Execution

    private static func runHelper(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", helperPath, command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {}
    }

    // MARK: - Fallback

    private static func fallbackUnblock() {
        var cmds = [
            "sed -i '' '/ \(marker)$/d' /etc/hosts",
            "pfctl -a \(pfAnchor) -F all 2>/dev/null || true",
            "dscacheutil -flushcache",
            "killall -HUP mDNSResponder 2>/dev/null || true",
            "rm -f \(pfRulesPath) \(domainFilePath)",
        ]
        let svcs = ["Wi-Fi", "Ethernet", "USB 10/100/1000 LAN",
                     "Thunderbolt Ethernet", "Thunderbolt Bridge"]
        for svc in svcs {
            cmds.append("networksetup -setautoproxystate \"\(svc)\" off 2>/dev/null || true")
        }
        runWithAdmin(cmds.joined(separator: " && "))
    }

    // MARK: - Chrome Policy

    private static func setChromePolicy(blocking: Bool) {
        let chrome = UserDefaults(suiteName: "com.google.Chrome")
        if blocking {
            chrome?.set(false, forKey: "BuiltInDnsClientEnabled")
            chrome?.set("off", forKey: "DnsOverHttpsMode")
        } else {
            chrome?.removeObject(forKey: "BuiltInDnsClientEnabled")
            chrome?.removeObject(forKey: "DnsOverHttpsMode")
        }
    }

    // MARK: - Related Domains

    private static func expandRelatedDomains(_ domains: [String]) -> [String] {
        var related: [String] = []
        for domain in domains {
            switch domain {
            case "x.com", "twitter.com":
                related += ["x.com", "twitter.com", "twimg.com", "t.co"]
            case "facebook.com":
                related += ["fbcdn.net", "fbsbx.com", "facebook.net", "fb.com"]
            case "instagram.com":
                related += ["cdninstagram.com", "ig.me"]
            case "reddit.com":
                related += ["redd.it", "redditstatic.com", "redditmedia.com"]
            case "youtube.com":
                related += ["youtu.be", "ytimg.com", "googlevideo.com", "youtube-nocookie.com"]
            case "tiktok.com":
                related += ["tiktokcdn.com", "tiktokv.com"]
            case "linkedin.com":
                related += ["licdn.com"]
            case "twitch.tv":
                related += ["jtvnw.net", "ttvnw.net"]
            case "netflix.com":
                related += ["nflxvideo.net", "nflximg.net", "nflxso.net", "nflxext.com"]
            default:
                break
            }
        }
        return related
    }

    // MARK: - Presets

    static let newsAndEntertainment = [
        // News
        "cnn.com", "foxnews.com", "msnbc.com", "nbcnews.com", "abcnews.go.com", "cbsnews.com",
        "nytimes.com", "washingtonpost.com", "wsj.com", "usatoday.com", "latimes.com", "nypost.com",
        "bbc.com", "bbc.co.uk", "theguardian.com", "dailymail.co.uk", "reuters.com", "apnews.com",
        "bloomberg.com", "cnbc.com", "ft.com", "economist.com", "businessinsider.com", "forbes.com",
        "npr.org", "politico.com", "axios.com", "thehill.com", "semafor.com", "huffpost.com",
        "theatlantic.com", "newyorker.com", "vox.com", "slate.com", "time.com", "newsweek.com",
        "vice.com", "buzzfeed.com", "breitbart.com", "drudgereport.com", "theverge.com",
        "techcrunch.com", "wired.com", "arstechnica.com", "engadget.com", "news.ycombinator.com",
        "news.google.com", "news.yahoo.com", "msn.com", "substack.com",
        // Video & streaming
        "youtube.com", "netflix.com", "hulu.com", "disneyplus.com", "max.com", "primevideo.com",
        "peacocktv.com", "paramountplus.com", "twitch.tv", "crunchyroll.com", "kick.com",
        // Social
        "x.com", "twitter.com", "reddit.com", "instagram.com", "facebook.com", "tiktok.com",
        "threads.net", "bsky.app", "tumblr.com", "pinterest.com", "9gag.com", "imgur.com",
        // Sports, celebrity, games, movies
        "espn.com", "bleacherreport.com", "theathletic.com", "barstoolsports.com", "tmz.com",
        "people.com", "eonline.com", "imdb.com", "rottentomatoes.com", "letterboxd.com",
        "ign.com", "kotaku.com", "polygon.com", "gamespot.com",
    ]

    // MARK: - Domain Cleaning

    static func cleanDomain(_ input: String) -> String {
        var d = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = d.range(of: "://") { d = String(d[range.upperBound...]) }
        if let slash = d.firstIndex(of: "/") { d = String(d[d.startIndex..<slash]) }
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        return d
    }

    // MARK: - Admin

    private static func runWithAdmin(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    // MARK: - Helper Script

    private static func helperScriptContent() -> String {
        """
        #!/bin/bash
        # v2
        set -euo pipefail

        MARKER="# FocusTimer"
        HOSTS="/etc/hosts"
        DOMAIN_FILE="/tmp/focustimer_domains.txt"
        PF_RULES="/tmp/focustimer_pf.rules"
        PF_ANCHOR="com.focustimer"

        block() {
            [ -f "$DOMAIN_FILE" ] || exit 1

            # 1. Update /etc/hosts
            sed "/ ${MARKER}$/d" "$HOSTS" > /tmp/hosts_ft_clean

            while IFS= read -r domain || [ -n "$domain" ]; do
                [ -z "$domain" ] && continue
                printf '127.0.0.1 %s %s\\n' "$domain" "$MARKER" >> /tmp/hosts_ft_clean
                case "$domain" in
                    www.*) ;;
                    *) printf '127.0.0.1 www.%s %s\\n' "$domain" "$MARKER" >> /tmp/hosts_ft_clean ;;
                esac
                for pfx in api m mobile cdn static assets media edge app; do
                    printf '127.0.0.1 %s.%s %s\\n' "$pfx" "$domain" "$MARKER" >> /tmp/hosts_ft_clean
                done
            done < "$DOMAIN_FILE"

            mv /tmp/hosts_ft_clean "$HOSTS"

            # 2. Load pf firewall rules (blocks DoH + domain IPs)
            if [ -f "$PF_RULES" ]; then
                pfctl -a "$PF_ANCHOR" -f "$PF_RULES" 2>/dev/null || true
                pfctl -e 2>/dev/null || true
            fi

            # 3. Disable auto-proxy (cleanup from old PAC approach)
            for svc in "Wi-Fi" "Ethernet" "USB 10/100/1000 LAN" "Thunderbolt Ethernet" "Thunderbolt Bridge"; do
                networksetup -setautoproxystate "$svc" off 2>/dev/null || true
            done

            # 4. Flush DNS
            dscacheutil -flushcache
            killall -HUP mDNSResponder 2>/dev/null || true
        }

        unblock() {
            # Remove /etc/hosts entries
            grep -q "$MARKER" "$HOSTS" 2>/dev/null && sed -i '' "/ ${MARKER}$/d" "$HOSTS"

            # Remove pf rules
            pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true

            # Disable auto-proxy (cleanup)
            for svc in "Wi-Fi" "Ethernet" "USB 10/100/1000 LAN" "Thunderbolt Ethernet" "Thunderbolt Bridge"; do
                networksetup -setautoproxystate "$svc" off 2>/dev/null || true
            done

            # Cleanup temp files
            rm -f "$PF_RULES" "$DOMAIN_FILE" /tmp/focustimer_proxy_*.pac /tmp/focustimer_pac_*.txt

            # Flush DNS
            dscacheutil -flushcache
            killall -HUP mDNSResponder 2>/dev/null || true
        }

        case "${1:-}" in
            block) block ;;
            unblock) unblock ;;
            *) echo "Usage: $0 {block|unblock}" >&2; exit 1 ;;
        esac
        """
    }
}
