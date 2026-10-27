// The `Kobe` executable: everything lives in the KobeApp library, so the tests can reach it.
import KobeApp

MainActor.assumeIsolated { KobeApp.run() }
