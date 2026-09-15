#!/usr/bin/env python3
"""Fabrique « Fixdock.shortcut » : UN raccourci, un menu, toutes les actions.

POURQUOI UN SEUL RACCOURCI
Un raccourci par action encombrerait Spotlight d'autant d'entrées : le défaut qu'on
cherchait justement à corriger en supprimant les bundles d'action. Ici, Spotlight ne voit
qu'une entrée, « Fixdock » ; c'est en la lançant que le menu des gestes apparaît.

POURQUOI CE DÉTOUR
La voie directe, des App Intents dans l'app, est fermée : les métadonnées faites à la
main sont structurellement identiques à celles des apps système, mais le système ne les
ingère pas. Les seules apps tierces de cette machine qui exposent des App Intents sont
signées par un vrai certificat. Un raccourci, lui, n'a besoin d'aucune identité.

FORMAT
Un .shortcut non signé est un plist dont WFWorkflowActions est la liste des actions. Le
menu se construit avec trois modes de contrôle de flux sur la même action :
  0 = ouverture du menu (porte la liste des intitulés)
  1 = début d'un cas          2 = fin du menu
`shortcuts sign` le signe pour qu'il s'installe sans avertissement.

DEUX MODES DE SIGNATURE, ET UN SEUL MARCHE ICI
  people-who-know-me : signe localement. Fonctionne, c'est le mode par défaut.
  anyone             : passe par un service Apple, et il répond 500 depuis cette machine
                       (mesuré le 14/09/2026). Nécessaire seulement pour DISTRIBUER le
                       raccourci à des tiers ; inutile pour s'en servir soi-même.
Le script tente « anyone » d'abord et retombe sur l'autre, plutôt que d'échouer.
"""

import plistlib
import subprocess
import sys
import uuid
from pathlib import Path

# Les commandes sont écrites en dur plutôt que d'appeler l'app : un raccourci doit rester
# vrai même si l'app est déplacée, et le geste utile ne doit jamais dépendre d'une fenêtre.
# Chaque geste : le titre montré dans le menu, puis la commande.
#
# LES TITRES RESTENT COURTS. Un essai avec l'explication collée après les deux points a
# été repris : un menu de Raccourcis n'a pas de sous-titre (`WFMenuItems` est une simple
# liste de chaînes, vérifié sur le gabarit d'Apple), donc l'explication s'affichait dans
# la même graisse et la même taille que le geste, et on ne distinguait plus l'un de
# l'autre. Six lignes courtes se parcourent ; six lignes longues se lisent.
GESTES = [
    ("Restart Dock",
     'if [ -x "$HOME/bin/fixdock.sh" ]; then /bin/zsh "$HOME/bin/fixdock.sh" shortcut; '
     'else killall Dock; fi'),
    ("Restart Finder", "killall Finder"),
    ("Restart Menu Bar", "killall ControlCenter SystemUIServer 2>/dev/null; true"),
    ("Quit Chrome", "osascript -e 'tell application \"Google Chrome\" to quit'"),
    ("Stop Stale Dev Servers",
     'for pid in $(pgrep -x node; pgrep -x bun); do '
     'cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n "s/^n//p" | head -1); '
     '[ -n "$cwd" ] && [ ! -d "$cwd" ] && kill -TERM "$pid"; done; true'),
    ("Open Fixdock", 'open -a /Applications/Fixdock.app'),
]

GROUPE = str(uuid.uuid4()).upper()


def action(ident, params):
    return {"WFWorkflowActionIdentifier": ident, "WFWorkflowActionParameters": params}


def shell(commande):
    """Une action « Exécuter un script shell » : le script, un UUID, rien d'autre.

    RELEVÉ SUR UN VRAI RACCOURCI, pas déduit : un raccourci fabriqué dans l'app et
    exporté ne porte que ces deux clés. `Shell` et `InputMode` valaient déjà leur valeur
    par défaut, et l'app ne les écrit pas. On fait pareil : moins on invente de champs,
    moins on peut en inventer un de travers.
    """
    return action("is.workflow.actions.runshellscript", {
        "Script": commande,
        "UUID": str(uuid.uuid4()).upper(),
    })


