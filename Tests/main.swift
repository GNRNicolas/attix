import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Harnais
// ─────────────────────────────────────────────────────────────────────────────
//
// Ni XCTest ni SwiftPM sur cette machine (pas d'Xcode, pas de Package.swift) : ce
// fichier est un exécutable autonome, compilé par ./test.sh avec les seuls fichiers
// source dont il a besoin. Il vit dans Tests/ et non à la racine, parce que build.sh
// compile « $ICI/*.swift » : un test posé à la racine partirait dans l'app livrée.

var passes = 0
var echecs = 0

func verifie<T: Equatable>(_ nom: String, _ obtenu: T, _ attendu: T) {
    if obtenu == attendu {
        passes += 1
        print("  ok   \(nom)")
    } else {
        echecs += 1
        print("  FAIL \(nom)")
        print("       expected: \(attendu)")
        print("       got:      \(obtenu)")
    }
}

func section(_ titre: String) { print("\n\(titre)") }

/// Les lignes de `ps` sont des tuples, qui ne sont pas Equatable : on les compare
/// sous une forme textuelle stable.
func aplati(_ lignes: [(rss: UInt64, pid: Int32, chemin: String)]) -> [String] {
    lignes.map { "\($0.rss)|\($0.pid)|\($0.chemin)" }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 1. Sonde.analyse : le découpage de la sortie de ps
// ─────────────────────────────────────────────────────────────────────────────
//
// LE bug le plus coûteux du projet. Une version antérieure découpait avec
// split(maxSplits: 2, omittingEmptySubsequences: true). `ps` aligne ses colonnes à
// droite : toute ligne dont le RSS n'occupe pas la largeur entière commence par des
// espaces, et ces espaces consommaient le premier split. Il n'en restait qu'un, la
// ligne rendait 2 champs au lieu de 3 et était écartée : 566 lignes perdues sur 575,
// Chrome affiché à 205 Mo au lieu de 1 273. Ces cas verrouillent le découpage manuel.

section("Sonde.analyse (ps output splitting)")

// Le cas qui cassait : RSS court, donc espaces de tête à cause de l'alignement à droite.
verifie("leading spaces before a short RSS",
        aplati(Sonde.analyse("   1234 567 /usr/bin/foo")),
        ["1263616|567|/usr/bin/foo"])

// Le cas qui, lui, passait déjà : RSS assez large pour remplir la colonne.
verifie("wide RSS with no leading space",
        aplati(Sonde.analyse("1303456 12 /usr/bin/bar")),
        ["1334738944|12|/usr/bin/bar"])

// Régression des 566 lignes : lignes larges et étroites mélangées, TOUTES doivent
// survivre. Avec l'ancien split, seules les larges restaient.
verifie("narrow and wide lines all survive together",
        aplati(Sonde.analyse("""
        1303456 12 /wide/one
            205 13 /narrow/one
              7 14 /narrow/two
        1000000 15 /wide/two
        """)).count,
        4)

// Un chemin contient des espaces (« /Applications/Google Chrome.app/... ») : seuls les
// deux premiers champs sont découpés, le reste est le chemin tel quel.
let cheminChrome = "/Applications/Google Chrome.app/Contents/Frameworks/"
    + "Google Chrome Framework.framework/Versions/140/Helpers/"
    + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
verifie("path containing spaces is kept whole",
        aplati(Sonde.analyse("  40960 999 \(cheminChrome)")),
        ["41943040|999|\(cheminChrome)"])

// Plusieurs espaces entre les colonnes : ils sont absorbés, pas comptés comme champs.
verifie("multiple spaces between columns",
        aplati(Sonde.analyse("  512     42     /usr/bin/baz")),
        ["524288|42|/usr/bin/baz"])

// Une ligne vide ne doit produire aucune entrée, et surtout pas faire tomber le reste.
verifie("blank lines are skipped, others survive",
        aplati(Sonde.analyse("\n  100 7 /a\n\n  200 8 /b\n")),
        ["102400|7|/a", "204800|8|/b"])

// Lignes malformées : rien d'exploitable, on écarte sans planter.
verifie("garbage line is dropped", aplati(Sonde.analyse("garbage")), [])
verifie("non-numeric RSS is dropped", aplati(Sonde.analyse("  abc 12 /usr/bin/foo")), [])
verifie("non-numeric PID is dropped", aplati(Sonde.analyse("  100 xy /usr/bin/foo")), [])
// Deux champs seulement : le chemin est vide, la ligne n'a rien à dire.
verifie("line with no path is dropped", aplati(Sonde.analyse("  100 12 ")), [])
verifie("empty output yields nothing", aplati(Sonde.analyse("")), [])

// Le RSS de `ps` est en kilo-octets : la conversion en octets fait partie du contrat.
verifie("RSS is converted from kilobytes to bytes",
        Sonde.analyse("  1024 1 /x").first?.rss, 1_048_576)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 2. Sonde.nomApp : remonter au bundle
// ─────────────────────────────────────────────────────────────────────────────

section("Sonde.nomApp (bundle name extraction)")

// Le cas qui décide du regroupement : un helper est imbriqué dans DEUX bundles .app.
// C'est le PREMIER qu'il faut rendre (« Google Chrome »), pas le dernier, sinon chaque
// helper forme sa propre ligne et le gros consommateur se cache dans sa poussière.
verifie("nested helper resolves to the outermost .app", Sonde.nomApp(cheminChrome), "Google Chrome")

verifie("plain app bundle",
        Sonde.nomApp("/Applications/Safari.app/Contents/MacOS/Safari"), "Safari")
verifie("binary outside any bundle", Sonde.nomApp("/opt/homebrew/bin/node"), "node")
verifie("path with no slash at all", Sonde.nomApp("kernel_task"), "kernel_task")
// Hors bundle, le nom passe par joli() : un identifiant inversé reste lisible.
verifie("binary outside a bundle is prettified",
        Sonde.nomApp("/System/Library/Foo/com.apple.WebKit.Networking"), "WebKit Networking")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 3. Sonde.joli : rendre lisible un identifiant inversé
// ─────────────────────────────────────────────────────────────────────────────

section("Sonde.joli (reverse-DNS names)")

verifie("reverse-DNS service name becomes readable",
        Sonde.joli("com.apple.SafariPlatformSupport.Helper"), "SafariPlatformSupport Helper")
verifie("name not starting with com. is left alone", Sonde.joli("mdworker_shared"), "mdworker_shared")
// Un seul point : il n'y a pas deux segments parlants à garder, on ne touche à rien.
verifie("com. name with a single dot is left alone", Sonde.joli("com.foo"), "com.foo")
verifie("empty name is left alone", Sonde.joli(""), "")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 4. Jetsam.victime : lire un rapport .ips
// ─────────────────────────────────────────────────────────────────────────────
//
// Format réel : première ligne = un objet JSON d'en-tête, le reste = un autre objet
// JSON contenant `processes`. Seuls les processus réellement tués portent un `reason`,
// et `per-process-limit` (une app qui dépasse SA limite, machine saine) ne doit pas
// être confondu avec un manque de mémoire réel.

section("Jetsam.victime (.ips reports)")

// TMPDIR de l'environnement d'abord : NSTemporaryDirectory() l'ignore et rend le dossier
// T/ de l'usager, qui n'est pas toujours accessible en écriture (bac à sable d'agent).
let racineTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
let bac = URL(fileURLWithPath: racineTmp)
    .appendingPathComponent("attix-tests-\(getpid())", isDirectory: true)
do { try FileManager.default.createDirectory(at: bac, withIntermediateDirectories: true) }
catch { print("  FAIL cannot create temp dir: \(error)"); exit(1) }

func rapport(_ nom: String, _ corps: String) -> URL {
    let u = bac.appendingPathComponent(nom)
    // L'en-tête sur sa propre ligne, comme dans un vrai .ips. Une écriture qui échoue
    // rendrait tous les cas « nil » et donc verts par accident : on sort bruyamment.
    do {
        try ("{\"timestamp\":\"2026-09-14 16:40:06.00 +0200\"}\n" + corps)
            .write(to: u, atomically: false, encoding: .utf8)
    } catch { print("  FAIL cannot write \(nom): \(error)"); exit(1) }
    return u
}

let tue = rapport("tue.ips", """
{"processes":[
  {"name":"launchd","pageCount":100},
  {"name":"Google Chrome","reason":"vm-pageshortage","pageCount":300000}
]}
""")
// Le nom passe par ALIAS : « Google Chrome » est montré comme « Chrome ».
verifie("killed process is found and aliased", Jetsam.victime(tue)?.nom, "Chrome")
verifie("its reason is reported", Jetsam.victime(tue)?.raison, "vm-pageshortage")

// per-process-limit doit rester distinct : c'est ce qui permet de ne PAS alerter comme
// pour un manque de mémoire machine.
let limite = rapport("limite.ips", """
{"processes":[{"name":"WebKitPlugin","reason":"per-process-limit"}]}
""")
verifie("per-process-limit is reported as such", Jetsam.victime(limite)?.raison, "per-process-limit")
verifie("per-process-limit keeps its process name", Jetsam.victime(limite)?.nom, "WebKitPlugin")

// Aucun `reason` : personne n'a été tué, il n'y a rien à annoncer.
let sain = rapport("sain.ips", """
{"processes":[{"name":"Safari","pageCount":10},{"name":"node","pageCount":20}]}
""")
verifie("report with no reason yields nil", Jetsam.victime(sain)?.nom, nil)

let vide = rapport("vide.ips", "{\"reason\":\"none\"}")
verifie("report with no processes array yields nil", Jetsam.victime(vide)?.nom, nil)

let casse = rapport("casse.ips", "{ not json at all")
verifie("unparseable report yields nil", Jetsam.victime(casse)?.nom, nil)

verifie("missing file yields nil",
        Jetsam.victime(bac.appendingPathComponent("absent.ips"))?.nom, nil)

try? FileManager.default.removeItem(at: bac)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 5. go() et le regroupement par ALIAS
// ─────────────────────────────────────────────────────────────────────────────

section("go (byte formatting)")

verifie("zero", go(0), "0 MB")
// Sous 0,1 Go on reste en Mo : « 0.1 GB » pour 60 Mo ne dirait rien à personne.
verifie("60 MB stays in MB", go(60 * 1024 * 1024), "60 MB")
verifie("just under the GB threshold", go(102 * 1024 * 1024), "102 MB")
verifie("exactly one GB", go(1_073_741_824), "1.0 GB")
// Le chiffre du bug : Chrome mesuré à 1 273 Mo là où l'app en affichait 205.
verifie("1273 MB reads as GB", go(1273 * 1024 * 1024), "1.2 GB")

section("ALIAS grouping")

// Le regroupement lui-même vit dans consommateurs(), qui interroge le système. Ce qui
// est testable sans le tordre, c'est sa clé : nomApp() puis ALIAS.
func groupe(_ chemin: String) -> String {
    let origine = Sonde.nomApp(chemin)
    return ALIAS[origine] ?? origine
}
verifie("chrome helper groups under Chrome", groupe(cheminChrome), "Chrome")
verifie("node groups under Node", groupe("/opt/homebrew/bin/node"), "Node")
verifie("bun groups under Node too", groupe("/opt/homebrew/bin/bun"), "Node")
verifie("claude CLI groups under Claude Code", groupe("/usr/local/bin/claude"), "Claude Code")
verifie("spotlight workers share one name",
        groupe("/System/Library/Frameworks/CoreServices.framework/mdworker_shared"),
        "Spotlight indexing")
verifie("unknown binary keeps its own name", groupe("/usr/bin/ssh"), "ssh")
// Ces deux-là ne doivent JAMAIS apparaître dans la liste : aucun geste n'y est sûr.
verifie("WindowServer is untouchable", INTOUCHABLES.contains("WindowServer"), true)
verifie("loginwindow is untouchable", INTOUCHABLES.contains("loginwindow"), true)

// ─────────────────────────────────────────────────────────────────────────────

print("\n\(passes) passed, \(echecs) failed")
exit(echecs == 0 ? 0 : 1)
