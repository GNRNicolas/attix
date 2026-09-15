#!/bin/zsh
# Construit « Fixdock.app » : LA seule app. Elle remplace celle que produisait
# BRAIN/03-OUTILLAGE/mac/fixdock-app.sh, dont elle reprend le nom et l'identifiant.
#
# Il y a eu deux apps pendant la mise au point : une « Fixdock Lab » à côté de l'originale,
# pour ne rien casser tant qu'on essayait. Ce n'est plus justifié une fois que la nouvelle
# fait tout ce que faisait l'ancienne : deux entrées Spotlight pour un même outil sont un
# défaut, pas une précaution. Ce script supprime donc l'ancienne installation.
#
# CE QUI N'EST PAS TOUCHÉ : ~/bin/fixdock.sh (la logique de relance du Dock, appelée par
# l'app comme par l'action Spotlight), l'entrée du menu Services, et memwatch.
#
# EFFET DE BORD SOUHAITABLE : fixdock.sh appelait /Applications/Fixdock.app/Contents/
# MacOS/fixdock-app pour ses notifications : un chemin qui échouait en silence (voir
# actions.sh). Ce binaire disparaît, donc fixdock.sh bascule sur son repli osascript,
# qui lui fonctionne. Ses notifications se remettent à s'afficher.
#
# LSUIElement est ABSENT ici, contrairement à Fixdock.app : cette app a une fenêtre, elle
# doit donc pouvoir prendre le focus et apparaître dans le Dock. Une app LSUIElement peut
# afficher une fenêtre mais jamais la mettre au premier plan proprement.

set -e
ICI=${0:A:h}
CIBLE=${1:-/Applications}
APP="$CIBLE/Fixdock.app"
ICONE=${ICONE:-$HOME/BRAIN/03-OUTILLAGE/mac/assets/fixdock-icon.png}

mkdir -p "$CIBLE"
JEU=$(mktemp -d)/AppIcon.iconset
mkdir -p "$JEU"

# ─── icône ───────────────────────────────────────────────────────────────────
if [[ -f $ICONE ]]; then
  sips -s format png -z 1024 1024 "$ICONE" --out "$JEU/maitre.png" >/dev/null
else
  # Repli minimal : un carré uni. L'icône n'est pas le sujet de la version d'essai.
  python3 -c "
import struct,zlib,sys
w=h=1024; px=b''.join(b'\x00'+bytes([52,120,199,255])*w for _ in range(h))
def c(t,d):
    x=t+d; return struct.pack('>I',len(d))+x+struct.pack('>I',zlib.crc32(x))
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+c(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+c(b'IDAT',zlib.compress(px))+c(b'IEND',b''))
" "$JEU/maitre.png"
fi

for paire in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
             256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  px=${paire%%:*}; nom=${paire##*:}
  sips -z $px $px "$JEU/maitre.png" --out "$JEU/icon_$nom.png" >/dev/null 2>&1
done
rm -f "$JEU/maitre.png"

# ─── bundle ──────────────────────────────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
iconutil -c icns "$JEU" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>Fixdock</string>
	<key>CFBundleDisplayName</key>     <string>Fixdock</string>
	<key>CFBundleIdentifier</key>      <string>fr.nicomatsuri.fixdock</string>
	<key>CFBundleExecutable</key>      <string>fixdock</string>
	<key>CFBundleIconFile</key>        <string>AppIcon</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleShortVersionString</key> <string>0.1</string>
	<key>CFBundleVersion</key>         <string>1</string>
	<key>LSMinimumSystemVersion</key>  <string>14.0</string>
	<key>NSHumanReadableCopyright</key><string>PROJECTS/Fixdock/build.sh</string>
</dict>
</plist>
PLIST

CACHE="${TMPDIR:-/tmp}/fixdock-cache"
mkdir -p "$CACHE"

# Le nom de MODULE est figé à « Fixdock » : le nom Swift mangé des App Intents en dépend,
# et c'est lui que les métadonnées désignent. L'app peut être renommée sans rien casser.
#
# Swift n'accepte du code au premier niveau que dans un fichier nommé main.swift, et il en
# faut exactement un dès qu'on compile plusieurs fichiers : d'où la copie dans un dossier
# de travail plutôt qu'un renommage de la source.
TRAVAIL=$(mktemp -d)
cp "$ICI/fixdock-lab.swift" "$TRAVAIL/main.swift"
cp "$ICI/appintents.swift" "$TRAVAIL/"
swiftc -O -module-name Fixdock -module-cache-path "$CACHE" \
  -o "$APP/Contents/MacOS/fixdock" "$TRAVAIL/main.swift" "$TRAVAIL/appintents.swift"
rm -rf "$TRAVAIL"

# Les métadonnées App Intents, que produirait appintentsmetadataprocessor si Xcode était
# installé. Voir metadata.py pour le détail du format et du relevé des noms mangés.
python3 "$ICI/metadata.py" "$APP/Contents/MacOS/fixdock" Fixdock \
  "$APP/Contents/Resources/Metadata.appintents" || true
rm -rf "${JEU:h}"

# Le raccourci Spotlight voyage DANS le bundle : l'app peut ainsi proposer son
# installation en un clic, sans dépendre d'un fichier laissé quelque part sur le disque.
[[ -f "$ICI/Fixdock.shortcut" ]] && cp "$ICI/Fixdock.shortcut" "$APP/Contents/Resources/"

codesign --force --sign - "$APP" >/dev/null 2>&1

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true
touch "$APP"
# L'installation d'essai n'a plus de raison d'être.
rm -rf "$HOME/Applications/Fixdock Lab.app"

print -r -- "✓ $APP"
