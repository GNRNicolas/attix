import AppKit
import Darwin
import ServiceManagement

// Attix Lab : la fenêtre actionnable de Attix.
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
final class FenetreAttix: NSWindow {
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Fenêtre
// ─────────────────────────────────────────────────────────────────────────────

final class Controleur: NSObject, NSWindowDelegate {
    private var fenetre: FenetreAttix!
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
                     "One Attix entry, every action inside. Needs Allow Running Scripts.")
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

        fenetre = FenetreAttix(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        fenetre.title = "Attix"
        // Fermer la fenêtre ne détruit ni la fenêtre ni l'app : Attix continue de
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
        // raccourci ne vaut que quand Attix est au premier plan, ce qui évite de
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
        var conseil = "Open Attix to see what is using your memory."
        if let c = cible {
            conseil = "\(c.nom) is using \(go(c.octets)). Click to quit it from Attix."
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
                          "Chrome is using 1.3 GB. Click to quit it from Attix.",
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
                              rappel: "Attix already starts with your Mac. Manage it in System Settings > General > Login Items.")
        bRaccourci.marqueFait(raccourci, titre: "Install",
                              rappel: "The Attix shortcut is installed. Click again to reinstall an updated version.")
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
        try? t.write(toFile: NSHomeDirectory() + "/attix-diag.txt",
                     atomically: true, encoding: .utf8)

        // Le rendu AppKit de la fenêtre, sans passer par une capture d'écran : pas de
        // permission à demander, et rien d'autre que notre propre fenêtre.
        if let v = fenetre?.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/attix-diag.png"))
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
        sousApp.addItem(NSMenuItem(title: "Hide Attix", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        sousApp.addItem(NSMenuItem(title: "Quit Attix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
