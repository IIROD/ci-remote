# ci-remote — app d'assistance à distance de Concept Informatique

Ce dépôt est une version **modifiée de [RustDesk](https://github.com/rustdesk/rustdesk)**
(base : version officielle **1.5.1**), publiée sous la même licence, **AGPL-3.0** (voir `LICENCE`).
« ci-remote » est un nom provisoire.

## Pourquoi ce dépôt

Concept Informatique (Belgique) utilise RustDesk avec son propre serveur pour l'assistance à
distance de ses clients. Les modifications prévues :

- rattachement automatique du PC au compte client du site ;
- ouverture de la session en un clic depuis la console du magasin ;
- accord du client à chaque session, élévation des droits dès l'acceptation ;
- information du serveur sur l'activité du technicien (compteur de temps) ;
- nom et logo propres (« RustDesk » est une marque de ses auteurs et n'est pas utilisé pour
  l'app distribuée).

## App client et app technicien

Une seule base, deux versions fixées à la compilation par une constante Dart :
`CI_ROLE=client` (par défaut) ou `--dart-define=CI_ROLE=tech`.

- **App client** (`flutter/lib/desktop/pages/ci_client_home.dart`) : une seule page aux couleurs
  du magasin — client, PC, propriétaire modifiable, « Demande d'aide », état du service. Mode
  « réception seule » (`conn-type: incoming` dans `res/ci-remote/client.json`) : l'app client ne peut
  pas prendre la main sur un autre PC.
- **App technicien** (`ci_tech_home.dart`, exe `ci-tech-x86_64.exe`) : connexion avec un compte
  admin du site (mot de passe + code reçu par email), puis tableau des PC clients (tri, recherche,
  demandes d'aide en tête, « Prendre la main », joindre un ID). Compilée par le même workflow, sans
  le mode « réception seule ».
- **Demande de connexion (app client)** (`ci_cm_shell.dart`) : la fenêtre RustDesk est remplacée par une
  carte au centre de l'écran : « Le technicien Jarod souhaiterait prendre le contrôle… » (prénom seul,
  vérifié par le serveur, sinon avertissement rouge), Autoriser (avec élévation UAC quand Windows la
  propose) ou Refuser ; refus automatique au bout de 45 s.
- **Compteur de temps** (`ci_session_counter.dart`) : solde du crédit support pendant la session
  (`-30:00`, puis `+00:20 | 0,20 €` : le montant n'apparaît qu'en dépassement), minutes offertes au
  début (« Offert 4:12 »). App technicien : dans sa barre d'actions. App client : overlay compact en
  haut de l'écran pendant la session, et bloc « Mon suivi » sur l'accueil (crédit, mois, dernières
  interventions). Calcul côté serveur (`/api/v1/*/counter`), l'app compte seule entre deux lectures.
- **Barre d'actions (app technicien)** (`ci_tech_bar.dart`, logique dans `ci_actions.dart`) : en haut de la
  session, client et compteur, sélecteur Partagé / Tech uniquement (clavier et souris du client bloqués,
  client prévenu par la discussion) / Privacy (écran masqué chez le client), « Rendre la main 2 min »,
  Fichiers, Discussion, Outils (palette avec recherche et récents : outils Windows, diagnostic, console,
  lancés par Win+R), Alimentation (verrouiller, redémarrer, veille, éteindre), Collègue, qualité d'image,
  plein écran, Terminer. La barre RustDesk reste pour les réglages avancés.
- **Demande de fin par le client** : le client ne coupe pas d'un clic ; « Demander la fin de l'accès »
  (confirmation) prévient le technicien (bandeau : Terminer maintenant ou « Encore 2 min », une fois) et
  l'app client coupe d'elle-même 2 min plus tard, même si le serveur est injoignable. Écran adapté à la
  fenêtre, qualité et codec automatiques par défaut (`default-settings` de `res/ci-remote/client.json`).
- **Redémarrage avec reconnexion** : avant de redémarrer, l'app client se programme pour se relancer à
  l'ouverture de session (RunOnce, `src/ci_remote.rs`) et accepte une fois le même technicien vérifié
  pendant 10 min (`ci_reconnect.dart`). Éteindre ne reconnecte pas.
- **App client portable sans droits administrateur** (`src/ci_overlay.rs`) : le blocage clavier/souris passe
  par le crochet de RustDesk (BlockInput exige l'administrateur, erreur 1460) ; « Privacy » est une fenêtre
  noire exclue de la capture (Windows 10 2004+) au lieu du mode RustDesk qui exige le service installé ;
  la fenêtre de connexion est exclue de la capture (le technicien ne la voit pas) et s'efface quand son
  pointeur passe dessus (ses clics vont dessous) ; le pointeur du technicien est montré au client par un
  halo à son prénom (crochet souris, évènements injectés), lui aussi exclu de la capture. Un message du
  technicien ouvre la discussion RustDesk sous l'overlay.
- **Passer à un collègue** (menu Concept) : le collègue voit le PC en tête de sa console (10 min) et prend
  la main ; l'app client l'accepte sans clic (`ci_reconnect.dart`, confirmé par le serveur) ; même session.
- **Journal d'actions** : chaque action de la barre est notée (`ciLog`, `POST /api/v1/tech/log`),
  visible dans l'admin du site (Support → Historique → Journal).
- Données : API d'assistance (`/api/v1/device/*`), le PC s'identifie par son ID, son identifiant
  machine et son code de téléchargement.

## Compilation

`.github/workflows/concept-windows.yml` compile l'exe portable Windows x64 à chaque pull request
et à chaque push sur `main` (artefact téléchargeable depuis l'onglet **Actions**, non signé).

Les workflows automatiques d'origine (toutes plateformes, publication de versions, tâches
nocturnes) ont été retirés ; les workflows réutilisables restent.

## Suivre RustDesk

Les nouvelles versions officielles sont fusionnées depuis le tag correspondant de RustDesk :

```bash
git remote add upstream https://github.com/rustdesk/rustdesk.git
git fetch upstream tag <version>
git merge <version>
```
