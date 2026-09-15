import AppKit
import Darwin

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

enum Sonde {
    // `ps` plutôt que proc_pidinfo : une seule traversée, pas de droits particuliers,
    // et c'est exactement ce que memwatch mesure déjà : deux outils, un même chiffre.
    static func lignesPs() -> [(rss: UInt64, pid: Int32, chemin: String)] {
        guard let sortie = shell("/bin/ps", ["-Ao", "rss=,pid=,comm="]) else { return [] }
        return analyse(sortie)
    }

    /// Le découpage pur de la sortie de `ps`, séparé de l'appel au binaire pour être
    /// testable sans processus (voir Tests/). Aucun changement de comportement.
    static func analyse(_ sortie: String) -> [(rss: UInt64, pid: Int32, chemin: String)] {
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
        // `processName` rend le nom de l'EXÉCUTABLE (« attix »), alors que la liste
        // regroupe les processus sous le nom de leur BUNDLE (« Attix »). Ne filtrer que
        // le premier laissait l'app se ranger parmi les consommateurs à surveiller, avec
        // son propre bouton Quit.
        let moi = ProcessInfo.processInfo.processName
        let monBundle = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Attix"
        let actives = NSWorkspace.shared.runningApplications
        return total.filter {
            $0.value >= minimum && $0.key != moi && $0.key != monBundle
                && $0.key != "Attix Lab"
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

