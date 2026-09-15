import AppKit
import Darwin
import ServiceManagement

// Fixdock Lab : la fenêtre actionnable de Fixdock.
//
// Principe directeur, tiré de l'échec de memwatch v3 : une alerte qui nomme un problème
// sans offrir le geste est un cul-de-sac. Ici, toute ligne affichée porte son action.
//
// Ce que l'app ne fait JAMAIS :
//   - tuer un processus de sa propre initiative (aucun automatisme, aucun seuil d'action) ;
//   - envoyer SIGKILL à une app : on passe par terminate(), qui la laisse enregistrer ;
//   - proposer de quitter un processus qui détient du travail non sauvé (liste PROTEGES).
//
// AppKit et non SwiftUI, comme nutip et Eyesaver : la toolchain installée ici (Command
// Line Tools 6.3.3 sur un SDK 6.3.2) refuse de reconstruire le .swiftinterface de SwiftUI.
// AppKit est de l'Objective-C, il n'a pas ce verrou de version. C'est aussi le style
// maison : une app de plus, pas une pile de plus.
//
// L'UI est en anglais, les commentaires en français : convention du dépôt.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Mesures système
// ─────────────────────────────────────────────────────────────────────────────

struct Memoire {
    var total: UInt64 = 0
    var libre: UInt64 = 0
    var compresse: UInt64 = 0
    var swapUtilise: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pression: Int = 1          // 1 normal, 2 warning, 4 critical (le noyau décide)

    // Le niveau de pression vient du noyau plutôt que d'un seuil maison : c'est la même
    // valeur sur laquelle Jetsam s'appuie pour tuer. Inventer notre propre seuil
    // reviendrait à deviner ce que le système sait déjà.
    static func releve() -> Memoire {
        var m = Memoire()
        m.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            m.libre = UInt64(stats.free_count) * page
            m.compresse = UInt64(stats.compressor_page_count) * page
        }

