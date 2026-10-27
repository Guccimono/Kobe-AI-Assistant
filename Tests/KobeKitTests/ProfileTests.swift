import Testing
@testable import KobeKit

@Suite struct ProfileTests {
    let p = Profile(name: "Mia", role: "my chief of staff", tone: .warm)

    @Test func soulStartsWithMarker() {
        let s = ProfileFiles.soul(p)
        #expect(s.hasPrefix(ProfileFiles.marker + "\n\n# Mia\n\n"))
        #expect(s.contains("You are Mia, my chief of staff."))
        #expect(s.contains("Be warm: friendly and encouraging, still concise."))
        #expect(s.hasSuffix("\n"))
    }

    @Test func neverWritesOverAnEditedSoul() {
        #expect(ProfileFiles.mayWriteSoul(existing: nil))
        #expect(ProfileFiles.mayWriteSoul(existing: ProfileFiles.soul(p)))
        #expect(ProfileFiles.mayWriteSoul(existing: "  " + ProfileFiles.marker + "\nmore"))
        #expect(!ProfileFiles.mayWriteSoul(existing: "You are my pirate."))
        #expect(!ProfileFiles.mayWriteSoul(existing: ""))
        #expect(!ProfileFiles.mayWriteSoul(existing: "# Mine\n" + ProfileFiles.marker))
    }

    @Test func systemPromptNamesTheAssistantAndTone() {
        #expect(ProfileFiles.systemPrompt(p) == "You are Mia, my chief of staff. Be warm: friendly and encouraging, still concise.")
        let d = Profile(name: "  ", role: "", tone: .direct)
        #expect(ProfileFiles.systemPrompt(d) == "You are Kobe, a personal assistant living in the notch of this Mac. Be direct: answer first, reasons after, no padding.")
        #expect(ProfileFiles.systemPrompt(Profile(name: "K", role: "", tone: .brief)).hasSuffix("Be brief: one or two sentences unless asked for more."))
    }

    @Test func profileMarkdownListsFields() {
        #expect(ProfileFiles.profileMarkdown(p) == "# Profile\n- name: Mia\n- role: my chief of staff\n- tone: warm\n")
        #expect(ProfileFiles.profileMarkdown(Profile(name: "", role: "", tone: .brief)) == "# Profile\n- name: Kobe\n- role: \n- tone: brief\n")
    }

    @Test func helloIsTheCopySentence() {
        #expect(ProfileFiles.hello(p) == Copy(name: "Mia").hello(role: p.role))
    }

    @Test func crlfSoulStillCountsAsOurs() {
        #expect(ProfileFiles.mayWriteSoul(existing: ProfileFiles.marker + "\r\nmore"))
        #expect(!ProfileFiles.mayWriteSoul(existing: "\r\n" + ProfileFiles.marker))
    }

    @Test func interiorNewlinesCollapse() {
        let q = Profile(name: "Mi\na", role: "a\nb\r\n  c", tone: .direct)
        #expect(ProfileFiles.profileMarkdown(q) == "# Profile\n- name: Mi a\n- role: a b c\n- tone: direct\n")
        #expect(ProfileFiles.systemPrompt(q).hasPrefix("You are Mi a, a b c. "))
        #expect(ProfileFiles.soul(q).contains("\n# Mi a\n"))
    }
}
