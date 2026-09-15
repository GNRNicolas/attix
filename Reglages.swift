import AppKit
import ServiceManagement

/// Le raccourci Spotlight livré dans le bundle, et son installation.
///
/// POURQUOI UN BOUTON ET NON UNE INSTALLATION SILENCIEUSE
/// macOS demande TOUJOURS confirmation avant d'ajouter un raccourci : il n'existe pas
/// d'API pour l'écrire dans la bibliothèque de l'usager, et c'est voulu : un raccourci
/// peut exécuter des commandes shell. On réduit donc le geste à un clic, plutôt que de
/// prétendre le supprimer.
///
/// La carte disparaît d'elle-même une fois le raccourci présent : proposer d'installer ce
/// qui est déjà installé est la meilleure façon de faire douter de tout le reste.
/// Le lancement au démarrage : c'est ce qui fait de Attix un remplaçant de memwatch.
///
/// Une alerte de mémoire n'a de valeur que si elle arrive SANS qu'on ait pensé à ouvrir
/// l'app : personne ne lance un moniteur de mémoire avant de manquer de mémoire. memwatch
/// tenait ce rôle par un LaunchAgent ; ici c'est SMAppService, qui inscrit l'app dans
/// Réglages > Général > Ouverture, là où l'usager peut la retirer d'un clic. Un agent
/// launchd posé à la main serait invisible de cet écran.
///
/// Vérifié le 14/09/2026 : `register()` fonctionne sous signature ad hoc, contrairement
/// aux notifications. Statut 3 (absent) avant, 1 (actif) après.
enum Demarrage {
    static var actif: Bool { SMAppService.mainApp.status == .enabled }

    static func active(depuis fenetre: NSWindow?) {
        do {
            try SMAppService.mainApp.register()
        } catch {
            let a = NSAlert()
            a.messageText = "Could not enable launch at login"
            a.informativeText = "\(error.localizedDescription)\n\nYou can add Attix yourself in System Settings > General > Login Items."
            a.runModal()
        }
    }
}

/// Les deux réglages qui décident de ce que Attix est : un outil qu'on ouvre, ou une
/// veille qui tourne.
///
/// Masquer l'icône du Dock passe l'app en .accessory : un moniteur qui tourne en
/// permanence n'a rien à faire dans le Dock, où l'on range ce qu'on ouvre et ferme.
///
/// Il n'y a délibérément PAS d'icône de barre des menus en échange. Le retour se fait par
/// Spotlight : lancer Attix alors qu'il tourne déjà envoie un « reopen », et la fenêtre
/// revient. C'est la même porte que pour tout le reste de l'app, plutôt qu'un vingtième
/// logo dans une barre déjà pleine.
enum Reglages {
    private static let d = UserDefaults.standard

    static var barreSeule: Bool {
        get { d.bool(forKey: "barreSeule") }
        set { d.set(newValue, forKey: "barreSeule"); applique() }
    }

    /// Le démarrage au login n'est pas stocké par nous : l'état de vérité est celui du
    /// système, que l'usager peut changer dans Réglages sans passer par l'app. Le lire
    /// plutôt que le dupliquer évite une case qui affirme le contraire de la réalité.
    static var auLogin: Bool {
        get { Demarrage.actif }
        set {
            if newValue { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
        }
    }

    static func applique() {
        NSApp.setActivationPolicy(barreSeule ? .accessory : .regular)
    }
}

enum RaccourciSpotlight {
    static let nom = "Attix"

    /// `shortcuts list` donne un nom par ligne. On compare la ligne entière : un raccourci
    /// nommé « Attix Notes » ne doit pas faire croire que le nôtre est là.
    static var installe: Bool {
        guard let sortie = shell("/usr/bin/shortcuts", ["list"]) else { return false }
        return sortie.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == nom }
    }

    static var fichier: URL? {
        Bundle.main.url(forResource: nom, withExtension: "shortcut")
    }

    /// Ouvrir le fichier passe la main à Raccourcis, qui présente sa propre confirmation.
    ///
    /// ON ANNONCE LE RÉGLAGE AVANT D'INSTALLER. Raccourcis refuse d'exécuter toute action
    /// de script tant que « Autoriser l'exécution de scripts » est décoché : c'est son
    /// réglage d'usine : et nos six gestes SONT des commandes shell. Sans ce réglage, le
    /// raccourci s'installe très bien, apparaît dans Spotlight, et échoue au moment précis
    /// où on s'en sert, avec un message qui parle de « réglages de sécurité » sans dire
    /// lequel ni où. Installer sans prévenir, c'est fabriquer cet échec.
    static let consigne = """
        1. Click Install, then confirm in Shortcuts.

        ⚠️ 2. In Shortcuts, open Settings (⌘,) → Advanced and turn on \
        "Allow Running Scripts".

        Step 2 is not optional: every Attix gesture is a shell command \
        (restart the Dock, quit Chrome, stop stale dev servers), and Shortcuts \
        refuses to run those until that box is ticked.
        """

    static func installe(depuis fenetre: NSWindow?) {
        guard let f = fichier else {
            let a = NSAlert()
            a.messageText = "Shortcut file missing"
            a.informativeText = "Attix.shortcut is not in the app bundle. Rebuild the app with build.sh."
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = "Two steps, then it works from Spotlight"
        a.informativeText = consigne
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(f)
    }
}

/// Une fenêtre de réglages minuscule : deux cases, et ce qu'elles impliquent écrit dessous.
final class FenetreReglages: NSWindowController {
    private let dock = NSButton(checkboxWithTitle: "Show in the Dock", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)

    convenience init() {
        let f = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        f.title = "Attix Settings"
        f.isReleasedWhenClosed = false
        self.init(window: f)

        dock.target = self; dock.action = #selector(change)
        login.target = self; login.action = #selector(change)

        let note = label("With the Dock icon hidden, reopen this window by launching Attix from Spotlight.",
                         taille: 11, couleur: .secondaryLabelColor)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2

        let pile = NSStackView(views: [dock, login, note])
        pile.orientation = .vertical
        pile.alignment = .leading
        pile.spacing = 10
        pile.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        pile.translatesAutoresizingMaskIntoConstraints = false
        f.contentView = pile
        NSLayoutConstraint.activate([
            note.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    func montre() {
        dock.state = Reglages.barreSeule ? .off : .on
        login.state = Reglages.auLogin ? .on : .off
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func change() {
        Reglages.barreSeule = (dock.state == .off)
        Reglages.auLogin = (login.state == .on)
    }
}