        var xsw = xsw_usage()
        var taille = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &taille, nil, 0) == 0 {
            m.swapUtilise = xsw.xsu_used
            m.swapTotal = xsw.xsu_total
        }

        var niveau: Int32 = 1
        var n = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &niveau, &n, nil, 0) == 0 {
            m.pression = Int(niveau)
        }
        return m
    }

    var etat: (texte: String, couleur: NSColor) {
        switch pression {
        case 4:  return ("Critical", .systemRed)
        case 2:  return ("Under pressure", .systemOrange)
        default: return ("Healthy", .systemGreen)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Consommateurs
// ─────────────────────────────────────────────────────────────────────────────

struct Consommateur {
    let nom: String
    let octets: UInt64
    let processus: Int
    let pids: [Int32]
    let appActive: NSRunningApplication?
    let sensible: Bool          // porte du travail en cours, prévenir, pas interdire

    // Tout ce qui a des pids peut être arrêté. « Sensible » ne retire pas le bouton, il
    // change l'avertissement : la première version affichait « in use » et s'arrêtait là,
    // ce qui est précisément le cul-de-sac que cette app existe pour supprimer.
    var peutQuitter: Bool { !pids.isEmpty }
}

// Arrêter ces processus ne coûte pas du travail non enregistré : ça coûte la SESSION.
// WindowServer tient l'affichage, loginwindow la session ouverte. Ici l'avertissement ne
// suffit pas, la bonne conception est de ne pas les faire figurer du tout : une ligne
// sur laquelle aucun geste n'est sûr n'a rien à faire dans une liste de gestes.
let INTOUCHABLES: Set<String> = [
    "WindowServer", "loginwindow", "launchd", "kernel_task", "logind", "UserEventAgent",
]

// La phrase qui dit ce qu'on risque à fermer. Elle remplace un refus par un choix éclairé.
let RISQUES: [String: String] = [
    "cmux": "This closes every terminal tab and any command still running in them.",
    "Claude Code": "This ends all running Claude Code sessions, including this one.",
    "VS Code": "Unsaved files will prompt you before closing.",
    "Cursor": "Unsaved files will prompt you before closing.",
    "Terminal": "This closes every terminal tab and any command still running in them.",
    "Node": "These are dev servers or build tools. Any unsaved build state is lost.",
    "Finder": "Finder relaunches by itself, but open Finder windows close.",
    "Spotlight indexing": "macOS restarts it within minutes and will re-index from scratch.",
]

// Ce qui porte du travail en cours : terminaux, agents, éditeurs. Ces lignes gardent leurs
// boutons : elles gagnent un avertissement nommé (RISQUES) et un dialogue dont le bouton
// par défaut est Cancel. Chrome n'y est pas : il restaure ses onglets tout seul.
let PROTEGES: Set<String> = [
    "cmux", "Claude Code", "Node", "Terminal", "iTerm2", "Ghostty", "Alacritty",
    "VS Code", "Xcode", "Cursor", "WindowServer", "loginwindow", "Finder"
]

// Le nom qu'un processus porte sur le disque n'est pas celui qu'on reconnaît à l'écran.
// `claude`, `claude.exe` et `node` sont trois exécutables d'une même chose vue de l'usager.
// Sans ce regroupement, l'app reproduit le défaut de memwatch : elle éparpille le coupable
// en plusieurs lignes anodines au lieu d'en montrer une seule, lourde.
let ALIAS: [String: String] = [
    "claude": "Claude Code",
    "claude.exe": "Claude Code",
    "Claude": "Claude",            // l'app de bureau, distincte du CLI
    "node": "Node",
    "bun": "Node",
    "Code": "VS Code",
    "Visual Studio Code": "VS Code",
    "Google Chrome": "Chrome",
    "com.apple.WebKit.WebContent": "WebKit pages",
    "mdworker_shared": "Spotlight indexing",
    "mds_stores": "Spotlight indexing",
    "mds": "Spotlight indexing",
]

/// Ce que les trois chiffres sous la barre veulent dire. Ils sont affichés parce qu'ils
/// disent l'état réel de la machine ; encore faut-il savoir de quoi on parle, « swap » et
/// « compressed » n'étant pas du vocabulaire courant.
///
/// Un TABLEAU et non une longue chaîne. La version d'avant était un littéral multiligne
/// avec des `\` de continuation : Swift joint bien les lignes, mais conserve l'indentation
/// de celle qui suit, et le texte arrivait truffé de blocs d'espaces. Un terme, sa
/// définition, et la mise en forme faite au moment de l'affichage.
let LEXIQUE: [(terme: String, sens: String)] = [
    ("Free", "Memory nothing is using right now."),
    ("Swap", "Memory moved out to disk because RAM ran out. Disk is far slower than RAM, "
           + "so a large swap is what makes the machine feel stuck."),
    ("Compressed", "Memory squeezed to fit more of it in RAM. Still fast, and still in RAM. "
                 + "This is the step before swapping."),
]

/// Un « ? » qui explique le vocabulaire, AU CLIC.
///
/// La première version s'en remettait à `toolTip`. Deux essais, deux échecs : rien ne
/// s'ouvrait. Une infobulle dépend du survol, donc de la vitesse du pointeur, du délai
/// système et du fait que la vue soit réellement atteinte par la souris ; quand elle ne
/// vient pas, elle ne dit pas pourquoi. Un clic, lui, se constate. Le `toolTip` reste posé
/// en prime pour qui s'arrête dessus, mais ce n'est plus lui qui porte la fonction.
final class Aide: NSButton {
    private let entrees: [(terme: String, sens: String)]
    private var popover: NSPopover?

    /// Le texte mis en forme : le terme en gras, sa définition à la ligne.
    private var texte: NSAttributedString {
        let t = NSMutableAttributedString()
        for (i, e) in entrees.enumerated() {
            if i > 0 { t.append(NSAttributedString(string: "\n\n")) }
            t.append(NSAttributedString(
                string: e.terme + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: NSColor.labelColor]))
            t.append(NSAttributedString(
                string: e.sens,
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return t
    }

    init(_ entrees: [(terme: String, sens: String)]) {
        self.entrees = entrees
        super.init(frame: .zero)
        title = "?"
        font = .systemFont(ofSize: 10, weight: .bold)
        contentTintColor = .secondaryLabelColor
        bezelStyle = .circular
        setButtonType(.momentaryPushIn)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        toolTip = entrees.map { "\($0.terme) : \($0.sens)" }.joined(separator: "\n")
        target = self
        action = #selector(bascule)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
        ])
        // Sans ça, une pile horizontale peut comprimer le bouton jusqu'à le rendre
        // invisible : il n'y aurait plus rien à viser.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func bascule() {
        if let p = popover, p.isShown { p.close(); popover = nil; return }
        let contenu = NSViewController()
        let vue = NSView()
        let l = NSTextField(labelWithAttributedString: texte)
        l.lineBreakMode = .byWordWrapping
        l.translatesAutoresizingMaskIntoConstraints = false
        vue.addSubview(l)
        NSLayoutConstraint.activate([
            l.widthAnchor.constraint(equalToConstant: 300),
            l.leadingAnchor.constraint(equalTo: vue.leadingAnchor, constant: 16),
            l.trailingAnchor.constraint(equalTo: vue.trailingAnchor, constant: -16),
            l.topAnchor.constraint(equalTo: vue.topAnchor, constant: 14),
            l.bottomAnchor.constraint(equalTo: vue.bottomAnchor, constant: -14),
        ])
        contenu.view = vue
        let p = NSPopover()
        p.contentViewController = contenu
        p.behavior = .transient            // un clic ailleurs le referme
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = p
    }
}

enum Sonde {
    // `ps` plutôt que proc_pidinfo : une seule traversée, pas de droits particuliers,
    // et c'est exactement ce que memwatch mesure déjà : deux outils, un même chiffre.
    static func lignesPs() -> [(rss: UInt64, pid: Int32, chemin: String)] {
        guard let sortie = shell("/bin/ps", ["-Ao", "rss=,pid=,comm="]) else { return [] }
        return sortie.split(separator: "\n").compactMap { ligne in
            // On découpe À LA MAIN, et ce n'est pas de la coquetterie.
            //
            // `split(maxSplits: 2, omittingEmptySubsequences: true)` semblait fait pour ça.
            // Il ne l'est pas : maxSplits compte les séparations EFFECTUÉES, y compris
            // celles qui ne produisent qu'une sous-séquence vide ensuite omise. `ps` aligne
            // ses colonnes à droite, donc toute ligne dont le RSS n'occupe pas la largeur
            // entière commence par des espaces : ces espaces consommaient le premier split,
            // il n'en restait qu'un, on obtenait 2 champs au lieu de 3, et la ligne était
            // écartée. Résultat mesuré : Chrome affiché à 205 Mo au lieu de 1 273, parce
            // que seuls ses processus à RSS le plus large étaient comptés. Un outil qui
            // mesure la mémoire ne peut pas se permettre d'en oublier la moitié en silence.
            var reste = ligne.drop { $0 == " " }
            func mot() -> Substring? {
                guard let i = reste.firstIndex(of: " ") else { return nil }
                defer { reste = reste[i...].drop { $0 == " " } }
                return reste[..<i]
            }
            guard let a = mot(), let rss = UInt64(a),
                  let b = mot(), let pid = Int32(b) else { return nil }
            let chemin = String(reste).trimmingCharacters(in: .whitespaces)
            return chemin.isEmpty ? nil : (rss * 1024, pid, chemin)
        }
    }

    // Regroupe les helpers sous leur app : sans ça Chrome apparaît en vingt lignes de
    // 40 Mo au lieu d'une de 2,8 Go, et le coupable se cache dans sa propre poussière.
    static func nomApp(_ chemin: String) -> String {
        if let r = chemin.range(of: #"/[^/]+\.app/"#, options: .regularExpression) {
            var s = String(chemin[r])
            s.removeFirst()          // le / initial
            s.removeLast(5)          // ".app/"
            return s
        }
        return joli((chemin as NSString).lastPathComponent)
    }

    /// Certains services système portent leur identifiant inversé comme nom de fichier
    /// (« com.apple.SafariPlatformSupport.Helper »). Affiché tel quel, c'est du jargon
    /// illisible : le même défaut que le « mdworker_shared » de memwatch. On garde les
    /// deux derniers segments, qui sont la partie parlante.
    static func joli(_ nom: String) -> String {
        guard nom.hasPrefix("com."), nom.filter({ $0 == "." }).count >= 2 else { return nom }
        let bouts = nom.split(separator: ".").map(String.init)
        return bouts.suffix(2).joined(separator: " ")
    }

    static func consommateurs(minimum: UInt64 = 60 * 1024 * 1024) -> [Consommateur] {
        var total: [String: UInt64] = [:]
        var compte: [String: Int] = [:]
        var brut: [String: String] = [:]     // nom affiché -> nom d'origine, pour retrouver l'app
        var pids: [String: [Int32]] = [:]
        for l in lignesPs() {
            let origine = nomApp(l.chemin)
            let nom = ALIAS[origine] ?? origine
            total[nom, default: 0] += l.rss
            compte[nom, default: 0] += 1
            pids[nom, default: []].append(l.pid)
            if brut[nom] == nil { brut[nom] = origine }
        }
        // DEUX noms pour un même processus, et il faut les deux.
        //
        // `processName` rend le nom de l'EXÉCUTABLE (« fixdock »), alors que la liste
        // regroupe les processus sous le nom de leur BUNDLE (« Fixdock »). Ne filtrer que
        // le premier laissait l'app se ranger parmi les consommateurs à surveiller, avec
        // son propre bouton Quit.
        let moi = ProcessInfo.processInfo.processName
        let monBundle = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Fixdock"
        let actives = NSWorkspace.shared.runningApplications
        return total.filter {
            $0.value >= minimum && $0.key != moi && $0.key != monBundle
                && $0.key != "Fixdock Lab"
                && !INTOUCHABLES.contains($0.key)
        }
            .map { (nom, octets) in
                let cible = brut[nom] ?? nom
                let app = actives.first { $0.localizedName == nom || $0.localizedName == cible }
                    ?? actives.first { $0.bundleURL?.deletingPathExtension().lastPathComponent == cible }
                return Consommateur(nom: nom, octets: octets,
                                    processus: compte[nom] ?? 1,
                                    pids: pids[nom] ?? [],
                                    appActive: app,
                                    sensible: PROTEGES.contains(nom))
            }
            .sorted { $0.octets > $1.octets }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Jetsam : ce que le noyau a déjà tué
// ─────────────────────────────────────────────────────────────────────────────

// Le niveau de pression dit ce qui se passe MAINTENANT. Jetsam dit ce qui s'est déjà
// produit : à chaque fois que le noyau tue un processus faute de mémoire, il dépose un
// rapport dans /Library/Logs/DiagnosticReports. C'est le signal qui a identifié le
// problème d'origine, et c'est le seul qui prouve qu'une app n'a pas « planté » mais a
// été tuée.
//
// CE QUE MEMWATCH RATE ICI, et qu'on corrige : il annonce « le noyau a tué des process,
// ferme une app » pour TOUT rapport. Or le champ `reason` distingue deux situations sans
// rapport entre elles. `per-process-limit` : le processus a dépassé SA propre limite, une
// extension qui déborde, la machine allait bien et il n'y a rien à faire. Les autres
// (vm-pageshortage, highwater…) : la mémoire de la machine manquait vraiment. Alerter de
// la même façon dans les deux cas, c'est apprendre à ignorer l'alerte.
enum Jetsam {
    static let dossier = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")

    /// Le nom porte la date (JetsamEvent-2026-09-14-164006.ips) : l'ordre alphabétique
    /// décroissant est l'ordre chronologique, sans avoir à interroger le disque.
    static func dernier() -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: dossier,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("JetsamEvent") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Un .ips est une ligne d'en-tête JSON, puis le corps JSON. Seuls les processus
    /// réellement tués portent un `reason`.
    static func victime(_ url: URL) -> (nom: String, raison: String)? {
        guard let brut = try? String(contentsOf: url, encoding: .utf8),
              let saut = brut.firstIndex(of: "\n"),
              let d = String(brut[brut.index(after: saut)...]).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ps = j["processes"] as? [[String: Any]] else { return nil }
        for p in ps {
            if let raison = p["reason"] as? String, let nom = p["name"] as? String {
                return (ALIAS[nom] ?? nom, raison)
            }
        }
        return nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Serveurs de dev orphelins
// ─────────────────────────────────────────────────────────────────────────────

// Un orphelin n'est pas deviné, il est PROUVÉ : son répertoire de travail n'existe plus
// sur le disque. C'est la signature d'un worktree supprimé dont le dev server a survécu.
// Aucune heuristique sur le nom ou le port : seulement ce fait vérifiable.
struct Orphelin {
    let pid: Int32
    let octets: UInt64
    let dossierDisparu: String
}

enum Orphelins {
    static func chercher() -> [Orphelin] {
        var pids: [Int32] = []
        for nom in ["node", "bun", "deno", "esbuild"] {
            guard let s = shell("/usr/bin/pgrep", ["-x", nom]) else { continue }
            pids += s.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        }
        var trouves: [Orphelin] = []
        for pid in pids {
            guard let n = shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"]),
                  let cwd = n.split(separator: "\n").first(where: { $0.hasPrefix("n") })
                      .map({ String($0.dropFirst()) }) else { continue }
            if !FileManager.default.fileExists(atPath: cwd) {
                let rss = shell("/bin/ps", ["-o", "rss=", "-p", "\(pid)"])
                    .flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                trouves.append(Orphelin(pid: pid, octets: rss * 1024, dossierDisparu: cwd))
            }
        }
        return trouves
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Utilitaires
// ─────────────────────────────────────────────────────────────────────────────

@discardableResult
func shell(_ binaire: String, _ args: [String]) -> String? {
    guard FileManager.default.isExecutableFile(atPath: binaire) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binaire)
    p.arguments = args
    let tube = Pipe()
    p.standardOutput = tube
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = tube.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

func go(_ octets: UInt64) -> String {
    let g = Double(octets) / 1_073_741_824
    return g < 0.1 ? String(format: "%.0f MB", Double(octets) / 1_048_576)
                   : String(format: "%.1f GB", g)
}

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
/// Le lancement au démarrage : c'est ce qui fait de Fixdock un remplaçant de memwatch.
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
            a.informativeText = "\(error.localizedDescription)\n\nYou can add Fixdock yourself in System Settings > General > Login Items."
            a.runModal()
        }
    }
}

/// Les deux réglages qui décident de ce que Fixdock est : un outil qu'on ouvre, ou une
/// veille qui tourne.
///
/// Masquer l'icône du Dock passe l'app en .accessory : un moniteur qui tourne en
/// permanence n'a rien à faire dans le Dock, où l'on range ce qu'on ouvre et ferme.
///
/// Il n'y a délibérément PAS d'icône de barre des menus en échange. Le retour se fait par
/// Spotlight : lancer Fixdock alors qu'il tourne déjà envoie un « reopen », et la fenêtre
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
    static let nom = "Fixdock"

    /// `shortcuts list` donne un nom par ligne. On compare la ligne entière : un raccourci
    /// nommé « Fixdock Notes » ne doit pas faire croire que le nôtre est là.
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

        Step 2 is not optional: every Fixdock gesture is a shell command \
        (restart the Dock, quit Chrome, stop stale dev servers), and Shortcuts \
        refuses to run those until that box is ticked.
        """

    static func installe(depuis fenetre: NSWindow?) {
        guard let f = fichier else {
            let a = NSAlert()
            a.messageText = "Shortcut file missing"
            a.informativeText = "Fixdock.shortcut is not in the app bundle. Rebuild the app with build.sh."
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Interface
// ─────────────────────────────────────────────────────────────────────────────
//
// La fenêtre est un tableau de bord : on l'ouvre pour VOIR où passe la mémoire, et chaque
// ligne porte son geste. Les actions atteignables sans ouvrir la fenêtre : quand plus rien
// ne répond, ne vivent pas ici : ce sont des bundles séparés que Spotlight indexe
// (voir actions.sh). Une fenêtre ne sert à rien quand l'interface est gelée.

func label(_ texte: String, taille: CGFloat = 12, poids: NSFont.Weight = .regular,
           couleur: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: texte)
    l.font = .systemFont(ofSize: taille, weight: poids)
    l.textColor = couleur
    l.lineBreakMode = .byTruncatingTail
    return l
}

// NSButton ne retient pas de closure : la cible d'un bouton AppKit est un couple
// (objet, sélecteur). On emballe donc l'action dans le bouton lui-même.
final class Bouton: NSButton {
    var geste: (() -> Void)?
    /// `indice` affiche le raccourci à droite du libellé, dans le bouton : le patron
    /// maison (Nutip écrit « Browse ⌘F »). Un raccourci qui ne se voit pas ne s'apprend pas.
    init(_ titre: String, indice: String? = nil, _ action: (() -> Void)? = nil) {
        self.geste = action
        super.init(frame: .zero)
        if let indice {
            let t = NSMutableAttributedString(
                string: titre + "  ",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.labelColor])
            t.append(NSAttributedString(
                string: indice,
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: NSColor.tertiaryLabelColor]))
            self.attributedTitle = t
        } else {
            self.title = titre
        }
        self.bezelStyle = .rounded
        self.controlSize = .small
        self.font = .systemFont(ofSize: 11)
        self.target = self
        self.action = #selector(declenche)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func declenche() { geste?() }

    /// Vert et « Done » quand le geste est déjà accompli.
    ///
    /// La carte se masquait une fois la chose faite. C'était un aveu escamoté : rien ne
    /// disait plus si l'arrière-plan était actif ou si l'app avait simplement cessé d'en
    /// parler. Un état visible vaut mieux qu'une absence, et il se relit sans rien rouvrir.
    ///
    /// Le bouton reste CLIQUABLE : désactivé, AppKit le délave et le vert se perd. Le
    /// deuxième clic est d'ailleurs utile — réinstaller un raccourci mis à jour, par
    /// exemple. L'infobulle le dit.
    func marqueFait(_ fait: Bool, titre: String, rappel: String) {
        // LE FOND EST PEINT SUR LE LAYER, PAS PAR `bezelColor`.
        //
        // C'est ce qui explique le vert qui virait au gris sans raison apparente : AppKit
        // délave les contrôles teintés dès que leur fenêtre n'est plus la fenêtre clé. Le
        // bouton repassait donc au gris en cliquant ailleurs, et revenait au vert en
        // revenant — un état qui semblait clignoter alors que rien n'avait changé. Écarté
        // d'emblée : la détection, vérifiée stable (huit lectures de `shortcuts list`,
        // 40 ms, aucun échec). Un layer, lui, ne dépend pas du focus.
        wantsLayer = true
        if fait {
            isBordered = false
            layer?.cornerRadius = 5
            // Le systemGreen brut est un vert de signalisation : il attire l'œil, or ce
            // bouton dit justement qu'il n'y a plus rien à regarder. Éclairci d'un tiers
            // vers le blanc, il se lit comme un état acquis et non comme une alerte.
            layer?.backgroundColor = NSColor.systemGreen
                .blended(withFraction: 0.3, of: .white)?.cgColor
            attributedTitle = NSAttributedString(
                string: "✓ Done",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.white])
            toolTip = rappel
        } else {
            isBordered = true
            layer?.backgroundColor = nil
            attributedTitle = NSAttributedString(
                string: titre,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.labelColor])
            toolTip = nil
        }
    }
}

/// Une pastille d'état : texte coloré sur fond teinté.
final class Pastille: NSView {
    private let l = label("", taille: 11, poids: .semibold)
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func regle(_ texte: String, _ couleur: NSColor) {
        l.stringValue = texte
        l.textColor = couleur
        layer?.backgroundColor = couleur.withAlphaComponent(0.18).cgColor
    }
}

/// Barre de remplissage horizontale.
final class Barre: NSView {
    private let remplissage = NSView()
    private var largeur: NSLayoutConstraint!
    private var ratio: Double = 0
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        remplissage.wantsLayer = true
        remplissage.layer?.cornerRadius = 4
        addSubview(remplissage)
        remplissage.translatesAutoresizingMaskIntoConstraints = false
        largeur = remplissage.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            remplissage.leadingAnchor.constraint(equalTo: leadingAnchor),
            remplissage.topAnchor.constraint(equalTo: topAnchor),
            remplissage.bottomAnchor.constraint(equalTo: bottomAnchor),
            largeur,
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func regle(_ r: Double, _ couleur: NSColor) {
        ratio = min(1, max(0, r))
        remplissage.layer?.backgroundColor = couleur.cgColor
        largeur.constant = max(4, bounds.width * CGFloat(ratio))
    }
    // La largeur en points n'est connue qu'après la mise en page : sans ce rappel, la
    // barre reste à sa taille initiale tant que la fenêtre n'a pas été redimensionnée.
    override func layout() {
        super.layout()
        largeur.constant = max(4, bounds.width * CGFloat(ratio))
    }
}

/// Une bulle de confirmation en bas à droite, qui s'efface seule.
///
/// Pas une notification système, et c'est un choix mesuré : `UNUserNotificationCenter`
/// depuis un bundle signé ad hoc ne fait RIEN (exit 0, aucune bannière, aucun journal),
/// et le repli `osascript` affiche bien mais sous l'icône de Script Editor, puisque c'est
/// lui qui émet. Nutip a tranché de la même façon : sa classe Toast dessine son propre
/// NSPanel. Une bulle qu'on dessine porte notre icône par construction.
final class Bulle {
    private var panneau: NSPanel?
    private var minuteur: Timer?

    func montre(_ texte: String) {
        efface()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // nonactivatingPanel + ignoresMouseEvents : la bulle ne vole jamais le focus et
        // ne bloque pas un clic destiné à ce qu'elle recouvre.
        p.ignoresMouseEvents = true

        let fond = NSVisualEffectView()
        fond.material = .hudWindow
        fond.blendingMode = .behindWindow
        fond.state = .active
        fond.maskImage = masqueArrondi(12)

        let icone = NSImageView()
        icone.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icone.imageScaling = .scaleProportionallyUpOrDown

        let texteVue = label(texte, taille: 12, poids: .medium)
        texteVue.lineBreakMode = .byWordWrapping
        texteVue.maximumNumberOfLines = 2

        let ligne = NSStackView(views: [icone, texteVue])
        ligne.orientation = .horizontal
        ligne.spacing = 10
        ligne.alignment = .centerY
        ligne.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        ligne.translatesAutoresizingMaskIntoConstraints = false
        fond.addSubview(ligne)
        NSLayoutConstraint.activate([
            icone.widthAnchor.constraint(equalToConstant: 24),
            icone.heightAnchor.constraint(equalToConstant: 24),
            ligne.leadingAnchor.constraint(equalTo: fond.leadingAnchor),
            ligne.trailingAnchor.constraint(equalTo: fond.trailingAnchor),
            ligne.topAnchor.constraint(equalTo: fond.topAnchor),
            ligne.bottomAnchor.constraint(equalTo: fond.bottomAnchor),
        ])
        p.contentView = fond
        p.setContentSize(fond.fittingSize)

        if let ecran = NSScreen.main {
            let v = ecran.visibleFrame
            let t = p.frame.size
            p.setFrameOrigin(NSPoint(x: v.maxX - t.width - 20, y: v.minY + 20))
        }
        p.orderFrontRegardless()
        panneau = p
        minuteur = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.efface()
        }
    }

    func efface() {
        minuteur?.invalidate(); minuteur = nil
        panneau?.orderOut(nil); panneau = nil
    }
}

/// La fenêtre intercepte elle-même ⌘R.
///
/// POURQUOI ⌘R ET NON ⌘ÉCHAP. Échap n'est pas une touche de raccourci ordinaire sur
/// macOS : AppKit refuse de l'accepter comme keyEquivalent de menu (vérifié via
/// l'accessibilité, AXMenuItemCmdChar reste vide), elle est déjà « annuler » dans toute
/// feuille ou champ de saisie, et ⌘⌥Échap appartient au système. Le raccourci ne pouvait
/// donc ni s'afficher dans le menu ni se comporter comme les autres. ⌘R est la convention
/// pour « relancer », il s'annonce partout, et rien ne le lui dispute ici.
///
/// On garde deux chemins : `performKeyEquivalent` est appelé sur la fenêtre clé avant la
/// recherche dans les menus, le moniteur sert de filet quand une feuille a le focus.
final class FenetreFixdock: NSWindow {
    var surRelance: (() -> Void)?

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           e.charactersIgnoringModifiers?.lowercased() == "r" {
            surRelance?()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

/// Une barre de défilement toujours visible, mais fine.
///
/// Les deux styles d'AppKit ratent chacun une moitié du besoin : `overlay` est fin mais
/// s'efface, donc rien n'annonce qu'il reste des processus plus bas ; `legacy` reste mais
/// dessine une piste large et grise qui pèse plus que la liste qu'elle borde. On garde
/// `legacy`, c'est lui qui persiste, et on redessine : pas de piste, un simple curseur
/// arrondi de trois points de large. Il se voit, il ne se remarque pas.
final class ScrollerFin: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for taille: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 9 }

    override func draw(_ r: NSRect) {
        // LA PISTE EST DESSINÉE, et ce n'est pas décoratif.
        //
        // La version d'avant ne peignait que le curseur. Un bâtonnet gris qui s'arrête net,
        // sans rien après lui, se lit comme une barre coupée : on croit qu'elle passe sous
        // quelque chose alors qu'elle est simplement finie. Vérifié sur le rendu de la
        // fenêtre, le curseur couvrait exactement sa proportion (85 % pour 265 points
        // visibles sur 311) : rien ne le masquait, il manquait juste ce qui dit où il
        // s'arrête. La piste donne la course, le curseur donne la position.
        piste()
        drawKnob()
    }

    private func piste() {
        let r = rect(for: .knobSlot).insetBy(dx: 3, dy: 2)
        guard r.height > 0, r.width > 0 else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }

    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 3, dy: 2)
        guard r.height > 0, r.width > 0 else { return }
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }
}

/// Un dégradé du fond vers le transparent, posé sur le bord d'une zone de défilement.
/// Sans lui, une ligne coupée net par le bord donne l'impression d'un texte tronqué plutôt
/// que d'un contenu qui continue. L'estompe dit « ça continue » sans rien écrire.
///
/// Son opacité suit la position du défilement : pas d'estompe en haut quand on est déjà
/// en haut : sinon elle voilerait la première ligne sans raison.
final class Estompe: NSView {
    private let degrade = CAGradientLayer()
    private let versLeBas: Bool

    init(versLeBas: Bool) {
        self.versLeBas = versLeBas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(degrade)
        degrade.startPoint = CGPoint(x: 0.5, y: versLeBas ? 1 : 0)
        degrade.endPoint   = CGPoint(x: 0.5, y: versLeBas ? 0 : 1)
        alphaValue = 0
        recolore()
    }
    required init?(coder: NSCoder) { fatalError() }

    // La vue ne doit jamais intercepter un clic destiné à un bouton situé dessous.
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Les couches ne suivent pas l'auto-layout : il faut leur donner le cadre à la main.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        degrade.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolore()
    }

    private func recolore() {
        // cgColor est résolu selon l'apparence COURANTE, pas celle de la vue : sans ce
        // basculement, une fenêtre en thème sombre reçoit un dégradé clair.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let f = NSColor.windowBackgroundColor
            degrade.colors = [f.cgColor, f.withAlphaComponent(0).cgColor]
        }
    }
}

/// Un bloc au fond légèrement contrasté, avec un titre en petites capitales.
final class Carte: NSView {
    let pile = NSStackView()
    init(_ titre: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        pile.orientation = .vertical
        pile.alignment = .leading
        pile.spacing = 9
        pile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pile)
        NSLayoutConstraint.activate([
            pile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pile.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pile.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            pile.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
        if let titre {
            pile.addArrangedSubview(
                label(titre.uppercased(), taille: 10, poids: .semibold, couleur: .secondaryLabelColor))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Une ligne pleine largeur.
    func ajouteLigne(_ vues: [NSView]) {
        let h = NSStackView(views: vues)
        h.orientation = .horizontal
        h.spacing = 8
        h.alignment = .centerY
        h.translatesAutoresizingMaskIntoConstraints = false
        pile.addArrangedSubview(h)
        h.widthAnchor.constraint(equalTo: pile.widthAnchor).isActive = true
    }
}

/// La vue document d'un NSScrollView doit être RETOURNÉE, sinon AppKit empile son contenu
/// depuis le bas et laisse un vide en haut dès que la fenêtre est plus haute que le
/// contenu.
final class VueRetournee: NSView {
    override var isFlipped: Bool { true }
}

/// Deux lignes de texte empilées, titre puis détail.
func duo(_ titre: String, _ detail: String) -> NSView {
    let v = NSStackView(views: [label(titre, taille: 12, poids: .medium),
                                label(detail, taille: 10, couleur: .secondaryLabelColor)])
    v.orientation = .vertical
    v.alignment = .leading
    v.spacing = 1
    return v
}

/// Une ligne de consommateur, construite UNE fois puis mise à jour.
///
/// Reconstruire les vues à chaque relevé faisait sauter la fenêtre trois fois par minute :
/// les vues changeaient d'identité et la pile se recalculait. Ici la vue persiste et seuls
/// son texte et ses gestes changent.
///
/// La zone d'action a une LARGEUR FIXE et les boutons y sont calés à droite : c'est ce qui
/// aligne les colonnes d'une ligne à l'autre, quel que soit le nombre de boutons.
final class LigneConso: NSView {
    private let titre = label("", taille: 12, poids: .medium)
    private let detail = label("", taille: 10, couleur: .secondaryLabelColor)
    private let bShow = Bouton("Show")
    private let bQuit = Bouton("Quit")
    static let largeurBouton: CGFloat = 52

    private var onShow: ((Consommateur) -> Void)!
    private var onQuit: ((Consommateur) -> Void)!

    init(onShow: @escaping (Consommateur) -> Void, onQuit: @escaping (Consommateur) -> Void) {
        super.init(frame: .zero)
        self.onShow = onShow; self.onQuit = onQuit

        let texte = NSStackView(views: [titre, detail])
        texte.orientation = .vertical
        texte.alignment = .leading
        texte.spacing = 1

        let actions = NSStackView(views: [bShow, bQuit])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.alignment = .centerY
        actions.distribution = .fillEqually
        // Sans ceci, NSStackView retire les vues masquées de la mise en page et le bouton
        // restant s'étale sur toute la zone : les colonnes se désalignent.
        actions.detachesHiddenViews = false

        for b in [bShow, bQuit] {
            b.widthAnchor.constraint(equalToConstant: Self.largeurBouton).isActive = true
        }
        actions.translatesAutoresizingMaskIntoConstraints = false
        texte.translatesAutoresizingMaskIntoConstraints = false
        addSubview(texte); addSubview(actions)
        NSLayoutConstraint.activate([
            texte.leadingAnchor.constraint(equalTo: leadingAnchor),
            texte.centerYAnchor.constraint(equalTo: centerYAnchor),
            texte.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.widthAnchor.constraint(equalToConstant: Self.largeurBouton * 2 + 6),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func regle(_ c: Consommateur, partDe total: UInt64) {
        let part = total > 0 ? Int(Double(c.octets) / Double(total) * 100) : 0
        var d = "\(go(c.octets)) · \(part)% of RAM"
        if c.processus > 1 { d += " · \(c.processus) processes" }
        titre.stringValue = c.nom
        detail.stringValue = d
        // Un bouton masqué garde sa place dans la zone : les colonnes restent alignées.
        bShow.isHidden = c.appActive == nil
        bQuit.isHidden = !c.peutQuitter
        bShow.geste = { [onShow] in onShow?(c) }
        bQuit.geste = { [onQuit] in onQuit?(c) }
    }
}

/// Arrondir un NSVisualEffectView SANS laisser ses coins carrés.
///
/// `layer.cornerRadius` + `masksToBounds` ne suffit pas : le matériau n'est pas dessiné
/// par le layer mais par le WindowServer, derrière la fenêtre, et il déborde donc du
/// masque. Ce sont ces quatre coins restés opaques qu'on prenait pour « un fond blanc
/// derrière ». La voie prévue par AppKit est `maskImage` : une image étirable dont les
/// marges fixes portent les arrondis.
func masqueArrondi(_ rayon: CGFloat) -> NSImage {
    let cote = rayon * 2 + 1
    let img = NSImage(size: NSSize(width: cote, height: cote), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: rayon, yRadius: rayon).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: rayon, left: rayon, bottom: rayon, right: rayon)
    img.resizingMode = .stretch
    return img
}

/// Une vue qui répond au clic. Un NSPanel sans bouton n'en reçoit aucun.
final class VueCliquable: NSView {
    var geste: (() -> Void)?
    override func mouseDown(with e: NSEvent) { geste?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Une vue qui signale l'entrée et la sortie du pointeur.
///
/// La zone de survol doit couvrir la MARGE autant que la notification : la croix déborde
/// du coin, et si elle sortait de la zone suivie, s'approcher d'elle la ferait disparaître.
final class VueSurvolee: NSView {
    var surSurvol: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with e: NSEvent) { surSurvol?(true) }
    override func mouseExited(with e: NSEvent) { surSurvol?(false) }
}

/// L'alerte de pression mémoire : ce que memwatch annonce, avec le geste en plus.
///
/// POURQUOI CE PANNEAU PLUTÔT QU'UNE NOTIFICATION DU SYSTÈME. Les deux voies natives ont
/// été essayées et mesurées. `UNUserNotificationCenter` est refusé net, le 14/09/2026, sur
/// un bundle minimal à identifiant stable, signé ad hoc, lancé par LaunchServices :
///
///     UNErrorDomain Code=1 "Notifications are not allowed for this application"
///
/// Le refus tombe avant la demande d'autorisation : pas de certificat Apple Developer,
/// pas d'enregistrement. `osascript`, lui, affiche bien une vraie bannière, mais sous
/// l'icône de Script Editor et sans aucune action au clic.
///
/// Or une alerte de mémoire sert à AGIR : elle doit dire d'où elle vient et mener à
/// l'endroit où l'on ferme l'app fautive. Un panneau qu'on dessine porte notre icône et
/// répond au clic, par construction. Le jour où l'app est signée pour de bon, cette classe
/// redevient dix lignes d'UNUserNotificationCenter.
///
/// Contrairement à la bulle de confirmation, celle-ci ATTEND : une alerte qu'on rate
/// pendant qu'on se bat avec une machine figée ne sert à rien.
final class Alarme {
    private var panneau: NSPanel?
    private var minuteur: Timer?

    func montre(_ titre: String, _ detail: String, critique: Bool,
                action: @escaping () -> Void) {
        efface()
        let largeur: CGFloat = 344
        // La croix est CENTRÉE SUR LE COIN, donc elle déborde. Le panneau porte une marge
        // de 12 en haut et à gauche pour l'accueillir : sans elle, le masque arrondi du
        // matériau la couperait en deux.
        let marge: CGFloat = 12
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: largeur + marge, height: 76 + marge),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let fond = NSVisualEffectView()
        fond.material = .popover
        fond.blendingMode = .behindWindow
        fond.state = .active
        fond.maskImage = masqueArrondi(18)

        let icone = NSImageView()
        icone.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icone.imageScaling = .scaleProportionallyUpOrDown

        let t = label(titre, taille: 13, poids: .semibold)
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 2
        let d = label(detail, taille: 12)
        d.lineBreakMode = .byWordWrapping
        d.maximumNumberOfLines = 3
        let texte = NSStackView(views: [t, d])
        texte.orientation = .vertical
        texte.alignment = .leading
        texte.spacing = 2

        let ligne = NSStackView(views: [icone, texte])
        ligne.orientation = .horizontal
        ligne.spacing = 12
        ligne.alignment = .top
        ligne.edgeInsets = NSEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)

        let cible = VueCliquable()
        cible.geste = { [weak self] in self?.efface(); action() }

        // La croix ferme SANS ouvrir l'app. Sans elle, l'alerte n'avait qu'une sortie :
        // cliquer, donc ouvrir Fixdock. Écarter une alerte qu'on a lue et comprise est un
        // geste à part entière, et il ne doit rien déclencher.
        // Un rond posé à cheval sur le coin supérieur gauche, révélé au survol : c'est la
        // forme et la place qu'a celle des notifications du système.
        let croix = Bouton("") { [weak self] in self?.efface() }
        croix.isBordered = false
        croix.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        croix.image?.isTemplate = true
        croix.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        croix.contentTintColor = .secondaryLabelColor
        croix.toolTip = "Dismiss"

        // LE MÊME MATÉRIAU QUE LA NOTIFICATION, et non une couleur unie qui s'en approche.
        // Le fond est translucide : ce qu'il montre dépend de ce qu'il y a derrière. Un
        // rond peint en windowBackgroundColor tombait juste sur un fond neutre et faux
        // partout ailleurs. Le masque circulaire vient de la même fonction que celui du
        // panneau, avec un rayon égal à la moitié du côté.
        let rond = NSVisualEffectView()
        rond.material = .popover
        rond.blendingMode = .behindWindow
        rond.state = .active
        rond.maskImage = masqueArrondi(10)
        rond.isHidden = true              // le couple n'apparaît qu'au survol
        croix.translatesAutoresizingMaskIntoConstraints = false
        rond.addSubview(croix)
        NSLayoutConstraint.activate([
            croix.leadingAnchor.constraint(equalTo: rond.leadingAnchor),
            croix.trailingAnchor.constraint(equalTo: rond.trailingAnchor),
            croix.topAnchor.constraint(equalTo: rond.topAnchor),
            croix.bottomAnchor.constraint(equalTo: rond.bottomAnchor),
        ])

        for v in [ligne, cible] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fond.addSubview(v)
        }

        // Le conteneur porte la marge ; le fond y est collé en bas à droite.
        let conteneur = VueSurvolee()
        conteneur.surSurvol = { entre in rond.isHidden = !entre }
        for v in [fond, rond] {
            v.translatesAutoresizingMaskIntoConstraints = false
            conteneur.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icone.widthAnchor.constraint(equalToConstant: 38),
            icone.heightAnchor.constraint(equalToConstant: 38),
            ligne.leadingAnchor.constraint(equalTo: fond.leadingAnchor),
            ligne.trailingAnchor.constraint(equalTo: fond.trailingAnchor),
            ligne.topAnchor.constraint(equalTo: fond.topAnchor),
            ligne.bottomAnchor.constraint(equalTo: fond.bottomAnchor),
            texte.widthAnchor.constraint(lessThanOrEqualToConstant: largeur - 80),
            cible.leadingAnchor.constraint(equalTo: fond.leadingAnchor),
            cible.trailingAnchor.constraint(equalTo: fond.trailingAnchor),
            cible.topAnchor.constraint(equalTo: fond.topAnchor),
            cible.bottomAnchor.constraint(equalTo: fond.bottomAnchor),

            fond.trailingAnchor.constraint(equalTo: conteneur.trailingAnchor),
            fond.bottomAnchor.constraint(equalTo: conteneur.bottomAnchor),
            fond.leadingAnchor.constraint(equalTo: conteneur.leadingAnchor, constant: marge),
            fond.topAnchor.constraint(equalTo: conteneur.topAnchor, constant: marge),

            // Serrée dans le coin : le centre du rond tombe sur la courbe de l'arrondi,
            // décalé de 5 vers l'intérieur sur les deux axes. Centré pile sur l'angle, il
            // flottait au-dessus du vide et paraissait détaché de la notification.
            rond.centerXAnchor.constraint(equalTo: fond.leadingAnchor, constant: 5),
            rond.centerYAnchor.constraint(equalTo: fond.topAnchor, constant: 5),
            rond.widthAnchor.constraint(equalToConstant: 20),
            rond.heightAnchor.constraint(equalToConstant: 20),
        ])
        p.contentView = conteneur
        conteneur.layoutSubtreeIfNeeded()
        let h = max(76, ligne.fittingSize.height)

        // En HAUT à droite, là où macOS pose ses notifications : l'endroit où l'œil va
        // chercher une alerte. La bulle de confirmation, elle, reste en bas, parce qu'une
        // confirmation suit un geste qu'on vient de faire.
        // La marge est INVISIBLE : ce qu'on aligne à 16 du bord, c'est le fond, pas le
        // panneau. D'où le décalage de `marge` sur x et sur la hauteur.
        if let e = NSScreen.main?.visibleFrame {
            p.setFrame(NSRect(x: e.maxX - largeur - 16 - marge, y: e.maxY - h - 16,
                              width: largeur + marge, height: h + marge), display: false)
        }
        p.orderFrontRegardless()
        panneau = p
        // Une minute quand le système tue déjà des processus, trente secondes sinon : la
        // gravité se dit par le temps qu'on laisse pour réagir.
        minuteur = Timer.scheduledTimer(withTimeInterval: critique ? 60 : 30,
                                        repeats: false) { [weak self] _ in self?.efface() }
    }

    func efface() {
        minuteur?.invalidate(); minuteur = nil
        panneau?.orderOut(nil); panneau = nil
    }
}

/// NSMenuItem ne retient pas de closure, comme NSButton.
final class ElementMenu: NSMenuItem {
    private let geste: () -> Void
    init(title: String, geste: @escaping () -> Void, keyEquivalent: String) {
        self.geste = geste
        super.init(title: title, action: #selector(joue), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func joue() { geste() }
}

/// Une fenêtre de réglages minuscule : deux cases, et ce qu'elles impliquent écrit dessous.
final class FenetreReglages: NSWindowController {
    private let dock = NSButton(checkboxWithTitle: "Show in the Dock", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)

    convenience init() {
        let f = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        f.title = "Fixdock Settings"
        f.isReleasedWhenClosed = false
        self.init(window: f)

        dock.target = self; dock.action = #selector(change)
        login.target = self; login.action = #selector(change)

        let note = label("With the Dock icon hidden, reopen this window by launching Fixdock from Spotlight.",
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Fenêtre
// ─────────────────────────────────────────────────────────────────────────────

final class Controleur: NSObject, NSWindowDelegate {
    private var fenetre: FenetreFixdock!
    private var colonne: NSStackView!
    private let pastille = Pastille()
    private let barre = Barre()
    private let detailMemoire = label("", taille: 11, couleur: .secondaryLabelColor)
    private let carteConso = Carte("What's using your memory")
    private let carteOrphelins = Carte("Stale dev servers")
    private let carteDock = Carte("Interface")
    private let carteRaccourci = Carte("Spotlight")
    private let carteDemarrage = Carte("Background")
    private let bDemarrage = Bouton("Enable")
    private let bRaccourci = Bouton("Install")
    private var texteDemarrage: NSView?
    private var texteRaccourci: NSView?
    private var tictac: Timer?
    private var tour = 0
    private let bulle = Bulle()
    private let alarme = Alarme()
    private let reglages = FenetreReglages()
    private var niveauAlerte = 1               // le dernier niveau annoncé
    private var dernierJetsam: String?         // le rapport le plus récent déjà vu
    private var derniereAlerte = Date.distantPast
    private var lignes: [LigneConso] = []      // réutilisées d'un relevé à l'autre
    private var ordre: [String] = []           // l'ordre d'affichage, délibérément figé
    private var moniteur: Any?                 // le jeton du raccourci ⌘R : À CONSERVER
    private let estompeHaut = Estompe(versLeBas: true)
    private let estompeBas = Estompe(versLeBas: false)
    private weak var defilement: NSScrollView?
    private var lignesOrphelins: [NSView] = []

    func ouvre() {
        let entete = Carte(nil)

        // Le logo de l'app, à gauche du titre. NSImage(named:) lit l'icône du bundle ;
        // en développement (binaire lancé hors bundle) on retombe sur l'icône générique
        // plutôt que de laisser un trou.
        let logo = NSImageView()
        logo.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 22),
            logo.heightAnchor.constraint(equalToConstant: 22),
        ])

        // L'engrenage est DANS la fenêtre, et il doit y être : sans icône de Dock, l'app
        // n'a pas non plus de barre de menus (.accessory les retire toutes les deux). La
        // fenêtre est alors le seul endroit d'où l'on peut revenir en arrière.
        let bReglages = Bouton("") { [weak self] in self?.reglages.montre() }
        bReglages.isBordered = false
        // Un vrai symbole plutôt que le caractère « ⚙ » : celui-ci se rend à la taille de
        // la police, donc minuscule à côté d'un titre de 15, et il ne suit pas le thème.
        bReglages.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        bReglages.image?.isTemplate = true
        bReglages.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        bReglages.contentTintColor = .secondaryLabelColor
        bReglages.toolTip = "Settings"
        bReglages.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bReglages.widthAnchor.constraint(equalToConstant: 22),
            bReglages.heightAnchor.constraint(equalToConstant: 22),
        ])
        entete.ajouteLigne([logo, label("Memory", taille: 15, poids: .semibold),
                            NSView(), pastille, bReglages])
        entete.pile.addArrangedSubview(barre)
        barre.translatesAutoresizingMaskIntoConstraints = false
        barre.widthAnchor.constraint(equalTo: entete.pile.widthAnchor).isActive = true
        // L'infobulle est posée sur le TEXTE autant que sur le « ? » : celui qui se
        // demande ce qu'est « swap » s'arrête sur le mot, pas sur la pastille à côté.
        detailMemoire.toolTip = LEXIQUE.map { "\($0.terme) : \($0.sens)" }.joined(separator: "\n")
        entete.ajouteLigne([detailMemoire, Aide(LEXIQUE), NSView()])

        carteDock.ajouteLigne([
            duo("Dock not responding?", "Mission Control and Launchpad share the same process."),
            NSView(),
            Bouton("Restart Dock", indice: "⌘R") { [weak self] in self?.relanceDock() },
        ])

        // Taille figée : sans bordure, un NSButton se recalcule plus petit, et le bouton
        // rétrécissait en passant à « Done ». Un état qui change la géométrie fait bouger
        // la carte entière.
        for b in [bDemarrage, bRaccourci] {
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 68),
                b.heightAnchor.constraint(equalToConstant: 21),
            ])
        }
        bDemarrage.geste = { [weak self] in
            Demarrage.active(depuis: self?.fenetre)
            self?.marqueLesCartes()
        }
        let td = duo("Watch memory in the background",
                     "Starts with your Mac and warns you before the system kills an app.")
        texteDemarrage = td
        carteDemarrage.ajouteLigne([td, NSView(), bDemarrage])

        let tr = duo("Run these actions from Spotlight",
                     "One Fixdock entry, every action inside. Needs Allow Running Scripts.")
        texteRaccourci = tr
        carteRaccourci.ajouteLigne([tr, NSView(), bRaccourci])
        bRaccourci.geste = { [weak self] in
            RaccourciSpotlight.installe(depuis: self?.fenetre)
        }

        // TROIS ZONES, ET UNE SEULE DÉFILE.
        //
        // L'en-tête mémoire reste en haut, le bloc Interface reste en bas, et seule la
        // liste des processus défile entre les deux. C'est ce qui garantit que « Restart
        // Dock » est toujours sous les yeux : c'est le geste pour lequel on ouvre l'app,
        // il ne doit jamais dépendre d'un défilement. La fenêtre garde du même coup une
        // hauteur constante, quel que soit le nombre de processus.
        colonne = NSStackView(views: [carteConso, carteOrphelins])
        colonne.orientation = .vertical
        colonne.alignment = .leading
        colonne.spacing = 12
        colonne.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 14, right: 14)
        colonne.translatesAutoresizingMaskIntoConstraints = false
        for c in [carteConso, carteOrphelins] {
            c.widthAnchor.constraint(equalTo: colonne.widthAnchor, constant: -28).isActive = true
        }

        let defilement = NSScrollView()
        defilement.hasVerticalScroller = true
        defilement.hasHorizontalScroller = false
        defilement.horizontalScrollElasticity = .none   // rien à voir sur les côtés
        defilement.drawsBackground = false
        // La barre reste VISIBLE en permanence : c'est le seul indice qu'il y a d'autres
        // processus plus bas. Le style overlay d'usage, qui s'efface après le défilement,
        // laisse croire que la liste s'arrête là où la fenêtre la coupe.
        defilement.autohidesScrollers = false
        defilement.scrollerStyle = .legacy
        defilement.verticalScroller = ScrollerFin()
        let doc = VueRetournee()
        doc.addSubview(colonne)
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colonne.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            colonne.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            colonne.topAnchor.constraint(equalTo: doc.topAnchor),
            doc.bottomAnchor.constraint(equalTo: colonne.bottomAnchor),
        ])
        defilement.documentView = doc

        fenetre = FenetreFixdock(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        fenetre.title = "Fixdock"
        // Fermer la fenêtre ne détruit ni la fenêtre ni l'app : Fixdock continue de
        // surveiller la mémoire en arrière-plan, et c'est tout l'intérêt d'une alerte.
        fenetre.isReleasedWhenClosed = false
        fenetre.minSize = NSSize(width: 420, height: 480)

        // Le bas de la fenêtre : Spotlight au-dessus d'Interface, les deux fixes.
        // Une NSStackView détache ses vues cachées, c'est ce qu'on veut ici : une fois le
        // raccourci installé, la carte Spotlight disparaît sans laisser de trou.
        let bas = NSStackView(views: [carteDemarrage, carteRaccourci, carteDock])
        bas.orientation = .vertical
        bas.alignment = .leading
        bas.spacing = 12
        for c in [carteDemarrage, carteRaccourci, carteDock] {
            c.widthAnchor.constraint(equalTo: bas.widthAnchor).isActive = true
        }

        let fond = NSView()
        for v in [entete, defilement, bas] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fond.addSubview(v)
        }
        NSLayoutConstraint.activate([
            entete.topAnchor.constraint(equalTo: fond.topAnchor, constant: 14),
            entete.leadingAnchor.constraint(equalTo: fond.leadingAnchor, constant: 14),
            entete.trailingAnchor.constraint(equalTo: fond.trailingAnchor, constant: -14),

            defilement.topAnchor.constraint(equalTo: entete.bottomAnchor, constant: 12),
            defilement.leadingAnchor.constraint(equalTo: fond.leadingAnchor),
            defilement.trailingAnchor.constraint(equalTo: fond.trailingAnchor),

            bas.topAnchor.constraint(equalTo: defilement.bottomAnchor, constant: 12),
            bas.leadingAnchor.constraint(equalTo: fond.leadingAnchor, constant: 14),
            bas.trailingAnchor.constraint(equalTo: fond.trailingAnchor, constant: -14),
            bas.bottomAnchor.constraint(equalTo: fond.bottomAnchor, constant: -14),
        ])
        // Seule la zone de défilement s'étire : les deux autres gardent leur taille propre.
        entete.setContentCompressionResistancePriority(.required, for: .vertical)
        bas.setContentCompressionResistancePriority(.required, for: .vertical)
        defilement.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Les estompes se posent PAR-DESSUS la zone de défilement, sur ses deux bords.
        for (e, haut) in [(estompeHaut, true), (estompeBas, false)] {
            e.translatesAutoresizingMaskIntoConstraints = false
            fond.addSubview(e, positioned: .above, relativeTo: defilement)
            NSLayoutConstraint.activate([
                e.leadingAnchor.constraint(equalTo: defilement.leadingAnchor),
                // S'ARRÊTER AVANT LA BARRE, par une constante et non par le clip.
                //
                // L'estompe est un aplat de windowBackgroundColor à son extrémité opaque :
                // posée jusqu'au bord, elle recouvrait le haut et le bas de la barre, qui
                // semblait alors passer derrière un bloc blanc. Se caler sur
                // `contentView` paraissait juste et n'a rien changé : le clip garde toute
                // la largeur, c'est le scroller qui se pose par-dessus. D'où la largeur en
                // dur, la même que celle que ScrollerFin déclare.
                e.trailingAnchor.constraint(equalTo: defilement.trailingAnchor, constant: -9),
                e.heightAnchor.constraint(equalToConstant: 20),
                haut ? e.topAnchor.constraint(equalTo: defilement.topAnchor)
                     : e.bottomAnchor.constraint(equalTo: defilement.bottomAnchor),
            ])
        }
        self.defilement = defilement
        defilement.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(aDefile),
            name: NSView.boundsDidChangeNotification, object: defilement.contentView)

        fenetre.surRelance = { [weak self] in self?.relanceDock() }
        fenetre.contentView = fond
        // La largeur de référence est celle du CLIP, pas celle du NSScrollView.
        //
        // Les deux diffèrent d'exactement la largeur de la barre de défilement : en style
        // `legacy`, elle occupe la place au lieu de flotter au-dessus. Caler le document
        // sur le scroll view le rendait donc 9 points plus large que la zone visible, et
        // c'est ce qui autorisait un défilement latéral de 9 points, sans le moindre
        // contenu à y voir.
        doc.widthAnchor.constraint(equalTo: defilement.contentView.widthAnchor).isActive = true
        fenetre.center()
        fenetre.delegate = self
        // En mode barre des menus, le lancement est SILENCIEUX : c'est ce qu'on attend
        // d'une veille qui démarre avec la session. Relancer l'app alors qu'elle tourne
        // déjà envoie un « reopen », et la fenêtre revient.
        if !Reglages.barreSeule {
            fenetre.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        installeMenu()
        Reglages.applique()
        // ⌘R relance le Dock sans viser le bouton. Un moniteur LOCAL suffit : le
        // raccourci ne vaut que quand Fixdock est au premier plan, ce qui évite de
        // confisquer une combinaison au reste du système.
        // Le jeton rendu par addLocalMonitorForEvents DOIT être conservé : le moniteur est
        // retiré dès que l'objet rendu est désalloué. Le jeter : ce que faisait la version
        // précédente : installe un raccourci qui ne se déclenche jamais, sans le moindre
        // message d'erreur. C'est ce qui expliquait « toujours pas de raccourci ».
        moniteur = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(.command),
               e.charactersIgnoringModifiers?.lowercased() == "r" {
                self?.relanceDock()
                return nil
            }
            return e
        }

        rafraichit(complet: true)
        // 5 s : à 3 s les chiffres changeaient plus vite qu'on ne les lit. La recherche
        // d'orphelins appelle lsof, trop lente même pour ce rythme : un tour sur six (30 s).
        tictac = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tour += 1
            self.rafraichit(complet: self.tour % 6 == 0)
        }
    }

    /// Annoncer l'asphyxie mémoire : et nommer le geste qui en sort.
    ///
    /// Le déclencheur est le niveau du NOYAU, pas un seuil maison : c'est la valeur sur
    /// laquelle Jetsam s'appuie pour décider de tuer. Quand elle passe à `critical`, le
    /// système ne menace pas de tuer des processus, il en tue déjà.
    ///
    /// Ce que memwatch rate et qu'on corrige ici : « ferme une app » ne dit pas laquelle.
    /// On nomme le plus gros consommateur qui ne porte pas de travail en cours : fermer
    /// Chrome coûte des onglets qui reviennent, fermer cmux coûte une session.
    private func surveille(_ m: Memoire, _ liste: [Consommateur]) {
        guard m.pression >= 2 else { niveauAlerte = 1; return }
        // On réannonce si ça EMPIRE, sinon au plus une fois par quart d'heure : une alerte
        // qui se répète toutes les cinq secondes se ferme sans se lire.
        let empire = m.pression > niveauAlerte
        guard empire || Date().timeIntervalSince(derniereAlerte) > 900 else { return }
        niveauAlerte = m.pression
        derniereAlerte = Date()

        let critique = m.pression >= 4
        let cible = liste.first { !$0.sensible } ?? liste.first
        var conseil = "Open Fixdock to see what is using your memory."
        if let c = cible {
            conseil = "\(c.nom) is using \(go(c.octets)). Click to quit it from Fixdock."
        }
        alarme.montre(critique ? "macOS is killing apps to free memory"
                               : "Memory is running out",
                      conseil, critique: critique) { [weak self] in self?.auPremierPlan() }
    }

    /// Affiche l'alerte telle qu'elle apparaîtra sous pression, sans attendre la pression.
    func testAlarme() {
        surveille(Memoire.releve(), Sonde.consommateurs())
        if niveauAlerte < 2 {   // la machine va bien : on force l'affichage
            alarme.montre("macOS is killing apps to free memory",
                          "Chrome is using 1.3 GB. Click to quit it from Fixdock.",
                          critique: true) { [weak self] in self?.auPremierPlan() }
        }
    }

    /// Annoncer qu'un processus vient d'être tué par le noyau.
    ///
    /// Au tout premier tour on se contente de NOTER le rapport le plus récent : sans ça,
    /// ouvrir l'app rejouerait l'alerte d'un incident vieux de trois jours.
    private func surveilleJetsam() {
        guard let recent = Jetsam.dernier() else { return }
        let nom = recent.lastPathComponent
        guard let vu = dernierJetsam else { dernierJetsam = nom; return }
        guard nom != vu else { return }
        dernierJetsam = nom

        guard let (victime, raison) = Jetsam.victime(recent) else { return }
        if raison == "per-process-limit" {
            // Sa limite à lui, pas celle de la machine : on informe, on n'alarme pas.
            alarme.montre("macOS stopped \(victime)",
                          "It hit its own memory limit, not the machine's. Nothing to do.",
                          critique: false) { [weak self] in self?.auPremierPlan() }
        } else {
            alarme.montre("macOS killed \(victime) to free memory",
                          "Your machine ran out of RAM. Click to see what is using it.",
                          critique: true) { [weak self] in self?.auPremierPlan() }
        }
    }

    /// L'état des deux réglages, lu du système et non d'une mémoire à nous.
    private func marqueLesCartes() {
        let demarre = Demarrage.actif, raccourci = RaccourciSpotlight.installe
        bDemarrage.marqueFait(demarre, titre: "Enable",
                              rappel: "Fixdock already starts with your Mac. Manage it in System Settings > General > Login Items.")
        bRaccourci.marqueFait(raccourci, titre: "Install",
                              rappel: "The Fixdock shortcut is installed. Click again to reinstall an updated version.")
        // Le texte s'estompe une fois la chose faite : la carte reste lisible si on la
        // cherche, mais elle cesse de réclamer l'attention de celui qui parcourt la fenêtre.
        texteDemarrage?.alphaValue = demarre ? 0.45 : 1
        texteRaccourci?.alphaValue = raccourci ? 0.45 : 1
    }

    /// Relève les cadres réels, faute de pouvoir regarder l'écran.
    func diag() {
        var t = ""
        if let d = defilement {
            t += "scrollview   \(d.frame)\n"
            t += "clip         \(d.contentView.frame)  bounds \(d.contentView.bounds)\n"
            t += "doc          \(d.documentView?.frame ?? .zero)\n"
            t += "scroller     \(d.verticalScroller?.frame ?? .zero)  "
            t += "masqué=\(d.verticalScroller?.isHidden ?? true)  "
            t += "style=\(d.scrollerStyle.rawValue)  classe=\(type(of: d.verticalScroller!))\n"
            t += "estompeHaut  \(estompeHaut.frame)  alpha \(estompeHaut.alphaValue)\n"
            t += "estompeBas   \(estompeBas.frame)  alpha \(estompeBas.alphaValue)\n"
            t += "ordre des sous-vues du fond :\n"
            for v in d.superview?.subviews ?? [] { t += "   \(type(of: v))  \(v.frame)\n" }
        }
        try? t.write(toFile: NSHomeDirectory() + "/fixdock-diag.txt",
                     atomically: true, encoding: .utf8)

        // Le rendu AppKit de la fenêtre, sans passer par une capture d'écran : pas de
        // permission à demander, et rien d'autre que notre propre fenêtre.
        if let v = fenetre?.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/fixdock-diag.png"))
            }
        }
    }

    /// Ramener la fenêtre, qu'elle soit derrière une autre app ou fermée.
    func auPremierPlan() {
        guard let fenetre else { return }
        fenetre.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Un menu minimal : sans lui l'app n'a ni ⌘Q ni ⌘W, et le raccourci du Dock reste
    /// invisible. Un raccourci qu'aucun menu n'annonce ne s'apprend pas.
    private func installeMenu() {
        let barre = NSMenu()

        let mApp = NSMenuItem()
        let sousApp = NSMenu()
        // Contrairement à Échap, ⌘R s'inscrit normalement dans le menu : le raccourci
        // s'y affiche, donc il s'apprend.
        let relance = NSMenuItem(title: "Restart Dock", action: #selector(menuRelanceDock),
                                 keyEquivalent: "r")
        relance.target = self
        sousApp.addItem(relance)
        sousApp.addItem(.separator())
        sousApp.addItem(ElementMenu(title: "Settings…",
                                    geste: { [weak self] in self?.reglages.montre() },
                                    keyEquivalent: ","))
        sousApp.addItem(.separator())
        sousApp.addItem(NSMenuItem(title: "Hide Fixdock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        sousApp.addItem(NSMenuItem(title: "Quit Fixdock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        mApp.submenu = sousApp
        barre.addItem(mApp)

        let mFenetre = NSMenuItem()
        let sousFenetre = NSMenu(title: "Window")
        sousFenetre.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        sousFenetre.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        mFenetre.submenu = sousFenetre
        barre.addItem(mFenetre)

        NSApp.mainMenu = barre
        NSApp.windowsMenu = sousFenetre
    }

    @objc private func menuRelanceDock() { relanceDock() }

    /// Chaque estompe n'apparaît que s'il y a réellement du contenu caché de son côté,
    /// et monte progressivement sur les 20 premiers points : sinon elle surgirait d'un coup.
    @objc private func aDefile() {
        guard let d = defilement, let doc = d.documentView else { return }
        let y = d.contentView.bounds.origin.y
        let restant = doc.bounds.height - d.contentView.bounds.height - y
        estompeHaut.alphaValue = min(1, max(0, y / 20))
        estompeBas.alphaValue = min(1, max(0, restant / 20))
    }

    func windowWillClose(_ n: Notification) {
        tictac?.invalidate()
        NSApp.terminate(nil)
    }

    // ── Rendu ────────────────────────────────────────────────────────────────

    private func rafraichit(complet: Bool) {
        let m = Memoire.releve()
        let e = m.etat
        pastille.regle(e.texte, e.couleur)
        barre.regle(m.swapTotal > 0 ? Double(m.swapUtilise) / Double(m.swapTotal) : 0, e.couleur)
        detailMemoire.stringValue =
            "\(go(m.libre)) free · swap \(go(m.swapUtilise)) of \(go(m.swapTotal)) · \(go(m.compresse)) compressed"

        // L'ORDRE NE BOUGE PAS TANT QUE LA DISTRIBUTION NE CHANGE PAS.
        //
        // Trier par mémoire à chaque relevé paraît juste, mais deux apps proches
        // s'échangent leur rang en permanence : la liste se réarrange sous les yeux et
        // devient illisible : on ne peut plus viser un bouton ni finir de lire une ligne.
        // On ne retrie donc QUE lorsque l'ENSEMBLE des apps affichées change (une entre,
        // une sort). Tant que ce sont les mêmes, chacune garde sa place et seuls ses
        // chiffres bougent.
        let mesures = Sonde.consommateurs()
        var parNom: [String: Consommateur] = [:]
        for c in mesures { parNom[c.nom] = c }
        let sommet = mesures.prefix(6).map(\.nom)

        if Set(sommet) != Set(ordre) { ordre = sommet }
        let liste = ordre.compactMap { parNom[$0] }
        while lignes.count < liste.count {
            let l = LigneConso(onShow: { [weak self] c in self?.montre(c) },
                               onQuit:  { [weak self] c in self?.quitte(c) })
            lignes.append(l)
            carteConso.ajouteLigne([l])
        }
        for (i, l) in lignes.enumerated() {
            if i < liste.count { l.isHidden = false; l.regle(liste[i], partDe: m.total) }
            else { l.isHidden = true }
        }

        surveille(m, liste)
        if complet { surveilleJetsam() }

        // La hauteur du contenu vient de changer : l'estompe du bas doit suivre.
        DispatchQueue.main.async { [weak self] in self?.aDefile() }

        if complet { marqueLesCartes() }

        if complet {
            let orphelins = Orphelins.chercher()
            carteOrphelins.isHidden = orphelins.isEmpty
            for v in lignesOrphelins { v.removeFromSuperview() }
            lignesOrphelins = []
            for o in orphelins {
                let bouton = Bouton("Stop") { [weak self] in self?.arrete(o) }
                let vues: [NSView] = [
                    duo("pid \(o.pid) · \(go(o.octets))",
                        "folder is gone: \((o.dossierDisparu as NSString).lastPathComponent)"),
                    NSView(), bouton,
                ]
                carteOrphelins.ajouteLigne(vues)
                if let derniere = carteOrphelins.pile.arrangedSubviews.last {
                    lignesOrphelins.append(derniere)
                }
            }
        }

    }

    // ── Gestes ───────────────────────────────────────────────────────────────

    // activate() seul ne suffit pas : une app peut tourner SANS aucune fenêtre (Claude et
    // Slack sont dans ce cas dès qu'on a fermé la leur). Elle passe alors au premier plan
    // et il n'y a rien à voir : le bouton semblait ne rien faire.
    // openApplication() envoie en plus l'événement « reopen », celui que produit un clic
    // sur l'icône du Dock : l'app recrée ou restaure sa fenêtre.
    private func montre(_ c: Consommateur) {
        guard let app = c.appActive else { return }
        if let url = app.bundleURL {
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: conf) { _, erreur in
                if erreur != nil {
                    DispatchQueue.main.async { app.activate(options: [.activateAllWindows]) }
                }
            }
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }

    // Deux voies, aucune n'est un SIGKILL :
    //   - une app graphique reçoit terminate(), le « Quitter » du menu : elle peut
    //     présenter ses dialogues d'enregistrement, ou refuser ;
    //   - un processus sans fenêtre (Claude Code, Node) reçoit SIGTERM, qu'il peut
    //     intercepter pour se fermer proprement.
    // Ce qui est « sensible » n'est pas interdit : c'est annoncé, et Cancel est le bouton
    // par défaut. Refuser le geste serait revenir au « in use » qui ne servait à rien.
    private func quitte(_ c: Consommateur) {
        let a = NSAlert()
        a.messageText = "Quit \(c.nom)?"
        var texte = "It is using \(go(c.octets))."
        if let risque = RISQUES[c.nom] { texte += " " + risque }
        else if c.appActive != nil { texte += " \(c.nom) will be asked to quit normally and can save your work first." }
        else { texte += " \(c.pids.count) background process\(c.pids.count > 1 ? "es" : "") will be asked to stop." }
        a.informativeText = texte

        if c.sensible {
            // L'ordre des boutons fait le défaut : Cancel en premier = Cancel sur Entrée.
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Quit \(c.nom)")
            a.alertStyle = .critical
            guard a.runModal() == .alertSecondButtonReturn else { return }
        } else {
            a.addButton(withTitle: "Quit \(c.nom)")
            a.addButton(withTitle: "Cancel")
            a.alertStyle = .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }

        if let app = c.appActive { app.terminate() }
        else { for pid in c.pids { kill(pid, SIGTERM) } }
        bulle.montre("Asked \(c.nom) to quit. \(go(c.octets)) should come back.")
        rafraichit(complet: false)
    }

    private func arrete(_ o: Orphelin) {
        kill(o.pid, SIGTERM)
        bulle.montre("Stopped stale server (pid \(o.pid)). \(go(o.octets)) freed.")
        rafraichit(complet: true)
    }

    // Le geste est fait ICI plutôt que délégué à ~/bin/fixdock.sh, et c'est un
    // renoncement assumé à l'unicité de la logique. La raison : fixdock.sh émet sa propre
    // notification, par osascript, donc sous l'icône de Script Editor. En l'appelant on
    // héritait de cette notification-là EN PLUS de notre bulle. Le script reste la
    // référence pour le terminal et le menu Services ; ici, trois lignes de killall valent
    // mieux qu'une notification qui porte le logo de quelqu'un d'autre.
    fileprivate func relanceDock() {
        let etaitLa = !shell("/usr/bin/pgrep", ["-x", "Dock"]).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }!.isEmpty
        if etaitLa {
            shell("/usr/bin/killall", ["Dock"])
        } else {
            shell("/usr/bin/open", ["-a", "/System/Library/CoreServices/Dock.app"])
        }
        // launchd relance le Dock en une à deux secondes ; on annonce après son retour
        // pour ne pas affirmer un succès qu'on n'a pas constaté.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let revenu = !(shell("/usr/bin/pgrep", ["-x", "Dock"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            DispatchQueue.main.async {
                self?.bulle.montre(revenu ? "Dock restarted."
                                          : "The Dock did not come back. If the whole screen is frozen, cursor included, that is WindowServer, not the Dock.")
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Entrée
// ─────────────────────────────────────────────────────────────────────────────

final class Delegue: NSObject, NSApplicationDelegate {
    let controleur = Controleur()
    func applicationDidFinishLaunching(_ n: Notification) {
        controleur.ouvre()
        // Une alerte qui ne se déclenche que sous asphyxie mémoire ne peut pas se vérifier
        // autrement qu'en asphyxiant la machine. Ce drapeau la montre sur demande.
        if CommandLine.arguments.contains("--test-alarme") { controleur.testAlarme() }
        if CommandLine.arguments.contains("--diag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.controleur.diag() }
        }
    }
    // false : la fenêtre fermée, l'app reste et continue de surveiller. Un moniteur qui
    // s'arrête quand on range sa fenêtre ne prévient de rien.
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }

    // Cliquer l'icône du Dock, ou relancer l'app depuis Spotlight, ramène la fenêtre.
    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows v: Bool) -> Bool {
        controleur.auPremierPlan()
        return true
    }
}

let app = NSApplication.shared
let delegue = Delegue()
app.delegate = delegue
app.setActivationPolicy(.regular)
app.run()
