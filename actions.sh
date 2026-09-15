#!/bin/zsh
# Construit les ACTIONS SPOTLIGHT de Fixdock : un bundle .app par geste.
#
# POURQUOI DES BUNDLES ET PAS DES APP INTENTS
# Le Spotlight de macOS 26 sait exécuter des « Actions » déclarées par une app via le
# framework AppIntents. Cette voie est fermée ici : le framework est bien dans le SDK des
# Command Line Tools, mais `appintentsmetadataprocessor` : l'outil qui produit le
# Metadata.appintents que le système indexe : n'existe que dans Xcode, absent de cette
# machine. Sans métadonnées, aucune action n'est découverte. On revient donc au mécanisme
# que Fixdock.app utilise déjà et qui, lui, marche partout : Spotlight indexe /Applications
# et ~/Applications, et sait lancer une app.
#
# POURQUOI LE PRÉFIXE « Fixdock »
# Spotlight cherche dans le NOM. Une app nommée « Restart Dock » ne sortirait pas sur
# « fixdock » ; préfixées, elles sortent toutes ensemble quand on tape « fixdock », et
# chacune sort aussi sur son propre nom (« restart dock », « quit chrome »).
#
# CE QUE CHAQUE ACTION EST
# Un bundle minimal dont l'exécutable est un script zsh. Pas de logique dupliquée : le
# redémarrage du Dock appelle ~/bin/fixdock.sh, la référence unique.
#
# LES NOTIFICATIONS PASSENT PAR osascript, ET C'EST MESURÉ
# L'idée séduisante est de les émettre depuis le binaire de Fixdock, pour qu'elles portent
# son icône plutôt que celle de Script Editor. Cette voie NE MARCHE PAS ici :
# UNUserNotificationCenter, appelé depuis un bundle signé ad hoc (sans TeamIdentifier),
# rend 0 sans rien afficher et sans rien journaliser : un échec parfaitement silencieux.
# Vérifié le 14/09/2026 sur macOS 26.6.2, sur ce binaire ET sur celui de Fixdock.app :
# aucune des deux apps n'apparaît dans com.apple.ncprefs, aucune bannière ne s'affiche.
# osascript, lui, affiche. On préfère donc une notification visible avec la mauvaise icône
# à une notification parfaite qui n'existe pas.
#
# LSUIElement = 1 : pas d'icône dans le Dock, pas de vol de focus. L'action s'exécute et
# se termine : on ne la « quitte » pas.
#
# Idempotent : relancer ce script reconstruit les bundles à l'identique.
# Pour les retirer : rm -rf "~/Applications/Fixdock Actions"

set -e
ICI=${0:A:h}
CIBLE=${1:-$HOME/Applications/Fixdock Actions}
ICONE=${ICONE:-$HOME/BRAIN/03-OUTILLAGE/mac/assets/fixdock-icon.png}
NOTIFIEUR="$HOME/Applications/Fixdock Lab.app/Contents/MacOS/fixdock-lab"

mkdir -p "$CIBLE"

