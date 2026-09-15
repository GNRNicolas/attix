import AppIntents
import AppKit
import Foundation

// Les actions que Spotlight propose quand on sélectionne Fixdock et qu'on appuie sur Tab.
//
// Elles ne dupliquent pas la logique de la fenêtre : `perform()` fait le même geste, par
// les mêmes moyens (fixdock.sh pour le Dock, le « Quitter » du menu pour une app), pour
// que l'action lancée depuis Spotlight et le bouton de la fenêtre ne puissent pas diverger.
//
// Le nom de MODULE Swift est figé à « Fixdock » dans build.sh, et c'est délibéré : le nom
// mangé que les métadonnées désignent en dépend. L'app peut donc être renommée, déplacée
// ou re-signée sans casser ses actions.
//
// openAppWhenRun = false : une action doit agir, pas ouvrir une fenêtre. Celui qui tape
// « restart dock » dans Spotlight veut un Dock qui repart, pas un tableau de bord.

struct RestartDockIntent: AppIntent {
    static var title: LocalizedStringResource = "Restart Dock"
    static var description = IntentDescription(
        "Restart the Dock. Mission Control and Launchpad come back with it. They are the same process.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let script = NSHomeDirectory() + "/bin/fixdock.sh"
        if FileManager.default.fileExists(atPath: script) {
            shell("/bin/zsh", [script, "spotlight"])
        } else {
            shell("/usr/bin/killall", ["Dock"])
        }
        return .result()
    }
}

struct RestartFinderIntent: AppIntent {
    static var title: LocalizedStringResource = "Restart Finder"
    static var description = IntentDescription(
        "Restart the Finder. It holds no unsaved data; only open Finder windows close.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        shell("/usr/bin/killall", ["Finder"])
        return .result()
    }
}

struct QuitChromeIntent: AppIntent {
    static var title: LocalizedStringResource = "Quit Chrome"
    static var description = IntentDescription(
        "Ask Chrome to quit normally. It saves its session and restores your tabs next time.")
    static var openAppWhenRun: Bool = false

    // terminate() et non un kill : Chrome enregistre sa session avant de partir.
    func perform() async throws -> some IntentResult {
        for a in NSWorkspace.shared.runningApplications
            where a.localizedName == "Google Chrome" || a.bundleIdentifier == "com.google.Chrome" {
            a.terminate()
        }
        return .result()
    }
}

struct StopStaleServersIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Stale Dev Servers"
    static var description = IntentDescription(
        "Stop dev servers whose working folder no longer exists. They are leftovers from deleted worktrees.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        for o in Orphelins.chercher() { kill(o.pid, SIGTERM) }
        return .result()
    }
}

// Les intents seuls ne suffisent pas à peupler le Tab de Spotlight : ce que le système y
// affiche, ce sont les APP SHORTCUTS. Constat tiré des métadonnées des apps système, qui
// portent toutes un `autoShortcutProviderMangledName` et une liste `autoShortcuts` : 
// celles qui n'exposent que des intents « découvrables » n'apparaissent pas.
//
// Les phrases servent aussi à Siri et au champ de recherche : ${applicationName} y est
// remplacé par le nom de l'app, ce qui est précisément ce qui permet de la renommer sans
// réécrire les phrases.
struct FixdockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RestartDockIntent(),
                    phrases: ["Restart Dock with \(.applicationName)",
                              "Fix the Dock with \(.applicationName)"],
                    shortTitle: "Restart Dock",
                    systemImageName: "arrow.clockwise")
        AppShortcut(intent: RestartFinderIntent(),
                    phrases: ["Restart Finder with \(.applicationName)"],
                    shortTitle: "Restart Finder",
                    systemImageName: "folder")
        AppShortcut(intent: QuitChromeIntent(),
                    phrases: ["Quit Chrome with \(.applicationName)"],
                    shortTitle: "Quit Chrome",
                    systemImageName: "xmark.circle")
        AppShortcut(intent: StopStaleServersIntent(),
                    phrases: ["Stop stale dev servers with \(.applicationName)"],
                    shortTitle: "Stop Stale Dev Servers",
                    systemImageName: "server.rack")
    }
}
