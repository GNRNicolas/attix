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
/// LA LARGEUR NE BOUGE PAS. Les chiffres sont rendus en chiffres à chasse fixe
/// (`monospacedDigitSystemFont`) : sans cela « 0.9 GB » et « 11.4 GB » n'ont pas la même
/// largeur, l'item se redimensionne à chaque relevé et POUSSE tout ce qui est à sa gauche
/// dans la barre, trois fois par minute. Une icône de veille ne doit jamais bouger.
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
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        i.button?.image = NSImage(systemSymbolName: "memorychip",
                                  accessibilityDescription: "Attix memory")
        i.button?.image?.isTemplate = true
        i.button?.imagePosition = .imageLeading
        i.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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

        bouton.title = " " + go(m.libre)
        // L'icône reste un template (donc noire ou blanche selon le thème) tant que tout
        // va bien : une barre des menus n'est pas un tableau de bord, une couleur y veut
        // dire « regarde-moi ». Elle n'apparaît qu'à partir de la pression du noyau,
        // c'est-à-dire au moment où Jetsam commence à décider.
        let e = m.etat
        if m.pression >= 2 {
            bouton.contentTintColor = e.couleur
            bouton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: e.texte)
            bouton.image?.isTemplate = false
        } else {
            bouton.contentTintColor = nil
            bouton.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: e.texte)
            bouton.image?.isTemplate = true
        }
        bouton.toolTip = "Attix · \(e.texte) · \(go(m.libre)) free"
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