# ─── le jeu d'icônes, construit une fois et partagé par tous les bundles ──────
JEU=$(mktemp -d)/AppIcon.iconset
mkdir -p "$JEU"
if [[ -f $ICONE ]]; then
  sips -s format png -z 1024 1024 "$ICONE" --out "$JEU/maitre.png" >/dev/null
  for paire in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
               256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    px=${paire%%:*}; nom=${paire##*:}
    sips -z $px $px "$JEU/maitre.png" --out "$JEU/icon_$nom.png" >/dev/null 2>&1
  done
  rm -f "$JEU/maitre.png"
  ICNS=$(mktemp -d)/AppIcon.icns
  iconutil -c icns "$JEU" -o "$ICNS"
fi

# ─── fabrique ────────────────────────────────────────────────────────────────
# $1 = nom affiché (sans le préfixe)  $2 = suffixe d'identifiant  $3 = corps du script
bundle() {
  local nom="Fixdock $1" ident="$2" corps="$3"
  local app="$CIBLE/$nom.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  [[ -n ${ICNS:-} && -f $ICNS ]] && cp "$ICNS" "$app/Contents/Resources/AppIcon.icns"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>$nom</string>
	<key>CFBundleDisplayName</key>     <string>$nom</string>
	<key>CFBundleIdentifier</key>      <string>fr.nicomatsuri.fixdock.action.$ident</string>
	<key>CFBundleExecutable</key>      <string>action</string>
	<key>CFBundleIconFile</key>        <string>AppIcon</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleShortVersionString</key> <string>0.1</string>
	<key>CFBundleVersion</key>         <string>1</string>
	<key>LSUIElement</key>             <true/>
	<key>LSMinimumSystemVersion</key>  <string>13.0</string>
</dict>
</plist>
PLIST

  cat > "$app/Contents/MacOS/action" <<SCRIPT
#!/bin/zsh
# Généré par PROJECTS/Fixdock/actions.sh : ne pas éditer ici.
dis() {
  osascript -e "display notification \"\$1\" with title \"Fixdock\"" 2>/dev/null
}
$corps
SCRIPT
  chmod +x "$app/Contents/MacOS/action"

  codesign --force --sign - "$app" >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$app" 2>/dev/null || true
  touch "$app"
  print -r -- "  ✓ $nom"
}

# ─── les actions ─────────────────────────────────────────────────────────────

# Le Dock : on délègue à ~/bin/fixdock.sh, qui reste la seule logique (il journalise,
# attend le retour du processus et notifie lui-même).
bundle "Restart Dock" dock '
if [[ -x $HOME/bin/fixdock.sh ]]; then
  exec /bin/zsh "$HOME/bin/fixdock.sh" spotlight
fi
killall Dock 2>/dev/null && dis "Dock restarted." || dis "Dock was not running."
'

# Le Finder ne détient rien : launchd le relance seul. Seules les fenêtres ouvertes
# disparaissent.
bundle "Restart Finder" finder '
killall Finder 2>/dev/null && dis "Finder restarted." || dis "Finder was not running."
'

# La barre de menus, c'est deux processus distincts : les rater tous les deux est la
# cause habituelle du « j'\''ai relancé et rien n'\''a changé ».
bundle "Restart Menu Bar" menubar '
n=0
for p in ControlCenter SystemUIServer NotificationCenter; do
  killall "$p" 2>/dev/null && n=$((n+1))
done
dis "Menu bar restarted ($n processes)."
'

# Quitter Chrome par AppleScript et non par kill : c'\''est le « Quitter » du menu, Chrome
# enregistre sa session et rouvrira ses onglets.
bundle "Quit Chrome" chrome '
if ! pgrep -x "Google Chrome" >/dev/null 2>&1; then dis "Chrome is not running."; exit 0; fi
avant=$(ps -Ao rss=,comm= | grep "Google Chrome" | awk "{s+=\$1} END {printf \"%.0f\", s/1024}")
osascript -e "tell application \"Google Chrome\" to quit" 2>/dev/null
for _ in {1..30}; do pgrep -x "Google Chrome" >/dev/null 2>&1 || break; sleep 0.2; done
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  dis "Chrome did not quit : it may be asking you to confirm."
else
  dis "Chrome quit. ${avant} MB freed."
fi
'

bundle "Quit Slack" slack '
if ! pgrep -x Slack >/dev/null 2>&1; then dis "Slack is not running."; exit 0; fi
avant=$(ps -Ao rss=,comm= | grep Slack | awk "{s+=\$1} END {printf \"%.0f\", s/1024}")
osascript -e "tell application \"Slack\" to quit" 2>/dev/null
for _ in {1..30}; do pgrep -x Slack >/dev/null 2>&1 || break; sleep 0.2; done
dis "Slack quit. ${avant} MB freed."
'

# Les serveurs orphelins : mêmes règles que dans l'\''app, on n'\''arrête QUE ce dont le
# répertoire de travail a disparu. C'\''est un fait vérifiable, pas une heuristique.
bundle "Stop Stale Dev Servers" stale '
tues=0; libere=0
for p in node bun deno esbuild; do
  for pid in $(pgrep -x "$p" 2>/dev/null); do
    cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n "s/^n//p" | head -1)
    [[ -z $cwd || -d $cwd ]] && continue
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d " ")
    kill -TERM "$pid" 2>/dev/null || continue
    tues=$((tues+1)); libere=$((libere + ${rss:-0}/1024))
  done
done
if (( tues == 0 )); then dis "No stale dev servers found."
else dis "Stopped $tues stale server(s). ${libere} MB freed."; fi
'

# La porte vers la fenêtre, pour rester cohérent : tout part de Spotlight.
bundle "Memory" memory '
open -a "$HOME/Applications/Fixdock Lab.app" 2>/dev/null || dis "Fixdock Lab is not installed."
'

rm -rf "${JEU:h}" "${ICNS:h}" 2>/dev/null || true
print -r -- ""
print -r -- "Actions installées dans : $CIBLE"
print -r -- "Tape « fixdock » dans Spotlight pour les voir toutes."