def construire():
    actions = [action("is.workflow.actions.choosefrommenu", {
        "GroupingIdentifier": GROUPE,
        "WFControlFlowMode": 0,
        "WFMenuPrompt": "Fixdock",
        "WFMenuItems": [titre for titre, _ in GESTES],
    })]
    for titre, commande in GESTES:
        actions.append(action("is.workflow.actions.choosefrommenu", {
            "GroupingIdentifier": GROUPE,
            "WFControlFlowMode": 1,
            "WFMenuItemTitle": titre,
        }))
        actions.append(shell(commande))
    # La fermeture du menu porte un UUID chez Apple ; on fait pareil.
    actions.append(action("is.workflow.actions.choosefrommenu", {
        "GroupingIdentifier": GROUPE,
        "WFControlFlowMode": 2,
        "UUID": str(uuid.uuid4()).upper(),
    }))
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "4711",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        # L'ICÔNE D'UN RACCOURCI : une couleur et un glyphe, pas une image.
        #
        # Le format n'offre RIEN d'autre : vérifié sur les sept raccourcis de la galerie
        # d'Apple livrés dans WorkflowKit, qui ne portent tous que ces deux clés. Le logo
        # de l'app ne peut donc pas être repris tel quel ; on s'en approche par la couleur.
        #
        # Ce n'est pas une limite qu'on suppose, c'est le SCHÉMA : l'entité
        # `WFCoreDataWorkflowIcon` du modèle CoreData de Raccourcis
        # (WorkflowKit/Resources/Shortcuts.momd) ne porte que deux attributs,
        # `glyphNumber` et `backgroundColorValue`. Il n'y a nulle part où ranger une image.
        #
        # La couleur est un entier 0xRRGGBBAA (relevé sur les raccourcis d'Apple : leur
        # jaune vaut 4274264319, soit 0xFEC72BFF). 0x8E8E93FF est le gris système.
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 61440,
            "WFWorkflowIconStartColor": 0x8E8E93FF,
        },
        "WFWorkflowImportQuestions": [],
        # La liste que l'app écrit d'office. Vide, elle dit « ce raccourci n'accepte
        # aucune entrée », ce qui n'est pas la même chose que « il n'en demande pas ».
        "WFWorkflowInputContentItemClasses": [
            "WFAppContentItem", "WFAppStoreAppContentItem", "WFArticleContentItem",
            "WFContactContentItem", "WFDateContentItem", "WFEmailAddressContentItem",
            "WFFolderContentItem", "WFGenericFileContentItem", "WFImageContentItem",
            "WFiTunesProductContentItem", "WFLocationContentItem", "WFDCMapsLinkContentItem",
            "WFAVAssetContentItem", "WFPDFContentItem", "WFPhoneNumberContentItem",
            "WFRichTextContentItem", "WFSafariWebPageContentItem", "WFStringContentItem",
            "WFURLContentItem",
        ],
        # Présent dans tous les raccourcis d'Apple, absent du nôtre jusqu'ici.
        "WFWorkflowOutputContentItemClasses": [],
        # LA CLÉ QUI MANQUAIT, et elle porte son explication dans son nom.
        #
        # Un raccourci n'est proposé par Spotlight que s'il déclare ce type. Le nôtre
        # avait une liste vide : il s'installait, se lançait depuis l'app Raccourcis, et
        # restait introuvable dans Spotlight. Relevé en comparant un raccourci fabriqué
        # dans l'app (qui, lui, sortait) au nôtre, après déchiffrement des deux fichiers.
        "WFWorkflowTypes": ["WFWorkflowTypeShowInSearch"],
        "WFQuickActionSurfaces": [],
    }


def main():
    sortie = Path(sys.argv[1] if len(sys.argv) > 1 else "Fixdock.shortcut")
    brut = sortie.with_suffix(".unsigned.shortcut")
    brut.write_bytes(plistlib.dumps(construire(), fmt=plistlib.FMT_BINARY))
    for mode in ("anyone", "people-who-know-me"):
        r = subprocess.run(["shortcuts", "sign", "--mode", mode,
                            "-i", str(brut), "-o", str(sortie)],
                           capture_output=True, text=True)
        if r.returncode == 0:
            print(f"  (signé en mode {mode})")
            break
        print(f"  ! mode {mode} refusé : {(r.stderr or r.stdout).strip()[:120]}", file=sys.stderr)
    else:
        print(f"  (le fichier non signé reste disponible : {brut})", file=sys.stderr)
        return 1
    brut.unlink(missing_ok=True)
    print(f"  ✓ {sortie} : {len(GESTES)} gestes dans un seul raccourci")
    return 0


if __name__ == "__main__":
    sys.exit(main())
