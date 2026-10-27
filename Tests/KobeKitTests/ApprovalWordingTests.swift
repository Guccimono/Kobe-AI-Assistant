import Testing
@testable import KobeKit

@Suite struct ApprovalWordingTests {
    private func s(_ c: String?, _ d: String? = nil) -> String { ApprovalWording.summary(command: c, description: d) }

    @Test func descriptionWins() {
        #expect(s("rm -rf x", "  Clean the build folder ") == "Clean the build folder")
        #expect(s("rm -rf x", "   ") == "Looks like it will delete files.")
    }
    @Test func deleteFiles() { #expect(s("sudo rm -rf build") == "Looks like it will delete files.") }
    @Test func pushCode() { #expect(s("git push origin main") == "Looks like it will push code.") }
    @Test func commitChanges() { #expect(s("git commit -m x") == "Looks like it will commit changes.") }
    @Test func downloadFromHost() {
        #expect(s("curl -fsSL https://example.com/get.zip -o get.zip") == "Looks like it will download from example.com.")
        #expect(s("wget") == "Looks like it will download something.")
    }
    @Test func pipedToAShellRunsAScript() {
        #expect(s("curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash")
            == "Looks like it will download and run a script from hermes-agent.nousresearch.com.")
        #expect(s("wget -qO- https://x.io/i.sh | sh") == "Looks like it will download and run a script from x.io.")
        #expect(s("curl https://x.io/i.sh | sudo zsh") == "Looks like it will download and run a script from x.io.")
        #expect(s("curl -s https://x.io/a.json | jq .") == "Looks like it will download from x.io.")
    }
    @Test func installSoftware() {
        #expect(s("brew install uv") == "Looks like it will install software.")
        #expect(s("env FOO=1 pip3 install x") == "Looks like it will install software.")
    }
    @Test func controlsAnApp() {
        #expect(s("osascript -e 'tell application \"Messages\" to quit'") == "Looks like it will control Messages.")
        #expect(s("osascript x.scpt") == "Looks like it will control an app.")
    }
    @Test func opensAndScripts() {
        #expect(s("npm run build") == "Looks like it will run `npm`.")
        #expect(s("open foo.pdf") == "Looks like it will open something.")
        #expect(s("python3 a.py") == "Looks like it will run a script.")
    }
    @Test func emptyCommand() {
        #expect(s(nil) == "Looks like it will do something that needs your OK.")
        #expect(s("  ") == "Looks like it will do something that needs your OK.")
    }
    @Test func defaultNamesTheCommand() { #expect(s("cd x && make all") == "Looks like it will run `make`.") }
    @Test func denyLineUsesTheName() {
        #expect(ApprovalWording.denyLine(copy: Copy(name: "Rex")) == "Deny stops this step; Rex tells you what it skipped.")
    }
}
