import AppKit

/// L'icône de barre des menus : Attix visible en permanence, sans fenêtre ouverte.
///
/// POURQUOI ELLE EXISTE MAINTENANT. Le dépôt a longtemps refusé cette icône : le retour
/// se faisait par Spotlight, et une barre pleine n'avait pas besoin d'un logo de plus.
/// L'argument tenait pour REVENIR à l'app ; il ne tient pas pour la SUIVRE. Un moniteur
/// de mémoire dont il faut ouvrir la fenêtre pour connaître l'état n'est consulté qu'une
/// fois le mal fait — or tout le reste de l'app existe pour agir AVANT. Les chiffres
/// libres sont donc affichés en permanence, et l'icône n'est pas qu'un raccourci
/// d'ouverture : elle porte les mêmes gestes que la fenêtre.
///
/// UNE ICÔNE, RIEN D'AUTRE. Pas de chiffres à côté, pas d'emoji : un item de largeur fixe
/// (`squareLength`), qui ne pousse jamais ses voisins et ne réclame pas plus de place
/// qu'un item système. Les chiffres sont dans le menu, à un clic.
///
/// UN SEUL SYMBOLE, JAMAIS DE COULEUR À NOUS. L'image est un TEMPLATE et le reste en
/// toute circonstance : macOS la rend alors exactement comme les autres icônes de la
/// barre, noire sur une barre claire, blanche sur une barre sombre, y compris quand c'est
/// le fond d'écran et non le thème qui la fait basculer.
///
/// Une version antérieure passait à un triangle d'alerte teinté sous pression mémoire.
/// C'était le seul endroit de l'app qui posait une couleur propre, et le résultat se
/// voyait : une icône orange au milieu d'une rangée d'icônes monochromes ne ressemble pas
/// à un avertissement, elle ressemble à une icône mal faite. L'alerte a déjà son canal,
/// le panneau de `Alarme`, qui nomme le coupable et porte le geste ; la barre ne sert qu'à
/// ouvrir, et l'état s'y lit dans l'infobulle et dans le menu.
final class BarreMenus: NSObject, NSMenuDelegate {
    /// Les gestes sont ceux de la fenêtre : la barre ne réimplémente rien, elle appelle.
    var surOuvre: (() -> Void)?
    var surReglages: (() -> Void)?
    var surRelanceDock: (() -> Void)?
    var surMontre: ((Consommateur) -> Void)?
    var surQuitte: ((Consommateur) -> Void)?

    private var item: NSStatusItem?
    private let menu = NSMenu()
    /// La ligne d'état en tête de menu : désactivée, c'est un titre et non un geste.
    private let ligneEtat = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ligneDetail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Le dernier relevé, gardé pour remplir le menu à son ouverture : les lignes sont
    /// reconstruites là, pas à chaque relevé — refaire des items sous le curseur d'un
    /// menu ouvert le fait clignoter.
    private var conso: [Consommateur] = []
    private var total: UInt64 = 0

    var visible: Bool { item != nil }

    override init() {
        super.init()
        menu.delegate = self
    }

    // ── Présence ─────────────────────────────────────────────────────────────

    func applique() {
        if Reglages.barreMenus { montre() } else { cache() }
    }

    private func montre() {
        guard item == nil else { return }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        i.button?.imagePosition = .imageOnly
        i.button?.image = Self.symbole()
        i.menu = menu
        item = i
    }

    private func cache() {
        guard let i = item else { return }
        NSStatusBar.system.removeStatusItem(i)
        item = nil
    }

    // ── Relevé ───────────────────────────────────────────────────────────────

    /// Appelé à chaque tour du minuteur de la fenêtre : un seul relevé alimente les deux.
    func regle(_ m: Memoire, _ liste: [Consommateur]) {
        conso = liste
        total = m.total
        guard let bouton = item?.button else { return }

        // L'icône ne bouge plus : ni son dessin, ni sa couleur. Seule l'infobulle suit le
        // relevé, et le menu se remplit à son ouverture.
        let e = m.etat
        bouton.toolTip = "Attix · \(e.texte) · \(go(m.libre)) free"
    }

    /// `contentTintColor` n'est jamais posé : un template dont on ne teinte rien est rendu
    /// par macOS avec la couleur de la barre, et c'est précisément ce qu'on veut. Poser
    /// `.labelColor` « pour bien faire » figerait la couleur du thème SYSTÈME, qui n'est
    /// pas toujours celle de la barre — l'icône jurerait alors avec ses voisines.
    private static func symbole() -> NSImage? {
        let img = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Attix memory")
        img?.isTemplate = true
        return img
    }

    // ── Menu ─────────────────────────────────────────────────────────────────

    /// Le menu se remplit À SON OUVERTURE, pas au relevé : ses lignes sont alors justes
    /// au moment où on les lit, et rien ne bouge sous le curseur pendant qu'il est ouvert.
    func menuWillOpen(_ m: NSMenu) { reconstruit() }

    private func reconstruit() {
        menu.removeAllItems()

        let mem = Memoire.releve()
        ligneEtat.title = mem.etat.texte
        ligneEtat.isEnabled = false
        ligneDetail.title = "\(go(mem.libre)) free · swap \(go(mem.swapUtilise)) · \(go(mem.compresse)) compressed"
        ligneDetail.isEnabled = false
        ligneDetail.attributedTitle = NSAttributedString(
            string: ligneDetail.title,
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(ligneEtat)
        menu.addItem(ligneDetail)
        menu.addItem(.separator())

        // Les trois premiers consommateurs, chacun avec SES gestes en sous-menu : le
        // principe de la fenêtre — toute ligne affichée porte son action — vaut ici aussi.
        // Un menu qui se contenterait de nommer le coupable serait le cul-de-sac que
        // l'app entière existe pour éviter. « Quit » passe par la même confirmation que
        // dans la fenêtre : c'est le contrôleur qui l'affiche, pas nous.
        for c in conso.prefix(3) {
            let part = total > 0 ? Int(Double(c.octets) / Double(total) * 100) : 0
            let ligne = NSMenuItem(title: "\(c.nom) · \(go(c.octets)) · \(part)%",
                                   action: nil, keyEquivalent: "")
            let gestes = NSMenu()
            if c.appActive != nil {
                gestes.addItem(ElementMenu(title: "Show \(c.nom)",
                                           geste: { [weak self] in self?.surMontre?(c) }, keyEquivalent: ""))
            }
            if c.peutQuitter {
                gestes.addItem(ElementMenu(title: "Quit \(c.nom)…",
                                           geste: { [weak self] in self?.surQuitte?(c) }, keyEquivalent: ""))
            }
            // Sans geste possible, la ligne reste informative plutôt que de proposer un
            // sous-menu vide, qui se déplie sur rien.
            if !gestes.items.isEmpty { ligne.submenu = gestes }
            menu.addItem(ligne)
        }
        if !conso.isEmpty { menu.addItem(.separator()) }

        menu.addItem(ElementMenu(title: "Open Attix",
                                 geste: { [weak self] in self?.surOuvre?() }, keyEquivalent: ""))
        menu.addItem(ElementMenu(title: "Restart Dock",
                                 geste: { [weak self] in self?.surRelanceDock?() }, keyEquivalent: ""))
        menu.addItem(ElementMenu(title: "Settings…",
                                 geste: { [weak self] in self?.surReglages?() }, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Attix",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }
}
