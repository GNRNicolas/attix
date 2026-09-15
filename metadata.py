#!/usr/bin/env python3
"""Génère Metadata.appintents : ce que ferait `appintentsmetadataprocessor` d'Xcode.

POURQUOI CE SCRIPT EXISTE
Les actions qu'un Spotlight de macOS 26 propose sous Tab viennent du framework AppIntents.
Le framework lui-même est dans le SDK des Command Line Tools et compile sans souci ; ce
qui manque, c'est l'outil qui produit le dossier `Metadata.appintents` indexé par le
système : il n'est livré qu'avec Xcode. Installer Xcode pour un seul générateur de JSON
n'est pas raisonnable, et le format s'est avéré lisible : `extract.actionsdata` est du
JSON en clair, et le titre d'une action accepte une chaîne littérale (vérifié sur Notes,
Podcasts, Mail : `"title": {"key": "Show Quick Note"}`, aucun fichier de traduction).

LE SEUL POINT DÉLICAT
Chaque action est désignée par son nom Swift « mangé » (`mangledTypeName`), par exemple
`7Fixdock17RestartDockIntentV`. On ne le devine pas : on le LIT dans le binaire compilé
avec `nm`. C'est ce qui rend le procédé fiable plutôt qu'approximatif : renommer l'app,
changer sa version ou la re-signer ne peut pas le désynchroniser.

USAGE
  metadata.py <binaire> <module> <dossier Metadata.appintents>
"""

import json
import re
import subprocess
import sys
from pathlib import Path

# Les actions exposées : nom du type Swift -> (titre, description).
# Les titres sont ce que Spotlight affiche ; ils doivent rester courts et commencer par
# un verbe : c'est un geste qu'on choisit, pas une rubrique qu'on consulte.
ACTIONS = {
    "RestartDockIntent": (
        "Restart Dock",
        "Restart the Dock. Mission Control and Launchpad come back with it. "
        "They are the same process.",
    ),
    "RestartFinderIntent": (
        "Restart Finder",
        "Restart the Finder. It holds no unsaved data; only open Finder windows close.",
    ),
    "QuitChromeIntent": (
        "Quit Chrome",
        "Ask Chrome to quit normally. It saves its session and restores your tabs next time.",
    ),
    "StopStaleServersIntent": (
        "Stop Stale Dev Servers",
        "Stop dev servers whose working folder no longer exists. "
        "They are leftovers from deleted worktrees.",
    ),
}


# Les phrases que Siri et le champ de recherche acceptent. ${applicationName} est remplacé
# par le nom de l'app : c'est ce qui permet de la renommer sans réécrire une seule phrase.
PHRASES = {
    "RestartDockIntent": ["Restart Dock with ${applicationName}",
                          "Fix the Dock with ${applicationName}"],
    "RestartFinderIntent": ["Restart Finder with ${applicationName}"],
    "QuitChromeIntent": ["Quit Chrome with ${applicationName}"],
    "StopStaleServersIntent": ["Stop stale dev servers with ${applicationName}"],
}

FOURNISSEUR = "FixdockShortcuts"


def mangle(module: str, type_: str) -> str:
    """Le nom mangé d'une struct : longueur+module, longueur+type, puis V."""
    return f"{len(module)}{module}{len(type_)}{type_}V"


def present(binaire: str, module: str, type_: str) -> bool:
    """Le type est-il réellement dans le binaire livré ?

    On regarde d'abord les symboles, puis les chaînes : le descripteur du fournisseur
    d'App Shortcuts n'apparaît pas toujours comme symbole après édition de liens, alors
    que son nom reste présent dans les données du binaire.
    """
    syms = subprocess.run(["nm", "-a", binaire], capture_output=True, text=True).stdout
    if re.search(rf"\$s{re.escape(mangle(module, type_))}", syms):
        return True
    chaines = subprocess.run(["strings", binaire], capture_output=True, text=True).stdout
    return type_ in chaines.split()


def noms_manges(binaire: str, module: str) -> dict[str, str]:
    """Relève dans le binaire le nom mangé de chaque type d'action.

    Un descripteur de type nominal Swift se termine par `V` pour une struct, précédé de la
    longueur du module puis de celle du type : `7Fixdock17RestartDockIntentV`. On cherche
    donc cette forme exacte plutôt que de la reconstruire, pour que le fichier produit
    corresponde toujours au binaire réellement livré.
    """
    # `nm` SANS -gU : après édition de liens, ces descripteurs deviennent des symboles
    # locaux et disparaissent de la liste des symboles globaux. Chercher parmi les seuls
    # globaux ne rendait rien, et le script concluait à tort qu'aucune action n'existait.
    sortie = subprocess.run(["nm", "-a", binaire], capture_output=True, text=True).stdout
    trouves: dict[str, str] = {}
    for type_ in ACTIONS:
        motif = rf"\$s{len(module)}{module}{len(type_)}{type_}V"
        if re.search(motif, sortie):
            trouves[type_] = f"{len(module)}{module}{len(type_)}{type_}V"
    return trouves


