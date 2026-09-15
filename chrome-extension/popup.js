// Attix for Chrome : mettre en veille les onglets inactifs, sans les perdre.
//
// CE QU'ON NE PEUT PAS FAIRE, et il vaut mieux le dire que le simuler : Chrome n'expose
// la mémoire par onglet à AUCUNE extension du Web Store. L'API `chrome.processes` existe
// mais reste réservée aux builds internes. Afficher « 312 Mo » par onglet demanderait
// donc d'inventer un chiffre : on ne le fait pas.
//
// Ce que Chrome expose et qui libère de la mémoire pour de vrai : tabs.discard(). L'onglet
// reste dans la barre, avec son titre et sa position ; c'est son processus de rendu qui
// est rendu au système. Un clic le recharge. Rien n'est fermé, rien n'est perdu.
//
// Le tri se fait donc sur ce qu'on sait vraiment : depuis quand l'onglet n'a pas été
// regardé. C'est le meilleur indicateur disponible de ce qu'on peut endormir sans gêne.

const SEUIL_INACTIF = 20 * 60 * 1000;   // 20 min sans consultation = candidat
const MAX_LISTE = 6;

const $ = (id) => document.getElementById(id);

// Les pages internes du navigateur refusent discard(). Les compter parmi les candidats
// ferait annoncer « 12 onglets peuvent dormir » alors que deux ne le peuvent pas : le
// compteur mentirait, et c'est exactement le genre de chiffre faux qu'on veut éviter.
const INTERNES = /^(chrome|chrome-extension|edge|brave|about|devtools|view-source):/i;

/** Un onglet est endormissable s'il n'est ni regardé, ni sonore, ni épinglé, ni déjà endormi. */
function endormissable(t) {
  return !t.active && !t.audible && !t.pinned && !t.discarded
    && t.id !== chrome.tabs.TAB_ID_NONE
    && !INTERNES.test(t.url || "");
}

/** Depuis combien de temps l'onglet n'a pas été consulté, en minutes. */
function inactifDepuis(t) {
  if (!t.lastAccessed) return null;          // lastAccessed : Chrome 121+
  return Math.max(0, Date.now() - t.lastAccessed);
}

function duree(ms) {
  if (ms === null) return "idle";
  const min = Math.round(ms / 60000);
  if (min < 60) return `idle ${min} min`;
  const h = Math.round(min / 60);
  return h < 24 ? `idle ${h} h` : `idle ${Math.round(h / 24)} d`;
}

function hote(url) {
  try { return new URL(url).hostname.replace(/^www\./, ""); }
  catch { return url ? url.slice(0, 40) : ""; }
}

async function rendu() {
  const onglets = await chrome.tabs.query({});
  const fenetres = new Set(onglets.map((t) => t.windowId)).size;
  const endormis = onglets.filter((t) => t.discarded);
  const candidats = onglets
    .filter(endormissable)
    .map((t) => ({ t, ms: inactifDepuis(t) }))
    // Les onglets sans lastAccessed (Chrome < 121) partent en fin de liste plutôt que
    // d'être traités comme « jamais consultés », ce qui les ferait remonter à tort.
    .sort((a, b) => (b.ms ?? -1) - (a.ms ?? -1));

  const inactifs = candidats.filter(({ ms }) => ms === null || ms >= SEUIL_INACTIF);

  // ── En-tête ────────────────────────────────────────────────────────────────
  const tendu = onglets.length >= 25;
  const pastille = $("pastille");
  pastille.textContent = tendu ? "A lot of tabs" : "Reasonable";
  pastille.classList.toggle("ok", !tendu);

  const remplissage = $("remplissage");
  remplissage.style.width = `${Math.min(100, (onglets.length / 40) * 100)}%`;
  remplissage.classList.toggle("ok", !tendu);

  $("resume").textContent =
    `${onglets.length} tabs in ${fenetres} window${fenetres > 1 ? "s" : ""} · ` +
    `${endormis.length} already asleep · ${inactifs.length} can sleep now`;

  // ── Action groupée ─────────────────────────────────────────────────────────
  const carte = $("carte-action");
  if (inactifs.length > 0) {
    carte.hidden = false;
    $("action-titre").textContent =
      `${inactifs.length} tab${inactifs.length > 1 ? "s" : ""} idle for 20 minutes or more`;
    $("action-detail").textContent =
      "They stay in the tab strip and reload when you click them.";
    const bouton = $("liberer");
    bouton.disabled = false;
    bouton.textContent = "Sleep them";
    bouton.onclick = async () => {
      bouton.disabled = true;
      bouton.textContent = "Sleeping…";
      await endors(inactifs.map(({ t }) => t.id));
      rendu();
    };
  } else {
    carte.hidden = true;
  }

  // ── Liste détaillée ────────────────────────────────────────────────────────
  const liste = $("liste");
  liste.replaceChildren();
  const aMontrer = candidats.slice(0, MAX_LISTE);
  $("vide").hidden = aMontrer.length > 0;

  for (const { t, ms } of aMontrer) {
    const li = document.createElement("li");

    const icone = document.createElement("img");
    icone.src = t.favIconUrl || "icons/16.png";
    icone.alt = "";
    icone.onerror = () => { icone.src = "icons/16.png"; };

    const texte = document.createElement("div");
    texte.className = "texte";
    const titre = document.createElement("strong");
    titre.textContent = t.title || hote(t.url);
    titre.title = t.title || "";
    const detail = document.createElement("span");
    detail.className = "detail";
    detail.textContent = `${hote(t.url)} · ${duree(ms)}`;
    texte.append(titre, detail);

    const bouton = document.createElement("button");
    bouton.textContent = "Sleep";
    bouton.onclick = async () => {
      bouton.disabled = true;
      await endors([t.id]);
      rendu();
    };

    li.append(icone, texte, bouton);
    liste.append(li);
  }

  $("pied").textContent = "Chrome does not report per-tab memory to extensions.";
}

/** discard() échoue sur certains onglets (internes, en cours de chargement) : on isole
 *  chaque appel pour qu'un refus n'annule pas les autres. */
async function endors(ids) {
  await Promise.allSettled(ids.map((id) => chrome.tabs.discard(id)));
}

document.addEventListener("DOMContentLoaded", rendu);
