import Foundation

/// Ce qui mérite une alerte, et à quel rythme : la seule décision que l'usager règle.
///
/// POURQUOI UN RÉGLAGE ET NON DE MEILLEURS SEUILS. Sur une machine qui vit près de sa
/// limite, la pression du noyau passe en `warning` des dizaines de fois par jour, et
/// chaque rapport Jetsam « per-process-limit » (une app qui bute sur SA limite, rien à
/// faire) ouvrait lui aussi un panneau, sans aucun délai. Aucun seuil fixe ne convient
/// à la fois à qui veut tout voir et à qui ne veut savoir que quand macOS tue.
///
/// Fonctions pures, sans AppKit : compilées par test.sh, donc vérifiées.
enum NiveauAlertes: String, CaseIterable {
    case toutes, critiques, aucune

    var titre: String {
        switch self {
        case .toutes: return "Memory warnings and app kills"
        case .critiques: return "Only when macOS kills apps"
        case .aucune: return "Never"
        }
    }
}

struct PolitiqueAlertes {
    var niveau: NiveauAlertes = .toutes
    /// Jamais deux alertes plus rapprochées que ça, quelle qu'en soit la source.
    var intervalle: TimeInterval = 900

    /// Les rythmes proposés dans les réglages.
    static let intervalles: [TimeInterval] = [300, 900, 1800, 3600]

    /// À niveau constant, on réannonce au plus tôt une demi-heure plus tard, et jamais
    /// avant l'intervalle choisi : un intervalle d'une heure ne doit pas céder au rappel.
    var rappel: TimeInterval { max(1800, intervalle) }

    /// La pression du noyau : 1 normal, 2 warning, 4 critical.
    /// `annonce` est le dernier niveau annoncé, `ecoule` le temps depuis la dernière alerte.
    func pression(_ niveauNoyau: Int, annonce: Int, ecoule: TimeInterval) -> Bool {
        switch niveau {
        case .aucune: return false
        case .critiques: guard niveauNoyau >= 4 else { return false }
        case .toutes: guard niveauNoyau >= 2 else { return false }
        }
        // Le plancher s'applique AUSSI à l'aggravation : sans lui, une pression qui
        // oscille entre normal et warning repasse pour une aggravation à chaque relevé.
        guard ecoule > intervalle else { return false }
        return niveauNoyau > annonce || ecoule > rappel
    }

    /// Un rapport Jetsam neuf. `critique` : le noyau a tué pour libérer la machine,
    /// et non parce qu'une app a atteint sa propre limite.
    func jetsam(critique: Bool, ecoule: TimeInterval) -> Bool {
        switch niveau {
        case .aucune: return false
        case .critiques: guard critique else { return false }
        case .toutes: break
        }
        return ecoule > intervalle
    }
}
