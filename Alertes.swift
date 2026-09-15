import AppKit

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

    /// Une alerte déjà affichée ne se remplace pas par une autre : la remplacer la ferait
    /// clignoter et remettrait son compte à rebours à zéro à chaque relevé.
    var visible: Bool { panneau != nil }

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
        // cliquer, donc ouvrir Attix. Écarter une alerte qu'on a lue et comprise est un
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

