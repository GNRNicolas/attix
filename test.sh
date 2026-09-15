#!/bin/zsh
# Lance la suite de tests des fonctions pures.
#
# Ni Xcode ni SwiftPM sur cette machine, donc pas de XCTest : on compile un exécutable
# autonome avec swiftc, comme build.sh le fait pour l'app.
#
# CE QUI N'EST PAS COMPILÉ ICI, et c'est volontaire : main.swift, qui porte l'amorçage
# de NSApplication au premier niveau. Un binaire ne peut avoir qu'un point d'entrée, et
# c'est Tests/main.swift qui l'est. On ne prend donc que les fichiers nécessaires.
#
# Et symétriquement : Tests/ est un SOUS-DOSSIER parce que build.sh compile « $ICI/*.swift ».
# Un fichier de test posé à la racine partirait dans le binaire livré.

set -e
ICI=${0:A:h}
CACHE="${TMPDIR:-/tmp}/fixdock-cache-tests"
BIN="${TMPDIR:-/tmp}/fixdock-tests.bin"
mkdir -p "$CACHE"

swiftc -module-name FixdockTests -module-cache-path "$CACHE" \
  -o "$BIN" "$ICI/Mesures.swift" "$ICI/Tests"/*.swift

"$BIN"
