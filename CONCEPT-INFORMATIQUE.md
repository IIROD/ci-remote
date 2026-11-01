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
- **Technicien vérifié** (`ci_peer_check.dart`) : quand quelqu'un demande à se connecter, l'app client
  affiche s'il s'agit d'un poste technicien reconnu par le serveur, sinon un avertissement.
- **Compteur de temps** (`ci_session_counter.dart`) : solde du crédit support pendant la session
  (`-30:00` → `+00:20 · 0,20 €`), minutes offertes au début (« Offert 4:12 »). App technicien : pastille
  dans la barre d'onglets de la session (dans la barre d'outils en plein écran). App client : encart
  dans la fenêtre de connexion, et bloc « Mon suivi » sur l'accueil (crédit, mois, dernières
  interventions). Calcul côté serveur (`/api/v1/*/counter`), l'app compte seule entre deux lectures.
- **Barre de session (app technicien)** : bouton « Fichiers » direct et menu « Concept » (`ci_actions.dart`,
  classes `_Ci*` en fin de `remote_toolbar.dart`) : mode Tech uniquement (clavier et souris du client bloqués,
  client prévenu par la discussion) et « Rendre la main 2 min », écran noir chez le client, outils Windows
  et diagnostic en un clic (Win+R puis saisie), verrouiller, redémarrer, veille, éteindre. Écran adapté à la
  fenêtre, qualité et codec automatiques par défaut (`default-settings` de `res/ci-remote/client.json`).
- **Redémarrage avec reconnexion** : avant de redémarrer, l'app client se programme pour se relancer à
  l'ouverture de session (RunOnce, `src/ci_remote.rs`) et accepte une fois le même technicien vérifié
  pendant 10 min (`ci_reconnect.dart`). Éteindre ne reconnecte pas.
- **Passer à un collègue** (menu Concept) : le collègue voit le PC en tête de sa console (10 min) et prend
  la main ; l'app client l'accepte sans clic (`ci_reconnect.dart`, confirmé par le serveur) ; même session.
- **Journal d'actions** : chaque action du menu Concept est notée (`ciLog`, `POST /api/v1/tech/log`),
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