def action(identifiant: str, mangle: str, module: str, titre: str,explication: str) -> dict:
    """Une entrée d'action, calquée sur celles des apps système (Notes, Podcasts)."""
    return {
        "actionConfiguration": {
            "actionSummary": {
                "wrapper": {
                    "otherParameterIdentifiers": [],
                    "summaryString": {"formatString": titre, "parameterIdentifiers": []},
                }
            }
        },
        "assistantDefinedSchemaTraits": [],
        "assistantDefinedSchemas": [],
        "authenticationPolicy": 0,
        "availabilityAnnotations": {"LNPlatformNameWildcard": {"introducedVersion": "*"}},
        "descriptionMetadata": {
            "descriptionText": {"alternatives": [], "key": explication},
            "searchKeywords": [],
        },
        "effectiveBundleIdentifiers": [],
        "fullyQualifiedTypeName": f"{module}.{identifiant}",
        "identifier": identifiant,
        "isAuthPolExplicit": False,
        "isDiscoverable": True,
        "mangledTypeName": mangle,
        "mangledTypeNameByBundleIdentifier": {},
        "mangledTypeNameByBundleIdentifierV2": {},
        "mangledTypeNameV2": mangle,
        "openAppWhenRun": False,
        "outputFlags": 0,
        "parameters": [],
        "presentationStyle": 0,
        "requiredCapabilities": [],
        "supportedModes": 1,
        "systemProtocolMetadata": [],
        "systemProtocolMetadataV2": [],
        "systemProtocols": [],
        "title": {"alternatives": [], "key": titre},
        "typeSpecificMetadata": [],
        "visibilityMetadata": {"assistantOnly": False, "isDiscoverable": True},
    }


def main() -> int:
    binaire, module, sortie = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    manges = noms_manges(binaire, module)

    manquants = [t for t in ACTIONS if t not in manges]
    if manquants:
        print(f"  ! absents du binaire, ignorés : {', '.join(manquants)}", file=sys.stderr)
    if not manges:
        print("  ! aucune action trouvée : métadonnées non générées", file=sys.stderr)
        return 1

    donnees = {
        "actions": {
            t: action(t, manges[t], module, *ACTIONS[t]) for t in sorted(manges)
        },
        # Sans ce fournisseur, les actions ne remontent PAS dans Spotlight : les apps
        # système qui n'exposent que des intents « découvrables » n'y apparaissent pas non
        # plus. C'est la liste autoShortcuts que le Tab de Spotlight affiche.
        "autoShortcutProviderMangledName": mangle(module, FOURNISSEUR),
        "assistantEntities": [],
        "assistantIntentNegativePhrases": [],
        "assistantIntents": [],
        "autoShortcuts": [
            {
                "actionIdentifier": t,
                "availabilityAnnotations": {
                    "LNPlatformNameWildcard": {"introducedVersion": "*"}
                },
                "phraseTemplates": [
                    {"alternatives": [], "key": ph} for ph in PHRASES.get(t, [])
                ],
                "shortTitle": {"alternatives": [], "key": ACTIONS[t][0]},
                "systemImageName": "bolt",
            }
            for t in sorted(manges)
            if PHRASES.get(t)
        ],
        "entities": {},
        "enums": [],
        # Xcode inscrit ici "xcode-tools" et sa version. On reprend cette valeur parce
        # qu'un générateur inconnu est l'un des deux seuls suspects restants quand les
        # actions n'apparaissent pas (l'autre étant la signature ad hoc) : la structure,
        # elle, a été comparée champ par champ à celle de Notes et se révèle identique.
        # Remettre "fixdock-metadata.py" ici est la façon de vérifier si ce champ compte.
        "generator": {"name": "xcode-tools", "version": "17E6107"},
        "negativePhrases": [],
        "queries": {},
        "shortcutTileColor": 14,
        "version": 1,
    }

    sortie.mkdir(parents=True, exist_ok=True)
    (sortie / "extract.actionsdata").write_text(json.dumps(donnees, separators=(",", ":")))
    (sortie / "version.json").write_text(
        json.dumps({"version": "3.0", "toolsVersion": "17E6107"}, indent=2)
    )
    print(f"  ✓ {len(manges)} actions : {', '.join(sorted(manges))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
