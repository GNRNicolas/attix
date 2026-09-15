import AppKit

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
        // 6 et non 9 : cet espacement sépare le titre de section de sa ligne, et les
        // lignes entre elles. Quatre cartes en bas de fenêtre le paient quatre fois.
        pile.spacing = 6
        pile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pile)
        NSLayoutConstraint.activate([
            pile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pile.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            // 10 et non 13 : trois cartes empilées en bas de fenêtre, cela fait 18
            // points repris à la liste des processus, qui est la seule zone dont la
            // hauteur compte vraiment. Une carte à une ligne n'a pas besoin de plus.
            pile.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            pile.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
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

