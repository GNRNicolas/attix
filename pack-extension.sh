#!/bin/zsh
# Fabrique le .zip à téléverser sur le Chrome Web Store.
#
# Le zip doit contenir manifest.json À SA RACINE, pas dans un sous-dossier : zipper le
# dossier parent est l'erreur classique, et le Store la refuse avec un message obscur.
# D'où le `cd` dans le dossier avant de zipper.
#
# -x exclut ce qui ne doit jamais partir : métadonnées macOS, dossiers d'outillage.
set -e
ICI=${0:a:h}
SORTIE="$ICI/docs/attix-chrome.zip"
rm -f "$SORTIE"
cd "$ICI/chrome-extension"
zip -r -X "$SORTIE" . \
  -x '.*' -x '*/.*' -x '__MACOSX/*' -x '.claude/*' >/dev/null
echo "$SORTIE"
unzip -l "$SORTIE"
